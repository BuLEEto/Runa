/*
Arabic Joining_Type lookup + state-machine tests.

Reference: the spec's Arabic shaping tables (UAX §9.2 Appendix B).
We don't claim full conformance against the test vectors yet —
runa's GSUB integration of init/medi/fina/isol features is the next
step — but the joining state itself must agree with the spec on
canonical Arabic strings.
*/
package shape_test

import "core:testing"

import shape "../../shape"

@(test)
test_joining_type_basic :: proc(t: ^testing.T) {
	// Alef (ا) is Right-joining (R).
	testing.expect_value(t, shape.joining_type('ا'), shape.Joining_Type.R)
	// Beh (ب) is Dual-joining (D).
	testing.expect_value(t, shape.joining_type('ب'), shape.Joining_Type.D)
	// Tatweel (ـ) is Join-Causing (C).
	testing.expect_value(t, shape.joining_type('ـ'), shape.Joining_Type.C)
	// Latin letter — not Arabic — should fall to X.
	testing.expect_value(t, shape.joining_type('a'), shape.Joining_Type.X)
	// Arabic combining marks (e.g. U+0670 ARABIC LETTER SUPERSCRIPT
	// ALEF) are Transparent per UAX #9, but ArabicShaping.txt lists
	// them implicitly via "default to T for general category Mn/Cf".
	// runa doesn't yet read general-category data for joining defaults
	// — these characters currently fall through to .X. Track for
	// fix when the Arabic shaper integrates with GSUB.
}

@(test)
test_arabic_join_state_simple :: proc(t: ^testing.T) {
	// "بنت" — three Dual-joining letters. Expected forms:
	//   ب (D) at start → Initial
	//   ن (D) middle  → Medial
	//   ت (D) end     → Final
	runes := []rune{'ب', 'ن', 'ت'}
	forms := make([]shape.Joining_Form, len(runes))
	defer delete(forms)
	shape.arabic_join_state(runes, forms)

	testing.expect_value(t, forms[0], shape.Joining_Form.Initial)
	testing.expect_value(t, forms[1], shape.Joining_Form.Medial)
	testing.expect_value(t, forms[2], shape.Joining_Form.Final)
}

@(test)
test_arabic_join_state_alef_breaks_chain :: proc(t: ^testing.T) {
	// "باب" — Beh, Alef, Beh. Alef is R (right-joining only), so
	// the chain after Alef can't carry: ب → ا → ب becomes
	// Initial → Final → Isolated.
	runes := []rune{'ب', 'ا', 'ب'}
	forms := make([]shape.Joining_Form, len(runes))
	defer delete(forms)
	shape.arabic_join_state(runes, forms)

	testing.expect_value(t, forms[0], shape.Joining_Form.Initial)
	testing.expect_value(t, forms[1], shape.Joining_Form.Final)
	testing.expect_value(t, forms[2], shape.Joining_Form.Isolated)
}

@(test)
test_arabic_join_state_isolated_alef :: proc(t: ^testing.T) {
	// A lone Alef → Isolated.
	runes := []rune{'ا'}
	forms := make([]shape.Joining_Form, 1)
	defer delete(forms)
	shape.arabic_join_state(runes, forms)
	testing.expect_value(t, forms[0], shape.Joining_Form.Isolated)
}

import "core:log"
import "core:os"
import parse "../../parse"

ARABIC_FONT :: "tests/fonts/NotoSansArabic-Regular.ttf"

@(test)
test_arabic_per_position_substitution :: proc(t: ^testing.T) {
	// Shape "بنت" (three Dual-joining letters → Initial / Medial /
	// Final). Each glyph must receive a different per-position
	// substitution; the base (isolated) cmap glyph IDs should change
	// for at least two of the three positions.
	bytes, err := os.read_entire_file_from_path(ARABIC_FONT, context.allocator)
	if err != nil {
		log.info("NotoSansArabic-Regular.ttf not present; skipping")
		return
	}
	defer delete(bytes)

	idx, _ := parse.parse_table_index(bytes)
	defer parse.table_index_destroy(&idx)

	cmap_b, _ := parse.find_table(&idx, bytes, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	gsub_b, _ := parse.find_table(&idx, bytes, parse.tag("GSUB"))
	g, _ := parse.new_gsub(gsub_b)

	base := [3]parse.Glyph_ID{
		parse.cmap_lookup(&cm, 'ب'),
		parse.cmap_lookup(&cm, 'ن'),
		parse.cmap_lookup(&cm, 'ت'),
	}
	runes := []rune{'ب', 'ن', 'ت'}
	forms := make([]shape.Joining_Form, len(runes))
	defer delete(forms)
	shape.arabic_join_state(runes, forms)

	testing.expect_value(t, forms[0], shape.Joining_Form.Initial)
	testing.expect_value(t, forms[1], shape.Joining_Form.Medial)
	testing.expect_value(t, forms[2], shape.Joining_Form.Final)

	// Apply per-position substitution and verify each cell rewrites
	// to a different glyph than the isolated cmap result.
	out_gids := make([]parse.Glyph_ID, 3)
	defer delete(out_gids)
	copy(out_gids, base[:])

	feats := [?]string{"init", "medi", "fina"}
	for i in 0..<3 {
		parse.gsub_apply_single_at(&g, out_gids, i,
			parse.tag("arab"), parse.DFLT_LANG, parse.tag(feats[i]))
	}

	changed := 0
	for i in 0..<3 {
		if out_gids[i] != base[i] { changed += 1 }
	}
	testing.expect(t, changed >= 2, "at least two positions get a per-form substitute")
}

@(test)
test_arabic_join_state_non_arabic_does_nothing :: proc(t: ^testing.T) {
	runes := []rune{'a', 'b', 'c'}
	forms := make([]shape.Joining_Form, 3)
	defer delete(forms)
	shape.arabic_join_state(runes, forms)
	for f in forms {
		testing.expect_value(t, f, shape.Joining_Form.Isolated)
	}
}
