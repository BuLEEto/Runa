/*
Probe what `font_color_layers` returns + rasterize each layer separately
to see which ones produce non-empty bitmaps.
*/
package main

import "core:fmt"
import "core:os"

import runa   "../"
import parse  "../parse"
import raster "../raster"

main :: proc() {
	bytes, _ := os.read_entire_file_from_path("tests/fonts/Twemoji-Mozilla.ttf", context.allocator)
	defer delete(bytes)
	font, err := runa.font_load(bytes)
	if err != .None { fmt.eprintfln("err: %v", err); os.exit(1) }
	defer runa.font_destroy(&font)

	gid := runa.font_lookup_glyph(&font, '🦊')
	fmt.printfln("fox gid: %d  is_colr=%v", gid, runa.font_has_color_layers(&font, gid))

	layers, _ := runa.font_color_layers(&font, gid)
	defer delete(layers)
	fmt.printfln("layer count: %d", len(layers))

	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)

	for lyr, i in layers {
		c := parse.cpal_lookup(&font._cpal, 0, lyr.palette_index)
		out := parse.Outline{}
		defer parse.outline_destroy(&out)
		oerr := parse.glyf_outline(&font._glyf, &font._loca, lyr.glyph_id, &out)
		fmt.printfln("layer %d: gid=%d palette=%d color=#%02x%02x%02x%02x outline_pts=%d ends=%d outline_err=%v",
		             i, lyr.glyph_id, lyr.palette_index, c.r, c.g, c.b, c.a, len(out.points), len(out.contour_ends), oerr)

		if len(out.contour_ends) == 0 { continue }
		bm, xo, yo, rerr := raster.rasterize(&out, font.units_per_em, 64.0, &edges)
		fmt.printfln("   bm=%dx%d off=(%d,%d) rerr=%v", bm.width, bm.height, xo, yo, rerr)
		raster.bitmap_destroy(&bm)
	}
}
