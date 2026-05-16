/*
Quick visual smoke test — load a font, rasterize one glyph, print as
ASCII art so the developer can eyeball-check the rasterizer output
without bringing up an image viewer.

Run:
    odin run tools/dump_glyph.odin -file -- Roboto-Regular.ttf A 24
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"

import runa   "../"
import raster "../raster"

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: dump_glyph <font.ttf> <codepoint> <size_px>")
		os.exit(2)
	}

	path := os.args[1]
	cp_arg := os.args[2]
	size_arg := os.args[3]

	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("read: %v", read_err)
		os.exit(1)
	}
	defer delete(data)

	cp: rune = '?'
	for r in cp_arg { cp = r; break }              // first rune of arg

	size, _ := strconv.parse_f32(size_arg)
	if size <= 0 { size = 24 }

	font, ferr := runa.font_load(data)
	if ferr != .None { fmt.eprintfln("font_load: %v", ferr); os.exit(1) }
	defer runa.font_destroy(&font)

	gid := runa.font_lookup_glyph(&font, cp)
	if gid == 0 {
		fmt.eprintfln("glyph for %v not in cmap", cp)
		os.exit(1)
	}

	o := runa.Outline{}
	defer runa.outline_destroy(&o)
	if err := runa.font_glyph_outline(&font, gid, &o); err != .None {
		fmt.eprintfln("outline: %v", err)
		os.exit(1)
	}

	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)

	subpx: u8 = 0
	if len(os.args) > 4 {
		v, _ := strconv.parse_int(os.args[4])
		subpx = u8(v & 3)
	}
	bm, x_off, y_off, rerr := raster.rasterize(&o, font.units_per_em, size, &edges, subpx)
	if rerr != .None {
		fmt.eprintfln("rasterize: %v", rerr)
		os.exit(1)
	}
	defer raster.bitmap_destroy(&bm)

	fmt.printfln("glyph=%v size=%v width=%d height=%d xoff=%d yoff=%d",
	             cp, size, bm.width, bm.height, x_off, y_off)

	// Ramp from light to dark by alpha bucket. Empty squares for zero
	// coverage so the bounding box is visible.
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
