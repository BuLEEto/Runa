/*
Smoke tests for the rest of the Brahmic family beyond Devanagari /
Bengali / Tamil — Telugu, Kannada, Malayalam, Gujarati, Gurmukhi,
and Odia. Each test shapes a 1-3 codepoint canonical syllable and
compares the gid sequence against HarfBuzz's reference output for
the same font.

Per-script quirks the Indic pipeline already handles:
  - Telugu / Malayalam / Gurmukhi: no reph (script_uses_reph
    returns false).
  - Kannada / Gujarati / Odia: reph + pre-base matra, just like
    Devanagari.
  - Tamil: no reph, IPC=Right matras (no pre-base reorder).
*/
package shape_test

import "core:os"
import "core:testing"

import runa  "../.."
import shape "../../shape"
import parse "../../parse"

@(private="file")
shape_indic :: proc(font_path: string, script: parse.Tag, text: string) -> ([]parse.Glyph_ID, runa.Font, []u8, bool) {
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
expect_gids :: proc(t: ^testing.T, got: []parse.Glyph_ID, want: []int) {
	testing.expect_value(t, len(got), len(want))
	for i in 0..<min(len(got), len(want)) {
		testing.expect_value(t, int(got[i]), want[i])
	}
}

@(private="file")
free_indic :: proc(gids: []parse.Glyph_ID, f: runa.Font, bytes: []u8) {
	delete(gids)
	g := f; runa.font_destroy(&g)
	delete(bytes)
}

// ---- Telugu --------------------------------------------------------

@(test)
test_telugu_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_indic("tests/fonts/Telugu.ttf", parse.tag("telu"), "క")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{23})
}

@(test)
test_telugu_kii_psts_ligature :: proc(t: ^testing.T) {
	// HarfBuzz: [211] — single composed glyph (psts ligation).
	gids, f, b, ok := shape_indic("tests/fonts/Telugu.ttf", parse.tag("telu"), "కీ")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{211})
}

// ---- Kannada -------------------------------------------------------

@(test)
test_kannada_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_indic("tests/fonts/Kannada.ttf", parse.tag("knda"), "ಕ")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{23})
}

@(test)
test_kannada_reph :: proc(t: ^testing.T) {
	// HarfBuzz: [23, 93] — base k + reph mark.
	gids, f, b, ok := shape_indic("tests/fonts/Kannada.ttf", parse.tag("knda"), "ರ್ಕ")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{23, 93})
}

// ---- Malayalam -----------------------------------------------------

@(test)
test_malayalam_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_indic("tests/fonts/Malayalam.ttf", parse.tag("mlym"), "ക")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{23})
}

@(test)
test_malayalam_kta_full_conjunct :: proc(t: ^testing.T) {
	// HarfBuzz: [164] — full conjunct ligation.
	gids, f, b, ok := shape_indic("tests/fonts/Malayalam.ttf", parse.tag("mlym"), "ക്ത")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{164})
}

// ---- Gujarati ------------------------------------------------------

@(test)
test_gujarati_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_indic("tests/fonts/Gujarati.ttf", parse.tag("gujr"), "ક")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{21})
}

@(test)
test_gujarati_pre_base_matra :: proc(t: ^testing.T) {
	// HarfBuzz: [627, 21] — i-matra reordered before base k.
	gids, f, b, ok := shape_indic("tests/fonts/Gujarati.ttf", parse.tag("gujr"), "કિ")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{627, 21})
}

@(test)
test_gujarati_reph :: proc(t: ^testing.T) {
	// HarfBuzz: [21, 676] — base k + reph.
	gids, f, b, ok := shape_indic("tests/fonts/Gujarati.ttf", parse.tag("gujr"), "ર્ક")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{21, 676})
}

// ---- Gurmukhi ------------------------------------------------------

@(test)
test_gurmukhi_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_indic("tests/fonts/Gurmukhi.ttf", parse.tag("guru"), "ਕ")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{17})
}

@(test)
test_gurmukhi_pre_base_matra :: proc(t: ^testing.T) {
	// HarfBuzz: [52, 17] — i-matra reordered before base.
	gids, f, b, ok := shape_indic("tests/fonts/Gurmukhi.ttf", parse.tag("guru"), "ਕਿ")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{52, 17})
}

// ---- Odia ----------------------------------------------------------

@(test)
test_odia_ka :: proc(t: ^testing.T) {
	gids, f, b, ok := shape_indic("tests/fonts/Oriya.ttf", parse.tag("orya"), "କ")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{20})
}

@(test)
test_odia_kta_conjunct :: proc(t: ^testing.T) {
	// HarfBuzz: [253] — full conjunct ligation.
	gids, f, b, ok := shape_indic("tests/fonts/Oriya.ttf", parse.tag("orya"), "କ୍ତ")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{253})
}

@(test)
test_odia_reph :: proc(t: ^testing.T) {
	// HarfBuzz: [20, 82] — base k + reph.
	gids, f, b, ok := shape_indic("tests/fonts/Oriya.ttf", parse.tag("orya"), "ର୍କ")
	if !ok { return }
	defer free_indic(gids, f, b)
	expect_gids(t, gids, []int{20, 82})
}
