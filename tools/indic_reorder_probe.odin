/*
Probe for Indic reorder index arithmetic. Shapes a set of Devanagari
inputs designed to drive `identify_base` into its fallback path (where
`base_idx` can land on or past the syllable end) and dumps the glyph
order so we can see whether reorder_reph permutes glyphs it shouldn't.

Run:
    odin run tools/indic_reorder_probe.odin -file
*/
package main

import "core:fmt"
import "core:os"

import runa  "../"
import shape "../shape"
import parse "../parse"

NOTO_DEV :: "tests/fonts/NotoSansDevanagari.ttf"

shape_deva :: proc(f: ^runa.Font, text: string) -> []parse.Glyph_ID {
	out := make([dynamic]shape.Shaped_Glyph, 0, 16, context.temp_allocator)
	inputs := shape.Shape_Inputs{
		cmap         = &f._cmap,
		hmtx         = &f._hmtx,
		gsub         = f._has_gsub ? &f._gsub : nil,
		gpos         = f._has_gpos ? &f._gpos : nil,
		units_per_em = f.units_per_em,
	}
	opts := shape.Shape_Run_Opts{script = parse.tag("deva"), language = parse.DFLT_LANG}
	shape.shape_run(&inputs, opts, text, 48.0, &out)

	gids := make([]parse.Glyph_ID, len(out), context.temp_allocator)
	for sg, i in out { gids[i] = sg.glyph_id }
	return gids
}

main :: proc() {
	bytes, oerr := os.read_entire_file_from_path(NOTO_DEV, context.allocator)
	if oerr != nil { fmt.eprintln("cannot read", NOTO_DEV); os.exit(1) }
	defer delete(bytes)

	f, ferr := runa.font_load(bytes)
	if ferr != .None { fmt.eprintln("font_load:", ferr); os.exit(1) }
	defer runa.font_destroy(&f)

	// Per-codepoint gid, so we can tell which output glyph is which.
	fmt.println("--- reference gids ---")
	for r in ([]rune{0x0930, 0x094D, 0x0915, 0x0020, 'A'}) {
		fmt.printfln("  U+%04X -> gid %d", r, parse.cmap_lookup(&f._cmap, r))
	}

	cases := []struct{ label, text: string }{
		{"RA VIRAMA KA      (normal reph)",    "र्क"},
		{"RA VIRAMA         (lone reph)",      "र्"},
		{"RA VIRAMA SPACE   (reph + Other)",   "र् "},
		{"RA VIRAMA 'A'     (reph + Latin)",   "र्A"},
		{"RA VIRAMA SP KA   (reph, Other, C)", "र् क"},
		{"RA VIRAMA DANDA   (Devanagari '.')", "र्।"},
		{"RA VIRAMA COMMA",                    "र्,"},
		{"RA VIRAMA DIGIT-9",                  "र्९"},
		{"KA VIRAMA SPACE   (non-RA control)", "क् "},
		{"RA VIR A         (reph + ind.vowel)", "र्अ"},
		{"KA RA VIR A      (word ctx)",         "कर्अ"},
		{"RA VIR A IMATRA  (vowel + matra)",    "र्अि"},
		{"RA VIR A ANUSVARA",                   "र्अं"},
	}

	fmt.println("\n--- shaped output ---")
	for c in cases {
		gids := shape_deva(&f, c.text)
		fmt.printfln("  %-34s -> %v", c.label, gids)
		free_all(context.temp_allocator)
	}

	// Does this reach users through the real layout pipeline? That
	// depends on the itemizer keeping a Common-script space inside the
	// Devanagari run rather than splitting it off.
	fmt.println("\n--- through layout_paragraph (real pipeline) ---")
	font_list := []^runa.Font{&f}
	stack := runa.Font_Stack(font_list)
	for text in ([]string{"र् क", "कर् क", "अर् और"}) {
		lines, lerr := runa.layout_paragraph(text, runa.Paragraph_Opts{
			fonts = stack, size = 48.0, max_width = 10000,
		})
		if lerr != .None { fmt.printfln("  %q -> err %v", text, lerr); continue }
		fmt.printf("  %q ->", text)
		for &ln in lines {
			for g in ln.glyphs { fmt.printf(" %d", g.glyph_id) }
		}
		fmt.println()
		for &ln in lines { runa.line_destroy(&ln) }
		delete(lines)
	}
}
