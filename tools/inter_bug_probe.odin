/*
Repro tool for the Inter GSUB bug-report cases. Loads
InterVariable.ttf, applies each of the six v0.1 GSUB features in
isolation against four input strings, and dumps which feature
rewrote which glyphs.

Run:
    odin run tools/inter_bug_probe.odin -file
*/
package main

import "core:fmt"
import "core:os"

import runa  "../"
import parse "../parse"

main :: proc() {
	bytes, err := os.read_entire_file_from_path("tests/fonts/InterVariable.ttf", context.allocator)
	if err != nil { fmt.eprintfln("read: %v", err); os.exit(1) }
	defer delete(bytes)

	font, ferr := runa.font_load(bytes)
	if ferr != .None { fmt.eprintfln("load: %v", ferr); os.exit(1) }
	defer runa.font_destroy(&font)

	cases := [?]struct{ label, text: string }{
		{"(Tibs)",        "(Tibs)"},
		{". Excellent",   "n. Excellent"},
		{"prompt",        "prompt"},
		{"6595 tokens",   "6595 tokens"},
	}

	features := [?]string{"ccmp", "locl", "rlig", "liga", "clig", "calt"}

	for c in cases {
		fmt.printfln("=== %s : %q ===", c.label, c.text)

		raw := make([dynamic]parse.Glyph_ID, 0, len(c.text))
		defer delete(raw)
		for r in c.text { append(&raw, parse.cmap_lookup(&font._cmap, r)) }
		fmt.printfln("  cmap:     %v", raw[:])

		for ft in features {
			gids := make([dynamic]parse.Glyph_ID, 0, len(c.text))
			defer delete(gids)
			for g in raw { append(&gids, g) }
			parse.gsub_apply_feature(&font._gsub, &gids, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag(ft))
			changed := false
			if len(gids) != len(raw) { changed = true }
			else {
				for i in 0..<len(gids) {
					if gids[i] != raw[i] { changed = true; break }
				}
			}
			if changed {
				fmt.printfln("  +%-5s   %v", ft, gids[:])
			}
		}

		// Full pipeline (same as shape_run).
		pipe := make([dynamic]parse.Glyph_ID, 0, len(c.text))
		defer delete(pipe)
		for g in raw { append(&pipe, g) }
		for ft in features {
			parse.gsub_apply_feature(&font._gsub, &pipe, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag(ft))
		}
		fmt.printfln("  pipeline: %v", pipe[:])
		fmt.println()
	}
}
