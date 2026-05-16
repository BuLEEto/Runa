/*
Rasterize a font glyph by ID (no shaping, no cmap) and ASCII-dump it.
Lets you compare e.g. Inter's `(` (gid 1437) against its calt variant
(gid 1446) to see what each looks like rendered.

Run:
    odin run tools/dump_gid.odin -file -- tests/fonts/InterVariable.ttf 1437 32
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"

import parse  "../parse"
import raster "../raster"

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: dump_gid <font.ttf> <gid> <size_px>")
		os.exit(2)
	}
	data, _ := os.read_entire_file_from_path(os.args[1], context.allocator)
	defer delete(data)

	gid_u, _ := strconv.parse_int(os.args[2])
	size, _ := strconv.parse_f32(os.args[3])
	if size <= 0 { size = 32 }

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	head_b, _ := parse.find_table(&idx, data, parse.tag("head"))
	head, _ := parse.parse_head(head_b)
	maxp_b, _ := parse.find_table(&idx, data, parse.tag("maxp"))
	mx, _ := parse.parse_maxp(maxp_b)
	loca_b, _ := parse.find_table(&idx, data, parse.tag("loca"))
	loca, _ := parse.parse_loca(loca_b, head.index_to_loc_format, mx.num_glyphs)
	defer parse.loca_destroy(&loca)
	glyf_b, _ := parse.find_table(&idx, data, parse.tag("glyf"))
	g := parse.new_glyf(glyf_b)

	out := parse.Outline{}
	defer parse.outline_destroy(&out)
	if err := parse.glyf_outline(&g, &loca, parse.Glyph_ID(u16(gid_u)), &out); err != .None {
		fmt.eprintfln("outline: %v", err); os.exit(1)
	}

	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)
	bm, x_off, y_off, rerr := raster.rasterize(&out, head.units_per_em, size, &edges)
	defer raster.bitmap_destroy(&bm)
	if rerr != .None { fmt.eprintfln("raster: %v", rerr); os.exit(1) }

	fmt.printfln("gid=%d size=%v width=%d height=%d xoff=%d yoff=%d", gid_u, size, bm.width, bm.height, x_off, y_off)
	ramp := []u8{' ', '.', ':', '-', '=', '+', '*', '#', '@'}
	for y in 0..<bm.height {
		for x in 0..<bm.width {
			a := bm.pixels[y * bm.width + x]
			idx := int(a) * (len(ramp) - 1) / 255
			fmt.printf("%c", rune(ramp[idx]))
		}
		fmt.println()
	}
}
