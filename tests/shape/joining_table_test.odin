/*
Drift detector for the hard-coded Joining_Type=T table in
`shape/joining.odin`.

That table is frozen source text while the ArabicShaping.txt beside it is
`#load`-ed, so a UCD bump can desync them (16.0 → 17.0 moved 39
codepoints). Spot-checking runes doesn't catch it — whole ranges can go
missing with the suite still green. So sweep the full codepoint space.
The `#load` here is in the test binary; the library pays nothing.
*/
package shape_test

import "core:strconv"
import "core:strings"
import "core:testing"

import shape "../../shape"

@(private="file")
GC_DATA :: #load("../../tools/ucd/DerivedGeneralCategory.txt", string)

@(private="file")
AS_DATA :: #load("../../tools/ucd/ArabicShaping.txt", string)

// explicit_listing_set marks every codepoint ArabicShaping.txt names
// outright. Those override the derivation both ways — ZWJ/ZWNJ are Cf but
// listed C/U; U+1E94B is Lm but listed T — so only unlisted codepoints
// are answerable here.
@(private="file")
explicit_listing_set :: proc() -> []bool {
	set := make([]bool, 0x110000)
	data := AS_DATA
	for line in strings.split_lines_iterator(&data) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }
		if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
			trimmed = strings.trim_space(trimmed[:hash])
		}
		semi := strings.index_byte(trimmed, ';')
		if semi < 0 { continue }
		cp, ok := strconv.parse_u64_of_base(strings.trim_space(trimmed[:semi]), 16)
		if !ok || cp >= 0x110000 { continue }
		set[cp] = true
	}
	return set
}

// gc_transparent_set builds Mn/Me/Cf membership from the vendored UCD.
@(private="file")
gc_transparent_set :: proc() -> []bool {
	set := make([]bool, 0x110000)
	data := GC_DATA
	for line in strings.split_lines_iterator(&data) {
		trimmed := line
		if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
			trimmed = trimmed[:hash]
		}
		trimmed = strings.trim_space(trimmed)
		if len(trimmed) == 0 { continue }

		// Format: "0300..036F    ; Mn" or "05BF          ; Mn"
		semi := strings.index_byte(trimmed, ';')
		if semi < 0 { continue }
		cat := strings.trim_space(trimmed[semi + 1:])
		if cat != "Mn" && cat != "Me" && cat != "Cf" { continue }

		cp_field := strings.trim_space(trimmed[:semi])
		lo_str, hi_str := cp_field, cp_field
		if dots := strings.index(cp_field, ".."); dots >= 0 {
			lo_str = strings.trim_space(cp_field[:dots])
			hi_str = strings.trim_space(cp_field[dots + 2:])
		}
		lo, lo_ok := strconv.parse_u64_of_base(lo_str, 16)
		hi, hi_ok := strconv.parse_u64_of_base(hi_str, 16)
		if !lo_ok || !hi_ok || hi >= 0x110000 || lo > hi { continue }
		for cp in lo..=hi { set[cp] = true }
	}
	return set
}

@(test)
test_transparent_table_matches_ucd :: proc(t: ^testing.T) {
	want := gc_transparent_set()
	defer delete(want)

	// Sanity-check the parse itself. A floor, not the exact 2242, so a UCD
	// bump fails where it matters rather than here.
	total := 0
	for v in want { if v { total += 1 } }
	if !testing.expect(t, total > 2000, "DerivedGeneralCategory.txt parse found implausibly few Mn/Me/Cf codepoints") {
		return
	}

	listed := explicit_listing_set()
	defer delete(listed)

	missing, extra := 0, 0
	first_missing, first_extra: rune = -1, -1

	for cp in rune(0)..<rune(0x110000) {
		if listed[cp] { continue }
		got := shape.joining_type(cp) == .T
		if want[cp] == got { continue }
		if want[cp] {
			missing += 1
			if first_missing < 0 { first_missing = cp }
		} else {
			extra += 1
			if first_extra < 0 { first_extra = cp }
		}
	}

	testing.expectf(t, missing == 0,
		"%d Mn/Me/Cf codepoints missing from is_transparent_by_category (first U+%04X) — regenerate the table in shape/joining.odin",
		missing, first_missing)
	testing.expectf(t, extra == 0,
		"%d codepoints reported Transparent that are not Mn/Me/Cf (first U+%04X) — the table has drifted from the UCD",
		extra, first_extra)
}
