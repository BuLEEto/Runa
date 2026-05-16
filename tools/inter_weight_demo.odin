/*
Render the same Inter glyph at three weight values to show that
gvar interpolation is actually working visually.

Run:
    odin run tools/inter_weight_demo.odin -file -o:speed
*/
package main

import "core:fmt"
import "core:os"

import runa   "../"
import raster "../raster"

main :: proc() {
	bytes, _ := os.read_entire_file_from_path("tests/fonts/InterVariable.ttf", context.allocator)
	defer delete(bytes)

	font, ferr := runa.font_load(bytes)
	if ferr != .None { fmt.eprintfln("load: %v", ferr); os.exit(1) }
	defer runa.font_destroy(&font)

	gid := runa.font_lookup_glyph(&font, 'a')
	WGHT :: runa.Axis_Tag(0x77676874)

	weights := [?]f32{100, 400, 700, 900}
	for w in weights {
		fmt.printfln("=== wght=%v ===", w)
		runa.font_set_variation(&font, WGHT, w)

		o := runa.Outline{}
		defer runa.outline_destroy(&o)
		runa.font_glyph_outline(&font, gid, &o)

		edges := make([dynamic]raster.Edge, 0, 128)
		defer delete(edges)
		bm, _, _, _ := raster.rasterize(&o, font.units_per_em, 32, &edges)
		defer raster.bitmap_destroy(&bm)

		ramp := []u8{' ', '.', ':', '-', '=', '+', '*', '#', '@'}
		for y in 0..<bm.height {
			for x in 0..<bm.width {
				a := bm.pixels[y * bm.width + x]
				idx := int(a) * (len(ramp) - 1) / 255
				fmt.printf("%c", rune(ramp[idx]))
			}
			fmt.println()
		}
		fmt.println()
	}
}
