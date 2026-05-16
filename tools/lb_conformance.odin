/*
UAX #14 conformance harness — runs the linebreak engine against
`tools/ucd/LineBreakTest.txt` and reports pass rate.

Each row of the test file looks like:

    × 2757 × 2757 ÷    # commentary…

`× CP` means "no break opportunity before this codepoint";
`÷ CP` means "break opportunity before this codepoint".
The trailing `÷` is the end-of-text break (always required).

The runner translates each row into (codepoints, expected_break_set)
and asks our engine for its break opportunities. Mismatches are
printed (capped to keep output tractable).

Run:
    odin run tools/lb_conformance.odin -file
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import lb "../linebreak"

main :: proc() {
	data, err := os.read_entire_file_from_path("tools/ucd/LineBreakTest.txt", context.allocator)
	if err != nil { fmt.eprintfln("read: %v", err); os.exit(1) }
	defer delete(data)

	total, passed, mismatches := 0, 0, 0
	print_cap := 12
	per_pair_count: map[[2]lb.Line_Break_Class]int
	defer delete(per_pair_count)

	iter := string(data)
	for line in strings.split_lines_iterator(&iter) {
		raw := strings.trim_space(line)
		if len(raw) == 0 || raw[0] == '#' { continue }

		// Strip trailing comment.
		body := raw
		if hash := strings.index_byte(body, '#'); hash >= 0 {
			body = strings.trim_space(body[:hash])
		}
		runes, breaks, ok := parse_test_row(body)
		if !ok { continue }

		total += 1
		actual := compute_breaks(runes)
		if break_sets_match(breaks, actual) {
			passed += 1
		} else {
			// Identify the first divergent gap and tally the pair-of-classes
			// that produced it.
			for i in 1..<len(breaks) {
				if breaks[i] != actual[i] && i < len(runes) {
					left  := lb.line_break_class(runes[i - 1])
					right := lb.line_break_class(runes[i])
					per_pair_count[[2]lb.Line_Break_Class{left, right}] += 1
					break
				}
			}
			if mismatches < print_cap {
				fmt.printfln("MISMATCH: %s", body)
				fmt.printfln("  runes:    %v", runes)
				fmt.printfln("  expected: %v", breaks)
				fmt.printfln("  actual:   %v", actual)
			}
			mismatches += 1
		}
		delete(runes)
		delete(breaks)
		delete(actual)
	}

	pct: f32 = 0
	if total > 0 { pct = 100.0 * f32(passed) / f32(total) }
	fmt.printfln("UAX #14 conformance: %d / %d passed (%.1f%%)  mismatches=%d", passed, total, pct, mismatches)
	fmt.println("Top 30 failing class pairs (left × right counts):")
	// Crude top-N: linear scan.
	for k := 0; k < 30; k += 1 {
		best_pair: [2]lb.Line_Break_Class
		best_count := 0
		for p, c in per_pair_count {
			if c > best_count { best_count = c; best_pair = p }
		}
		if best_count == 0 { break }
		fmt.printfln("  %v -> %v   %d", best_pair[0], best_pair[1], best_count)
		delete_key(&per_pair_count, best_pair)
	}
}

// parse_test_row turns `× 2757 × 2757 ÷` into ([0x2757, 0x2757],
// [false, false, true]) — the boolean slice has one entry per "gap
// position" (sot, between each pair, eot), so its length is
// `len(runes) + 1`.
parse_test_row :: proc(body: string) -> (runes: []rune, breaks: []bool, ok: bool) {
	tokens := strings.fields(body)
	if len(tokens) < 2 { return }

	runes_dyn  := make([dynamic]rune, 0, 16)
	breaks_dyn := make([dynamic]bool,  0, 16)

	expecting_break := true        // toggles after each codepoint read
	for tok in tokens {
		// `÷` (U+00F7) or `×` (U+00D7) are the markers.
		switch tok {
		case "÷":
			append(&breaks_dyn, true)
			expecting_break = false
		case "×":
			append(&breaks_dyn, false)
			expecting_break = false
		case:
			cp_u, perr := strconv.parse_u64_of_base(tok, 16)
			if !perr { delete(runes_dyn); delete(breaks_dyn); return }
			append(&runes_dyn, rune(cp_u))
			expecting_break = true
		}
	}
	if expecting_break {
		// shouldn't happen — test rows always end with a marker
	}
	runes = runes_dyn[:]
	breaks = breaks_dyn[:]
	ok = true
	return
}

// compute_breaks walks the engine and produces the same shape of
// boolean slice that parse_test_row emits (sot at index 0, eot at
// index len(runes)).
//
// At v0.1 sot/eot are always "break"-true (LB2 = sot ÷, LB3 = ÷ eot)
// and we never call `next_break` for the sot position.
compute_breaks :: proc(runes: []rune) -> []bool {
	out := make([]bool, len(runes) + 1)
	// LB2: never break AT sot. Convention in the UCD test file is `×`
	// before the first codepoint — i.e. out[0] = false. We leave the
	// zero default in place.
	out[len(runes)] = true                                        // LB3: ÷ eot

	i := 0
	for i < len(runes) {
		next_i, _ := lb.next_break(runes, i)
		if next_i <= i { i += 1; continue }
		if next_i < len(runes) { out[next_i] = true }
		i = next_i
	}
	return out
}

break_sets_match :: proc(a, b: []bool) -> bool {
	if len(a) != len(b) { return false }
	for i in 0..<len(a) { if a[i] != b[i] { return false } }
	return true
}
