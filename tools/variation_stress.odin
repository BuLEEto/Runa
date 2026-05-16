/*
Stress the variable-font pipeline: random axis values × every glyph
outline × every glyph advance. Confirms gvar / HVAR / MVAR don't
panic on arbitrary axis tuples or any glyph in the font.

Run:
    odin run tools/variation_stress.odin -file -o:speed
*/
package main

import "core:fmt"
import "core:math/rand"
import "core:os"

import runa "../"

main :: proc() {
	bytes, _ := os.read_entire_file_from_path("tests/fonts/InterVariable.ttf", context.allocator)
	defer delete(bytes)
	font, err := runa.font_load(bytes)
	if err != .None { fmt.eprintfln("load: %v", err); os.exit(1) }
	defer runa.font_destroy(&font)

	axes := runa.font_axes(&font)
	fmt.printfln("axes=%d glyphs=%d", len(axes), font.num_glyphs)

	rand.reset(0x5EED)

	ITERS :: 200                              // distinct axis tuples
	out := runa.Outline{}
	defer runa.outline_destroy(&out)

	for iter in 0..<ITERS {
		// Pick a random user-coord per axis in [min, max].
		for ax in axes {
			t := rand.float32()
			v := ax.min_value + t * (ax.max_value - ax.min_value)
			runa.font_set_variation(&font, ax.tag, v)
		}
		// Walk every glyph: outline + advance.
		for gid_u in 0..<int(font.num_glyphs) {
			gid := runa.Glyph_ID(gid_u)
			_ = runa.font_glyph_outline(&font, gid, &out)
			_ = runa.font_glyph_advance(&font, gid)
		}
		if iter % 50 == 0 {
			fmt.printfln("  iter %d/%d ok", iter, ITERS)
		}
	}
	fmt.println("variation stress passed — no panics")
}
