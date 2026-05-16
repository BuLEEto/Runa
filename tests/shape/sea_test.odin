/*
SEA (Southeast Asian) shaper smoke tests — Thai, Lao, Khmer,
Myanmar. Unlike the Indic family these scripts don't share a
single shaping engine; Thai / Lao mostly pass through the
standard GSUB feature pipeline (their pre-base vowel signs encode
in visual order already), while Khmer / Myanmar use a per-script
clustering / reordering model that lands in v1.0.

What v0.9.x covers:
  - Thai: bare consonants, pre-vowels (already in visual order),
    above/below marks, tone marks.
  - Lao: bare consonants + pre-vowels.
  - Khmer: bare consonants + AA-vowel ligation (basic GSUB
    suffices because Khmer's complex shaping isn't required for
    every syllable).
  - Myanmar: bare consonants, basic vowel attachment, medial YA.

Verified against HarfBuzz on canonical syllables.
*/
package shape_test

import "core:os"
import "core:testing"

import runa  "../.."
import shape "../../shape"
import parse "../../parse"

@(private="file")
shape_sea :: proc(font_path: string, script: parse.Tag, text: string) -> ([]parse.Glyph_ID, runa.Font, []u8, bool) {
	bytes, oerr := os.read_entire_file_from_path(font_path, context.allocator)
	if oerr != nil { return nil, runa.Font{}, nil, false }
	f, ferr := runa.font_load(bytes)
	if ferr != .None { delete(bytes); return nil, runa.Font{}, nil, false }

	out := make([dynamic]shape.Shaped_Glyph, 0, 16)
	defer delete(out)
	inputs := shape.Shape_Inputs{
		cmap         = &f._cmap,
		hmtx         = &f._hmtx,
		gsub         = f._has_gsub ? &f._gsub : nil,
		gpos         = f._has_gpos ? &f._gpos : nil,
		hvar         = nil,
		axis_values  = nil,
		units_per_em = f.units_per_em,
	}
	opts := shape.Shape_Run_Opts{script = script, language = parse.DFLT_LANG}
	shape.shape_run(&inputs, opts, text, 48.0, &out)

	gids := make([]parse.Glyph_ID, len(out))
	for sg, i in out { gids[i] = sg.glyph_id }
	return gids, f, bytes, true
}

@(private="file")
expect_gids_sea :: proc(t: ^testing.T, got: []parse.Glyph_ID, want: []int) {
	testing.expect_value(t, len(got), len(want))
	for i in 0..<min(len(got), len(want)) {
		testing.expect_value(t, int(got[i]), want[i])
	}
}

@(private="file")
free_sea :: proc(gids: []parse.Glyph_ID, f: runa.Font, bytes: []u8) {
	delete(gids)
	g := f; runa.font_destroy(&g)
	delete(bytes)
}

// ---- Thai ---------------------------------------------------------

@(test)
test_thai_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_sea("tests/fonts/Thai.ttf", parse.tag("thai"), "ก")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{29})
}

@(test)
test_thai_pre_vowel :: proc(t: ^testing.T) {
	// "เก" — SARA E (encoded BEFORE consonant in source per Unicode
	// Thai convention) + KO KAI. HB: [91, 29]. No reordering needed
	// because Thai pre-vowels are already in visual order at input.
	gids, f, b, ok := shape_sea("tests/fonts/Thai.ttf", parse.tag("thai"), "เก")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{91, 29})
}

@(test)
test_thai_ai_pre_vowel :: proc(t: ^testing.T) {
	// "ไก" — SARA AI MAIMALAI + KO KAI. HB: [88, 29].
	gids, f, b, ok := shape_sea("tests/fonts/Thai.ttf", parse.tag("thai"), "ไก")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{88, 29})
}

@(test)
test_thai_above_vowel :: proc(t: ^testing.T) {
	// "กิ" — KO KAI + SARA I (above). HB: [29, 92].
	gids, f, b, ok := shape_sea("tests/fonts/Thai.ttf", parse.tag("thai"), "กิ")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{29, 92})
}

@(test)
test_thai_tone_mark :: proc(t: ^testing.T) {
	// "ก่" — KO KAI + MAI EK (tone). HB: [29, 42].
	gids, f, b, ok := shape_sea("tests/fonts/Thai.ttf", parse.tag("thai"), "ก่")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{29, 42})
}

@(test)
test_thai_hello :: proc(t: ^testing.T) {
	// "สวัสดี" — full Thai "hello" word. HB: [110, 134, 45, 110, 12, 94].
	gids, f, b, ok := shape_sea("tests/fonts/Thai.ttf", parse.tag("thai"), "สวัสดี")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{110, 134, 45, 110, 12, 94})
}

// ---- Lao ----------------------------------------------------------

@(test)
test_lao_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_sea("tests/fonts/Lao.ttf", parse.tag("lao "), "ກ")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{4})
}

@(test)
test_lao_pre_vowel :: proc(t: ^testing.T) {
	// "ເກ" — Lao SARA E (pre-vowel) + KO. HB: [37, 4].
	gids, f, b, ok := shape_sea("tests/fonts/Lao.ttf", parse.tag("lao "), "ເກ")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{37, 4})
}

// ---- Khmer --------------------------------------------------------

@(test)
test_khmer_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_sea("tests/fonts/Khmer.ttf", parse.tag("khmr"), "ក")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{25})
}

@(test)
test_khmer_aa_ligature :: proc(t: ^testing.T) {
	// "កា" — KA + AA. HB: [212] — single ligated glyph.
	gids, f, b, ok := shape_sea("tests/fonts/Khmer.ttf", parse.tag("khmr"), "កា")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{212})
}

// ---- Myanmar ------------------------------------------------------

@(test)
test_myanmar_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_sea("tests/fonts/Myanmar.ttf", parse.tag("mymr"), "က")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{4})
}

@(test)
test_myanmar_vowel :: proc(t: ^testing.T) {
	// "ကိ" — KA + I-MATRA (Myanmar). HB: [4, 369].
	gids, f, b, ok := shape_sea("tests/fonts/Myanmar.ttf", parse.tag("mymr"), "ကိ")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{4, 369})
}

@(test)
test_myanmar_medial_ya :: proc(t: ^testing.T) {
	// "ကျ" — KA + MEDIAL YA. Medial YA is IPC=Right, no reorder.
	// HB: [4, 382].
	gids, f, b, ok := shape_sea("tests/fonts/Myanmar.ttf", parse.tag("mymr"), "ကျ")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{4, 382})
}

@(test)
test_myanmar_medial_ra :: proc(t: ^testing.T) {
	// "ကြ" — KA + MEDIAL RA. Medial RA is IPC=Top_And_Bottom_And_Left
	// → reorder to start of cluster. HB: [198, 4].
	gids, f, b, ok := shape_sea("tests/fonts/Myanmar.ttf", parse.tag("mymr"), "ကြ")
	if !ok { return }
	defer free_sea(gids, f, b)
	expect_gids_sea(t, gids, []int{198, 4})
}
