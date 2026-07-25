/*
Probe for Arabic cursive joining across combining marks, checked against
HarfBuzz reference output. ArabicShaping.txt omits Joining_Type=T
characters; if runa defaults them to chain-breaking, a single fatha
severs joining and vocalised Arabic renders disconnected.

Run:
    odin run tools/arabic_join_probe.odin -file
*/
package main

import "core:fmt"
import "core:os"
import "core:strings"

import runa  "../"
import shape "../shape"
import parse "../parse"

NOTO_ARABIC :: "tests/fonts/NotoSansArabic-Regular.ttf"

shape_arabic :: proc(f: ^runa.Font, text: string) -> []parse.Glyph_ID {
	out := make([dynamic]shape.Shaped_Glyph, 0, 16, context.temp_allocator)
	inputs := shape.Shape_Inputs{
		cmap         = &f._cmap,
		hmtx         = &f._hmtx,
		gsub         = f._has_gsub ? &f._gsub : nil,
		gpos         = f._has_gpos ? &f._gpos : nil,
		units_per_em = f.units_per_em,
	}
	opts := shape.Shape_Run_Opts{script = parse.tag("arab"), language = parse.DFLT_LANG}
	shape.shape_run(&inputs, opts, text, 48.0, &out)

	gids := make([]parse.Glyph_ID, len(out), context.temp_allocator)
	for sg, i in out { gids[i] = sg.glyph_id }
	return gids
}

// shape_run emits logical order; HarfBuzz reports RTL runs in visual
// order. Reverse so the two are directly comparable.
as_visual :: proc(gids: []parse.Glyph_ID) -> []int {
	v := make([]int, len(gids), context.temp_allocator)
	for g, i in gids { v[len(gids) - 1 - i] = int(g) }
	return v
}

// render formats the gid list as "[a b c]". Built by hand because a
// width specifier on %v (e.g. "%-28v") zero-pads each element.
render :: proc(got: []int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for g, i in got {
		if i > 0 { strings.write_byte(&b, ' ') }
		strings.write_int(&b, g)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

main :: proc() {
	bytes, oerr := os.read_entire_file_from_path(NOTO_ARABIC, context.allocator)
	if oerr != nil { fmt.eprintln("cannot read", NOTO_ARABIC); os.exit(1) }
	defer delete(bytes)

	f, ferr := runa.font_load(bytes)
	if ferr != .None { fmt.eprintln("font_load:", ferr); os.exit(1) }
	defer runa.font_destroy(&f)

	fmt.println("--- joining_type of the harakat (expect T, not X) ---")
	marks := []struct{ cp: rune, name: string }{
		{0x064E, "FATHA"}, {0x064F, "DAMMA"}, {0x0650, "KASRA"},
		{0x0651, "SHADDA"}, {0x0652, "SUKUN"}, {0x0670, "SUPERSCRIPT ALEF"},
		{0x200D, "ZWJ (expect C)"}, {0x200C, "ZWNJ (expect U)"},
		{0x0628, "BEH (expect D)"}, {0x0627, "ALEF (expect R)"},
	}
	for m in marks {
		fmt.printfln("  U+%04X %-22s -> %v", m.cp, m.name, shape.joining_type(m.cp))
	}

	fmt.println("\n--- shaped output vs HarfBuzz ---")
	cases := []struct{ label, text, hb: string }{
		{"BEH BEH (no marks)",     "بب",       "[101 102]"},
		{"BEH FATHA BEH",          "بَب",      "[101 291 102]"},
		{"BEH FATHA BEH FATHA BEH","بَبَب",    "[101 291 104 291 102]"},
		{"MUHAMMAD (vocalised)",   "مُحَمَّد",   "[215 1161 773 291 419 235 771]"},
		{"LAM ALEF lig",           "لا",       "[704]"},
		{"LAM FATHA ALEF",         "لَا",      "[291 704]"},
	}
	for c in cases {
		gids := shape_arabic(&f, c.text)
		got := render(as_visual(gids))
		mark := got == c.hb ? "ok  " : "DIFF"
		fmt.printfln("  %s %-26s -> %-30s HB: %s", mark, c.label, got, c.hb)
		free_all(context.temp_allocator)
	}
}
