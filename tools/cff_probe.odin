/*
Probe CFF table internals — verify the parser found the charstrings,
private dict, and subroutines correctly.
*/
package main

import "core:fmt"
import "core:os"

import runa  "../"
import parse "../parse"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: cff_probe <font.otf>")
		os.exit(2)
	}
	bytes, _ := os.read_entire_file_from_path(os.args[1], context.allocator)
	defer delete(bytes)

	font, ferr := runa.font_load(bytes)
	if ferr != .None { fmt.eprintfln("font_load: %v", ferr); os.exit(1) }
	defer runa.font_destroy(&font)

	fmt.printfln("has_cff=%v num_glyphs=%d", font._has_cff, font.num_glyphs)
	if !font._has_cff { fmt.eprintln("not a CFF font"); os.exit(0) }

	c := &font._cff
	fmt.printfln("cff: cs_count=%d gsubrs=%d lsubrs=%d cs_type=%d",
		c.charstrings_index.count, c.global_subrs.count, c.local_subrs.count, c.charstring_type)

	gid := runa.font_lookup_glyph(&font, 'A')
	fmt.printfln("'A' gid: %d", gid)

	cs := parse.cff_charstring_bytes(c, gid)
	fmt.printfln("charstring len: %d", len(cs))
	if len(cs) > 0 {
		// First 32 bytes as hex.
		fmt.printf("  bytes: ")
		max := min(len(cs), 32)
		for i in 0..<max { fmt.printf("%02x ", cs[i]) }
		fmt.println()
	}

	out := runa.Outline{}
	defer runa.outline_destroy(&out)
	err := parse.cff_glyph_outline(c, gid, &out)
	fmt.printfln("outline err=%v points=%d contours=%d bbox=(%d,%d)-(%d,%d)",
		err, len(out.points), len(out.contour_ends),
		out.x_min, out.y_min, out.x_max, out.y_max)
}
