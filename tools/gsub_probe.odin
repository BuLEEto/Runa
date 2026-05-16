/*
Probe a font's GSUB table — list which lookup indices are wired to the
`liga` feature under (latn, dflt) and what type each one is. Useful
for sanity-checking shaper integration.

Run:
    odin run tools/gsub_probe.odin -file -- tests/fonts/FiraCode-Regular.ttf
*/
package main

import "core:fmt"
import "core:os"

import parse "../parse"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: gsub_probe <font.ttf>")
		os.exit(2)
	}
	data, rerr := os.read_entire_file_from_path(os.args[1], context.allocator)
	if rerr != nil { fmt.eprintfln("read: %v", rerr); os.exit(1) }

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	if !parse.has_table(&idx, parse.tag("GSUB")) {
		fmt.println("no GSUB table")
		return
	}
	gsub_bytes, _ := parse.find_table(&idx, data, parse.tag("GSUB"))
	g, err := parse.new_gsub(gsub_bytes)
	if err != .None { fmt.eprintfln("new_gsub: %v", err); os.exit(1) }

	features := [?]parse.Tag{
		parse.tag("liga"), parse.tag("clig"), parse.tag("calt"),
		parse.tag("rlig"), parse.tag("locl"), parse.tag("ccmp"),
	}
	for ft in features {
		ll, _ := parse.gsub_resolve_feature_lookups(&g, parse.LATN_SCRIPT, parse.DFLT_LANG, ft)
		defer delete(ll)
		fmt.printf("feature ")
		for c in tag_to_chars(ft) { fmt.printf("%c", c) }
		fmt.printf(": %d lookups", len(ll))
		for li in ll {
			li_info, _ := parse.gsub_get_lookup(&g, li)
			defer parse.lookup_info_destroy(&li_info)
			fmt.printf(" [#%d type=%d subs=%d]", li, li_info.type, len(li_info.subtable_offsets))
		}
		fmt.println()
	}

	// Reproduce "fi" → fi.
	if !parse.has_table(&idx, parse.tag("cmap")) { return }
	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	// Probe a few canonical programming-font ligatures.
	probe :: proc(g: ^parse.Gsub, cm: ^parse.Cmap, label: string, runes: []rune) {
		gids := make([dynamic]parse.Glyph_ID, 0, 8)
		defer delete(gids)
		for r in runes { append(&gids, parse.cmap_lookup(cm, r)) }
		before := fmt.tprintf("%v", gids[:])
		parse.gsub_apply_feature(g, &gids, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("calt"))
		parse.gsub_apply_feature(g, &gids, parse.DFLT_SCRIPT, parse.DFLT_LANG, parse.tag("calt"))
		fmt.printfln("  %s before=%s after=%v", label, before, gids[:])
	}

	probe(&g, &cm, "->",  []rune{'-', '>'})
	probe(&g, &cm, "=>",  []rune{'=', '>'})
	probe(&g, &cm, "==",  []rune{'=', '='})
	probe(&g, &cm, "===", []rune{'=', '=', '='})
	probe(&g, &cm, "!=",  []rune{'!', '='})
	probe(&g, &cm, "::",  []rune{':', ':'})
	probe(&g, &cm, ":=",  []rune{':', '='})

	gids := make([dynamic]parse.Glyph_ID, 0, 4)
	defer delete(gids)
	append(&gids, parse.cmap_lookup(&cm, '!'))
	append(&gids, parse.cmap_lookup(&cm, '='))

	liga_n := parse.gsub_apply_feature(&g, &gids, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("liga"))
	calt_n := parse.gsub_apply_feature(&g, &gids, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("calt"))
	fmt.printfln("'!=' after shaping (liga=%d, calt=%d subs): %v", liga_n, calt_n, gids[:])

	// Same again under DFLT/dflt, in case features hang off the default
	// script slot instead.
	dflt_n := parse.gsub_apply_feature(&g, &gids, parse.DFLT_SCRIPT, parse.DFLT_LANG, parse.tag("calt"))
	fmt.printfln("'!=' after DFLT calt (%d subs): %v", dflt_n, gids[:])
}

@(private)
tag_to_chars :: proc(t: parse.Tag) -> [4]u8 {
	v := u32(t)
	return [4]u8{u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}
}
