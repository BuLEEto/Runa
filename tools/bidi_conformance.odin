/*
UAX #9 conformance — runs `bidi.resolve_levels` against every test
case in `tools/ucd/BidiCharacterTest.txt` and reports pass rate.

The 91 k test rows each carry:
  field 0: codepoint sequence (hex, space-separated)
  field 1: paragraph direction (0 LTR, 1 RTL, 2 Auto)
  field 2: resolved paragraph base level (informational)
  field 3: per-codepoint resolved levels ('x' for X9-removed)
  field 4: visual-order index map

Compares field 3 against `bidi.resolve_levels`. The 'x' positions
(LRE/RLE/PDF/etc. removed by X9) are skipped — runa keeps them in
the buffer marked .BN with whatever level X-rules assigned; the
test's 'x' is a "don't care" wherever we agree on placement of
real characters.

Run:
    odin run tools/bidi_conformance.odin -file -o:speed
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import bidi "../bidi"

main :: proc() {
	data, err := os.read_entire_file_from_path("tools/ucd/BidiCharacterTest.txt", context.allocator)
	if err != nil { fmt.eprintfln("read: %v", err); os.exit(1) }
	defer delete(data)

	total, passed, level_mismatches := 0, 0, 0
	print_cap := 5
	per_case_mismatches: map[string]int
	defer delete(per_case_mismatches)

	// Bucket counters — each mismatch increments exactly one bucket,
	// chosen by the most distinctive feature present in the test
	// codepoint set.
	bucket_isolate_fsi   := 0 // contains FSI / RLI / LRI / PDI
	bucket_embed_format  := 0 // contains LRE/RLE/LRO/RLO/PDF
	bucket_brackets      := 0 // contains paired-bracket characters
	bucket_other         := 0

	iter := string(data)
	for line in strings.split_lines_iterator(&iter) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' { continue }
		fields := strings.split(t, ";", context.temp_allocator)
		if len(fields) < 4 { continue }

		runes, ok := parse_codepoints(fields[0])
		if !ok { continue }
		defer delete(runes)

		dir_str := strings.trim_space(fields[1])
		dir_u, _ := strconv.parse_int(dir_str)
		bd_dir: bidi.Direction
		switch dir_u {
		case 0: bd_dir = .LTR
		case 1: bd_dir = .RTL
		case 2: bd_dir = bidi.paragraph_direction(string_from_runes(runes))
		}
		if bd_dir == .Neutral { bd_dir = .LTR }

		want_levels := parse_levels(fields[3])
		defer delete(want_levels)

		total += 1

		// runa's resolve_levels takes a string, so we re-encode.
		text := string_from_runes(runes)
		got_levels, byte_idx := bidi.resolve_levels(text, bd_dir, context.temp_allocator)
		_ = byte_idx

		// Compare. Skip 'x' positions (encoded as -1).
		ok_match := len(got_levels) == len(want_levels)
		if ok_match {
			for i in 0..<len(want_levels) {
				if want_levels[i] < 0 { continue }
				if int(got_levels[i]) != want_levels[i] { ok_match = false; break }
			}
		}
		if ok_match {
			passed += 1
		} else {
			level_mismatches += 1
			// Bucket by distinguishing codepoint feature.
			has_isolate, has_embed, has_bracket := false, false, false
			for r in runes {
				switch r {
				case 0x2066, 0x2067, 0x2068, 0x2069: has_isolate = true
				case 0x202A, 0x202B, 0x202C, 0x202D, 0x202E: has_embed = true
				case 0x0028, 0x0029, 0x005B, 0x005D, 0x007B, 0x007D,
				     0x0F3A, 0x0F3B, 0x0F3C, 0x0F3D,
				     0x169B, 0x169C, 0x2045, 0x2046,
				     0x207D, 0x207E, 0x208D, 0x208E,
				     0x2308, 0x2309, 0x230A, 0x230B,
				     0x2329, 0x232A, 0x2768, 0x2769, 0x276A, 0x276B,
				     0x276C, 0x276D, 0x276E, 0x276F, 0x2770, 0x2771,
				     0x2772, 0x2773, 0x2774, 0x2775,
				     0x27C5, 0x27C6, 0x27E6, 0x27E7, 0x27E8, 0x27E9,
				     0x27EA, 0x27EB, 0x27EC, 0x27ED, 0x27EE, 0x27EF,
				     0x2983, 0x2984, 0x2985, 0x2986, 0x2987, 0x2988,
				     0x2989, 0x298A, 0x298B, 0x298C, 0x298D, 0x298E,
				     0x298F, 0x2990, 0x2991, 0x2992, 0x2993, 0x2994,
				     0x2995, 0x2996, 0x2997, 0x2998,
				     0x29D8, 0x29D9, 0x29DA, 0x29DB,
				     0x29FC, 0x29FD, 0x2E22, 0x2E23, 0x2E24, 0x2E25,
				     0x2E26, 0x2E27, 0x2E28, 0x2E29,
				     0x3008, 0x3009, 0x300A, 0x300B, 0x300C, 0x300D,
				     0x300E, 0x300F, 0x3010, 0x3011, 0x3014, 0x3015,
				     0x3016, 0x3017, 0x3018, 0x3019, 0x301A, 0x301B,
				     0xFE59, 0xFE5A, 0xFE5B, 0xFE5C, 0xFE5D, 0xFE5E,
				     0xFF08, 0xFF09, 0xFF3B, 0xFF3D, 0xFF5B, 0xFF5D,
				     0xFF5F, 0xFF60, 0xFF62, 0xFF63:
					has_bracket = true
				}
			}
			bucket: ^int
			switch {
			case has_isolate: bucket = &bucket_isolate_fsi
			case has_embed:   bucket = &bucket_embed_format
			case has_bracket: bucket = &bucket_brackets
			case:             bucket = &bucket_other
			}
			bucket^ += 1
			if bucket^ <= print_cap {
				fmt.printfln("MISMATCH: %s", fields[0])
				fmt.printfln("  dir=%v expected=%v got=%v", bd_dir, want_levels, got_levels)
			}
		}
	}

	pct: f32 = 0
	if total > 0 { pct = 100.0 * f32(passed) / f32(total) }
	fmt.printfln("UAX #9 BidiCharacterTest: %d / %d passed (%.2f%%)  mismatches=%d", passed, total, pct, level_mismatches)
	fmt.println("---- mismatch buckets ----")
	fmt.printfln("  isolate/FSI:         %d", bucket_isolate_fsi)
	fmt.printfln("  embedding/override:  %d", bucket_embed_format)
	fmt.printfln("  brackets only:       %d", bucket_brackets)
	fmt.printfln("  other:               %d", bucket_other)
}

parse_codepoints :: proc(s: string) -> ([]rune, bool) {
	out := make([dynamic]rune, 0, 16)
	iter := s
	for tok in strings.fields_iterator(&iter) {
		v, p := strconv.parse_u64_of_base(tok, 16)
		if !p { delete(out); return nil, false }
		append(&out, rune(v))
	}
	return out[:], true
}

// parse_levels returns one entry per codepoint. 'x' becomes -1.
parse_levels :: proc(s: string) -> []int {
	out := make([dynamic]int, 0, 16)
	iter := s
	for tok in strings.fields_iterator(&iter) {
		if tok == "x" { append(&out, -1); continue }
		v, _ := strconv.parse_int(tok)
		append(&out, v)
	}
	return out[:]
}

string_from_runes :: proc(rs: []rune) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in rs { strings.write_rune(&b, r) }
	return strings.to_string(b)
}

// Unused fields-iter wrapper to avoid an import-warn on strings.fields.
@(private)
_unused := utf8.RUNE_ERROR
