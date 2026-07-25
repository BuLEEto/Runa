/*
Arabic Joining_Type lookup + state-machine tests.

Reference: UAX §9.2 Appendix B plus `ArabicShaping.txt`, which omits
Transparent characters by design — runa derives them from
General_Category Mn/Me/Cf.

Most tests here are font-independent and run in CI. The end-to-end one at
the bottom pins HarfBuzz gids and skips if the font is absent.
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
}

@(test)
test_joining_type_transparent_marks :: proc(t: ^testing.T) {
	// The Mn/Me/Cf derivation. Without it a single harakat severs the
	// cursive chain — see test_arabic_join_state_mark_is_transparent.
	for r in ([]rune{
		0x064E, // FATHA
		0x064F, // DAMMA
		0x0650, // KASRA
		0x0651, // SHADDA
		0x0652, // SUKUN
		0x0670, // SUPERSCRIPT ALEF
		0x0653, // MADDAH ABOVE
		0x0483, // COMBINING CYRILLIC TITLO (Mn, non-Arabic)
		0x0591, // HEBREW ACCENT ETNAHTA (Mn)
	}) {
		testing.expect_value(t, shape.joining_type(r), shape.Joining_Type.T)
	}

	// Explicit listing must win: both are Cf, so a naive derivation would
	// call them Transparent and break ZWJ joining / ZWNJ breaking.
	testing.expect_value(t, shape.joining_type(0x200D), shape.Joining_Type.C) // ZWJ
	testing.expect_value(t, shape.joining_type(0x200C), shape.Joining_Type.U) // ZWNJ
}

@(test)
test_arabic_join_state_mark_is_transparent :: proc(t: ^testing.T) {
	// "بَب" — the fatha passes through, leaving the BEHs joined to each
	// other. Pre-fix it resolved to .X, which breaks the chain, so all
	// three came out Isolated and vocalised Arabic rendered disconnected.
	runes := []rune{'ب', 0x064E, 'ب'}
	forms := make([]shape.Joining_Form, len(runes))
	defer delete(forms)
	shape.arabic_join_state(runes, forms)

	testing.expect_value(t, forms[0], shape.Joining_Form.Initial)
	testing.expect_value(t, forms[1], shape.Joining_Form.Isolated) // the mark itself
	testing.expect_value(t, forms[2], shape.Joining_Form.Final)
}

@(test)
test_arabic_join_state_multiple_marks_transparent :: proc(t: ^testing.T) {
	// Stacked marks must not break the chain either.
	runes := []rune{'ب', 0x064E, 0x064F, 'ب'}
	forms := make([]shape.Joining_Form, len(runes))
	defer delete(forms)
	shape.arabic_join_state(runes, forms)

	testing.expect_value(t, forms[0], shape.Joining_Form.Initial)
	testing.expect_value(t, forms[3], shape.Joining_Form.Final)
}

@(test)
test_arabic_join_state_zwnj_still_breaks :: proc(t: ^testing.T) {
	// ZWNJ is Cf but explicitly listed U, so it must still break the
	// chain despite the derivation.
	runes := []rune{'ب', 0x200C, 'ب'}
	forms := make([]shape.Joining_Form, len(runes))
	defer delete(forms)
	shape.arabic_join_state(runes, forms)

	testing.expect_value(t, forms[0], shape.Joining_Form.Isolated)
	testing.expect_value(t, forms[2], shape.Joining_Form.Isolated)
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
import runa  "../.."

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

// ---- End-to-end joining across marks -------------------------------

@(test)
test_arabic_vocalised_joins_end_to_end :: proc(t: ^testing.T) {
	// Full-pipeline check. Gids are HarfBuzz reference output for
	// NotoSansArabic-Regular.ttf, reversed — HarfBuzz reports RTL in
	// visual order, shape_run emits logical. Pre-fix every letter
	// position shaped to the isolated form (gid 100).
	bytes, err := os.read_entire_file_from_path(ARABIC_FONT, context.allocator)
	if err != nil {
		log.info("NotoSansArabic-Regular.ttf not present; skipping")
		return
	}
	defer delete(bytes)

	f, ferr := runa.font_load(bytes)
	if ferr != .None { log.info("font_load failed; skipping"); return }
	defer runa.font_destroy(&f)

	Case :: struct {
		text:     string,
		expected: []parse.Glyph_ID,   // logical order
	}
	cases := []Case{
		// HarfBuzz visual [101 102]         -> logical [102 101]
		{"بب",   {102, 101}},
		// HarfBuzz visual [101 291 102]     -> logical [102, 291, 101]
		{"بَب",  {102, 291, 101}},
		// HarfBuzz visual [101 291 104 291 102]
		{"بَبَب", {102, 291, 104, 291, 101}},
	}

	out := make([dynamic]shape.Shaped_Glyph, 0, 16)
	defer delete(out)

	for c in cases {
		clear(&out)
		inputs := shape.Shape_Inputs{
			cmap         = &f._cmap,
			hmtx         = &f._hmtx,
			gsub         = f._has_gsub ? &f._gsub : nil,
			gpos         = f._has_gpos ? &f._gpos : nil,
			units_per_em = f.units_per_em,
		}
		opts := shape.Shape_Run_Opts{script = parse.tag("arab"), language = parse.DFLT_LANG}
		shape.shape_run(&inputs, opts, c.text, 48.0, &out)

		if !testing.expect_value(t, len(out), len(c.expected)) { continue }
		for want, i in c.expected {
			testing.expect_value(t, out[i].glyph_id, want)
		}
	}
}
