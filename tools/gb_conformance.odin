/*
UAX #29 grapheme-cluster conformance — runs `itemize.grapheme_iter_*`
against `tools/ucd/GraphemeBreakTest.txt` and reports pass rate.

Format: a sequence of `÷` (break) and `×` (no-break) markers
separated by hex codepoints. Each row encodes the boundary state at
every position. We rebuild the codepoint string, iterate clusters,
and compare the produced break-set with the file's.

Run:
    odin run tools/gb_conformance.odin -file -o:speed
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "../itemize"

main :: proc() {
	data, err := os.read_entire_file_from_path("tools/ucd/GraphemeBreakTest.txt", context.allocator)
	if err != nil { fmt.eprintfln("read: %v", err); os.exit(1) }
	defer delete(data)

	total, passed := 0, 0
	print_cap := 5
	mismatches := 0

	iter := string(data)
	for line in strings.split_lines_iterator(&iter) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' { continue }
		if hash := strings.index_byte(t, '#'); hash >= 0 {
			t = strings.trim_space(t[:hash])
		}
		if len(t) == 0 { continue }

		// Parse tokens — `÷` (multi-byte), `×` (multi-byte), and hex.
		runes := make([dynamic]rune, 0, 16, context.temp_allocator)
		want_break := make([dynamic]bool, 0, 16, context.temp_allocator) // length = len(runes) + 1, edge before each + after last

		ti := t
		expect_break := false
		first_marker := true
		for tok in tokenize_gb(&ti) {
			switch tok {
			case "÷":
				if !first_marker { append(&want_break, true) }
				expect_break = true
				first_marker = false
			case "×":
				if !first_marker { append(&want_break, false) }
				expect_break = false
				first_marker = false
			case:
				v, ok := strconv.parse_u64_of_base(tok, 16)
				if !ok { continue }
				append(&runes, rune(v))
				first_marker = false
				expect_break = false
			}
		}
		// `want_break` now has one entry per *interior* position
		// (between adjacent runes); the final ÷ at EOS isn't tracked.

		// Build the codepoint string and iterate clusters.
		text := string_from_runes(runes[:])
		got_breaks := make([dynamic]int, 0, 16, context.temp_allocator)
		it := itemize.grapheme_iter_make(text)
		for {
			lo, hi, ok := itemize.grapheme_iter_next(&it)
			if !ok { break }
			_ = lo
			append(&got_breaks, hi)            // includes EOS (always a break per GB2)
		}

		// Translate got-byte-offsets back to per-pair indices.
		got_break_at := make([]bool, len(runes), context.temp_allocator)
		byte_at := make([]int, len(runes) + 1, context.temp_allocator)
		off := 0
		for i in 0..<len(runes) {
			byte_at[i] = off
			off += utf8_rune_size(runes[i])
		}
		byte_at[len(runes)] = off
		for b in got_breaks {
			for j in 0..<len(runes) {
				if byte_at[j + 1] == b { got_break_at[j] = true; break }
			}
		}

		ok := len(want_break) == len(runes)
		if ok {
			for i in 0..<len(want_break) {
				if want_break[i] != got_break_at[i] { ok = false; break }
			}
		}

		total += 1
		if ok {
			passed += 1
		} else {
			mismatches += 1
			if mismatches <= print_cap {
				fmt.printfln("MISMATCH: %s", t)
				fmt.printfln("  want=%v got=%v", want_break[:], got_break_at)
			}
		}
	}

	pct: f32 = 0
	if total > 0 { pct = 100.0 * f32(passed) / f32(total) }
	fmt.printfln("UAX #29 GraphemeBreakTest: %d / %d passed (%.2f%%)  mismatches=%d", passed, total, pct, mismatches)
}

tokenize_gb :: proc(s: ^string) -> [dynamic]string {
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	for len(s^) > 0 {
		// Skip whitespace.
		for len(s^) > 0 && (s^[0] == ' ' || s^[0] == '\t') {
			s^ = s^[1:]
		}
		if len(s^) == 0 { break }
		// `÷` is U+00F7 — UTF-8 0xC3 0xB7 (2 bytes).
		if len(s^) >= 2 && s^[0] == 0xC3 && s^[1] == 0xB7 {
			append(&out, "÷")
			s^ = s^[2:]
			continue
		}
		// `×` is U+00D7 — UTF-8 0xC3 0x97.
		if len(s^) >= 2 && s^[0] == 0xC3 && s^[1] == 0x97 {
			append(&out, "×")
			s^ = s^[2:]
			continue
		}
		// Otherwise hex digits until whitespace.
		j := 0
		for j < len(s^) && s^[j] != ' ' && s^[j] != '\t' {
			j += 1
		}
		if j > 0 {
			append(&out, s^[:j])
			s^ = s^[j:]
		} else {
			s^ = s^[1:]
		}
	}
	return out
}

string_from_runes :: proc(rs: []rune) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in rs { strings.write_rune(&b, r) }
	return strings.to_string(b)
}

utf8_rune_size :: proc(r: rune) -> int {
	switch {
	case r < 0x80:    return 1
	case r < 0x800:   return 2
	case r < 0x10000: return 3
	}
	return 4
}
