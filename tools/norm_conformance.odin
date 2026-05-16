/*
UAX #15 NormalizationTest.txt conformance harness.

The test file ships 5 columns per row: source, NFC, NFD, NFKC,
NFKD. The conformance invariants per UAX #15 §6:

    c2 == toNFC(c1) == toNFC(c2) == toNFC(c3)
    c4 == toNFC(c4) == toNFC(c5)
    c3 == toNFD(c1) == toNFD(c2) == toNFD(c3)
    c5 == toNFD(c4) == toNFD(c5)
    c4 == toNFKC(c1..c5)
    c5 == toNFKD(c1..c5)

Run:
    odin run tools/norm_conformance.odin -file -o:speed
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "../normalize"

main :: proc() {
	data, err := os.read_entire_file_from_path("tools/ucd/NormalizationTest.txt", context.allocator)
	if err != nil { fmt.eprintfln("read: %v", err); os.exit(1) }
	defer delete(data)

	total, passed := 0, 0
	print_cap := 10
	mismatches := 0
	bad: [6]int

	iter := string(data)
	for line in strings.split_lines_iterator(&iter) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' || t[0] == '@' { continue }
		// Strip comment.
		if hash := strings.index_byte(t, '#'); hash >= 0 {
			t = strings.trim_space(t[:hash])
		}
		// 5 columns separated by ; (final ; before comment included).
		cols: [5]string
		n := 0
		s := t
		for n < 5 {
			semi := strings.index_byte(s, ';')
			if semi < 0 { break }
			cols[n] = strings.trim_space(s[:semi])
			n += 1
			s = s[semi + 1:]
		}
		if n < 5 { continue }
		c := [5]string{
			decode_cps(cols[0]),
			decode_cps(cols[1]),
			decode_cps(cols[2]),
			decode_cps(cols[3]),
			decode_cps(cols[4]),
		}

		ok := true
		// NFC invariants.
		for src_idx in 0..<3 {
			got := normalize.to_nfc(c[src_idx], context.temp_allocator)
			if got != c[1] { ok = false; bad[0] += 1 }
		}
		for src_idx in 3..<5 {
			got := normalize.to_nfc(c[src_idx], context.temp_allocator)
			if got != c[3] { ok = false; bad[1] += 1 }
		}
		// NFD invariants.
		for src_idx in 0..<3 {
			got := normalize.to_nfd(c[src_idx], context.temp_allocator)
			if got != c[2] { ok = false; bad[2] += 1 }
		}
		for src_idx in 3..<5 {
			got := normalize.to_nfd(c[src_idx], context.temp_allocator)
			if got != c[4] { ok = false; bad[3] += 1 }
		}
		// NFKC: all 5 sources should normalize to c4.
		for src_idx in 0..<5 {
			got := normalize.to_nfkc(c[src_idx], context.temp_allocator)
			if got != c[3] { ok = false; bad[4] += 1 }
		}
		// NFKD: all 5 sources should normalize to c5.
		for src_idx in 0..<5 {
			got := normalize.to_nfkd(c[src_idx], context.temp_allocator)
			if got != c[4] { ok = false; bad[5] += 1 }
		}

		total += 1
		if ok {
			passed += 1
		} else {
			mismatches += 1
			if mismatches <= print_cap {
				fmt.printfln("MISMATCH: %s", t)
				for i in 0..<5 {
					fmt.printfln("  c%d=%s", i + 1, hex_of(c[i]))
				}
				fmt.printfln("  NFC(c1)=%s",  hex_of(normalize.to_nfc(c[0], context.temp_allocator)))
				fmt.printfln("  NFD(c1)=%s",  hex_of(normalize.to_nfd(c[0], context.temp_allocator)))
				fmt.printfln("  NFKC(c1)=%s", hex_of(normalize.to_nfkc(c[0], context.temp_allocator)))
				fmt.printfln("  NFKD(c1)=%s", hex_of(normalize.to_nfkd(c[0], context.temp_allocator)))
			}
		}
	}

	pct: f32 = 0
	if total > 0 { pct = 100.0 * f32(passed) / f32(total) }
	fmt.printfln("UAX #15 NormalizationTest: %d / %d passed (%.2f%%)  mismatches=%d", passed, total, pct, mismatches)
	fmt.printfln("  failures by check: NFC=%d NFC[2]=%d NFD=%d NFD[2]=%d NFKC=%d NFKD=%d", bad[0], bad[1], bad[2], bad[3], bad[4], bad[5])
}

decode_cps :: proc(field: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := field
	for tok in strings.split_iterator(&rest, " ") {
		if len(tok) == 0 { continue }
		v, ok := strconv.parse_u64_of_base(tok, 16)
		if !ok { continue }
		strings.write_rune(&b, rune(v))
	}
	return strings.to_string(b)
}

hex_of :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	first := true
	rest := s
	for len(rest) > 0 {
		r: rune
		sz: int
		r, sz = decode_one(rest)
		if !first { strings.write_byte(&b, ' ') }
		first = false
		strings.write_string(&b, fmt.tprintf("%04X", r))
		rest = rest[sz:]
	}
	return strings.to_string(b)
}

decode_one :: proc(s: string) -> (rune, int) {
	if len(s) == 0 { return 0, 0 }
	b := s[0]
	switch {
	case b < 0x80: return rune(b), 1
	case b < 0xC0: return 0xFFFD, 1
	case b < 0xE0:
		if len(s) < 2 { return 0xFFFD, 1 }
		return rune(b & 0x1F) << 6 | rune(s[1] & 0x3F), 2
	case b < 0xF0:
		if len(s) < 3 { return 0xFFFD, 1 }
		return rune(b & 0x0F) << 12 | rune(s[1] & 0x3F) << 6 | rune(s[2] & 0x3F), 3
	case:
		if len(s) < 4 { return 0xFFFD, 1 }
		return rune(b & 0x07) << 18 | rune(s[1] & 0x3F) << 12 | rune(s[2] & 0x3F) << 6 | rune(s[3] & 0x3F), 4
	}
}
