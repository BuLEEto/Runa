/*
UAX #29 word-break conformance harness.

Runs `itemize.word_iter_next` against every test case in
`tools/ucd/WordBreakTest.txt` and reports pass / mismatch counts.

Format mirrors the grapheme break test: a sequence of `÷` (break)
and `×` (no-break) markers separated by hex codepoints.

Run:
    odin run tools/wb_conformance.odin -file -o:speed
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "../itemize"

main :: proc() {
	data, err := os.read_entire_file_from_path("tools/ucd/WordBreakTest.txt", context.allocator)
	if err != nil { fmt.eprintfln("read: %v", err); os.exit(1) }
	defer delete(data)

	total, passed := 0, 0
	print_cap := 20
	mismatches := 0

	iter := string(data)
	for line in strings.split_lines_iterator(&iter) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' { continue }
		if hash := strings.index_byte(t, '#'); hash >= 0 {
			t = strings.trim_space(t[:hash])
		}
		if len(t) == 0 { continue }

		runes := make([dynamic]rune, 0, 16, context.temp_allocator)
		want_break := make([dynamic]bool, 0, 16, context.temp_allocator)

		ti := t
		first_marker := true
		for tok in tokenize_wb(&ti) {
			switch tok {
			case "÷":
				if !first_marker { append(&want_break, true) }
				first_marker = false
			case "×":
				if !first_marker { append(&want_break, false) }
				first_marker = false
			case:
				v, ok := strconv.parse_u64_of_base(tok, 16)
				if !ok { continue }
				append(&runes, rune(v))
				first_marker = false
			}
		}

		text := string_from_runes(runes[:])
		got_breaks := make([dynamic]int, 0, 16, context.temp_allocator)
		it := itemize.word_iter_make(text)
		for {
			lo, hi, ok := itemize.word_iter_next(&it)
			if !ok { break }
			_ = lo
			append(&got_breaks, hi)
		}

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
	fmt.printfln("UAX #29 WordBreakTest: %d / %d passed (%.2f%%)  mismatches=%d", passed, total, pct, mismatches)
}

tokenize_wb :: proc(s: ^string) -> [dynamic]string {
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	for len(s^) > 0 {
		for len(s^) > 0 && (s^[0] == ' ' || s^[0] == '\t') { s^ = s^[1:] }
		if len(s^) == 0 { break }
		if len(s^) >= 2 && s^[0] == 0xC3 && s^[1] == 0xB7 {
			append(&out, "÷")
			s^ = s^[2:]
			continue
		}
		if len(s^) >= 2 && s^[0] == 0xC3 && s^[1] == 0x97 {
			append(&out, "×")
			s^ = s^[2:]
			continue
		}
		j := 0
		for j < len(s^) && s^[j] != ' ' && s^[j] != '\t' { j += 1 }
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
