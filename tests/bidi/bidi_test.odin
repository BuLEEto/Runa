/*
UAX #9 foundation tests: Bidi_Class lookup + paragraph direction
detection. Full UAX #9 X-rule conformance against BidiTest.txt
arrives with the embedding-level resolver.
*/
package bidi_test

import "core:testing"

import bd "../../bidi"

@(test)
test_bidi_class_basic :: proc(t: ^testing.T) {
	testing.expect_value(t, bd.bidi_class('A'), bd.Bidi_Class.L)
	testing.expect_value(t, bd.bidi_class('z'), bd.Bidi_Class.L)
	testing.expect_value(t, bd.bidi_class('1'), bd.Bidi_Class.EN)
	testing.expect_value(t, bd.bidi_class(' '), bd.Bidi_Class.WS)
	testing.expect_value(t, bd.bidi_class('.'), bd.Bidi_Class.CS)
	// Hebrew letter alef — strong R.
	testing.expect_value(t, bd.bidi_class('א'), bd.Bidi_Class.R)
	// Arabic letter — strong AL.
	testing.expect_value(t, bd.bidi_class('ا'), bd.Bidi_Class.AL)
	// Combining acute — NSM.
	testing.expect_value(t, bd.bidi_class(0x0301), bd.Bidi_Class.NSM)
}

@(test)
test_paragraph_direction_latin :: proc(t: ^testing.T) {
	testing.expect_value(t, bd.paragraph_direction("Hello, world!"), bd.Direction.LTR)
}

@(test)
test_paragraph_direction_hebrew :: proc(t: ^testing.T) {
	testing.expect_value(t, bd.paragraph_direction("שלום עולם"), bd.Direction.RTL)
}

@(test)
test_paragraph_direction_arabic :: proc(t: ^testing.T) {
	testing.expect_value(t, bd.paragraph_direction("مرحبا بالعالم"), bd.Direction.RTL)
}

@(test)
test_paragraph_direction_mixed_first_strong_wins :: proc(t: ^testing.T) {
	// Leading punctuation (neutral) shouldn't sway the result — the
	// first *strong* character does.
	testing.expect_value(t, bd.paragraph_direction(`"Hello" שלום`),  bd.Direction.LTR)
	testing.expect_value(t, bd.paragraph_direction(`"שלום" Hello`), bd.Direction.RTL)
}

@(test)
test_resolve_levels_pure_ltr :: proc(t: ^testing.T) {
	levels, idx := bd.resolve_levels("Hello", .LTR)
	defer delete(levels)
	defer delete(idx)
	testing.expect_value(t, len(levels), 5)
	for l in levels { testing.expect_value(t, l, u8(0)) }
}

@(test)
test_resolve_levels_pure_rtl :: proc(t: ^testing.T) {
	// "שלום" — 4 Hebrew letters. With base RTL, all 4 land at level 1.
	levels, idx := bd.resolve_levels("שלום", .RTL)
	defer delete(levels)
	defer delete(idx)
	testing.expect_value(t, len(levels), 4)
	for l in levels { testing.expect_value(t, l, u8(1)) }
}

@(test)
test_resolve_levels_mixed_ltr_para :: proc(t: ^testing.T) {
	// "Hi שלום" — base LTR. "Hi " stays L level 0, "שלום" goes to
	// level 1 (I1 bumps R chars to next odd).
	levels, idx := bd.resolve_levels("Hi שלום", .LTR)
	defer delete(levels)
	defer delete(idx)
	testing.expect_value(t, len(levels), 7)
	// 'H', 'i', ' ', then 4 Hebrew chars.
	testing.expect_value(t, levels[0], u8(0))           // 'H'
	testing.expect_value(t, levels[1], u8(0))           // 'i'
	testing.expect_value(t, levels[2], u8(0))           // ' ' between LTR runs stays 0 (N1)
	testing.expect_value(t, levels[3], u8(1))           // ש
	testing.expect_value(t, levels[6], u8(1))           // ם
}

@(test)
test_resolve_levels_numbers_in_rtl :: proc(t: ^testing.T) {
	// "א 123 ב" — Hebrew letters around Arabic numerals. In RTL
	// paragraph, EN runs at level 2 (one above the RTL embedding).
	levels, idx := bd.resolve_levels("א 123 ב", .RTL)
	defer delete(levels)
	defer delete(idx)
	testing.expect_value(t, levels[0], u8(1))           // א
	testing.expect_value(t, levels[2], u8(2))           // '1' (EN at level 2)
	testing.expect_value(t, levels[3], u8(2))           // '2'
	testing.expect_value(t, levels[4], u8(2))           // '3'
	testing.expect_value(t, levels[6], u8(1))           // ב
}

@(test)
test_reorder_runs_pure_rtl :: proc(t: ^testing.T) {
	text := "שלום"
	levels, idx := bd.resolve_levels(text, .RTL)
	defer delete(levels)
	defer delete(idx)
	runs := bd.reorder_runs(levels, idx, text)
	defer delete(runs)
	// One contiguous level-1 run; reorder reverses it (visual = one
	// run encompassing the whole text, drawn right-to-left).
	testing.expect_value(t, len(runs), 1)
	testing.expect_value(t, runs[0].level, u8(1))
}

@(test)
test_reorder_runs_mixed :: proc(t: ^testing.T) {
	// LTR para with embedded Hebrew: visual order should be
	// [LTR-prefix, RTL-run-reversed, LTR-suffix].
	text := "abc שלום xyz"
	levels, idx := bd.resolve_levels(text, .LTR)
	defer delete(levels)
	defer delete(idx)
	runs := bd.reorder_runs(levels, idx, text)
	defer delete(runs)
	// Three runs: "abc ", "שלום", " xyz" with levels 0, 1, 0.
	testing.expect(t, len(runs) >= 3, "at least three runs")
	// In LTR base, runs stay in logical order (no swap).
	testing.expect_value(t, runs[0].level, u8(0))
}

@(test)
test_x_rule_rli_pdi_isolate :: proc(t: ^testing.T) {
	// "A⁧B⁩C" — A (L), RLI, B (L), PDI, C (L).
	// In an LTR paragraph: A is level 0, RLI/PDI assigned level 0,
	// B inside the RLI isolate gets level 1 (next odd) but is L so
	// I2 bumps to level 2. C resumes at level 0.
	text := "A⁧B⁩C"
	levels, idx := bd.resolve_levels(text, .LTR)
	defer delete(levels)
	defer delete(idx)

	testing.expect_value(t, len(levels), 5)
	testing.expect_value(t, levels[0], u8(0))           // A
	// levels[1] is the RLI char — should land at level 0 (the
	// paragraph base, assigned BEFORE pushing).
	testing.expect_value(t, levels[1], u8(0))
	// 'B' is inside the RLI isolate at base level 1 (odd). It's
	// class L, so I2 applies: bumps to level 2.
	testing.expect_value(t, levels[2], u8(2))
	// PDI assigned the current (now-popped) level which is 0.
	testing.expect_value(t, levels[3], u8(0))
	testing.expect_value(t, levels[4], u8(0))           // C
}

@(test)
test_n0_brackets_in_rtl :: proc(t: ^testing.T) {
	// "A(B)C" where A/B/C are Hebrew letters → the parens should
	// take RTL direction too (N0.b: matching strong type found
	// inside the pair).
	levels, idx := bd.resolve_levels("א(ב)ג", .RTL)
	defer delete(levels)
	defer delete(idx)
	testing.expect_value(t, len(levels), 5)
	// Every codepoint should land at level 1 — the parens get
	// resolved to R by N0 because the bracket content is R.
	for i in 0..<5 {
		testing.expect_value(t, levels[i], u8(1))
	}
}

@(test)
test_brackets_table_basics :: proc(t: ^testing.T) {
	testing.expect_value(t, bd.bidi_paired_bracket_type('('), bd.Bracket_Type.Open)
	testing.expect_value(t, bd.bidi_paired_bracket_type(')'), bd.Bracket_Type.Close)
	testing.expect_value(t, bd.bidi_paired_bracket('('),       ')')
	testing.expect_value(t, bd.bidi_paired_bracket(')'),       '(')
	testing.expect_value(t, bd.bidi_paired_bracket_type('a'),  bd.Bracket_Type.None)
	testing.expect_value(t, bd.bidi_paired_bracket('a'),       rune(0))
}

@(test)
test_paragraph_direction_no_strong :: proc(t: ^testing.T) {
	// Digits are EN, not strong. Pure-numeric paragraph has no
	// directional preference.
	testing.expect_value(t, bd.paragraph_direction("123 456"), bd.Direction.Neutral)
	testing.expect_value(t, bd.paragraph_direction(""),         bd.Direction.Neutral)
}
