/*
Load a COLRv0 emoji font, render one codepoint at a given size, dump
the result as a color PPM (P6) on a white background.

Run:
    odin run tools/dump_emoji.odin -file -- tests/fonts/Twemoji-Mozilla.ttf '🦊' 64 /tmp/fox.ppm
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"

import runa   "../"
import parse  "../parse"
import raster "../raster"

main :: proc() {
	if len(os.args) < 5 {
		fmt.eprintln("usage: dump_emoji <font.ttf> <emoji-char> <size_px> <out.ppm>")
		os.exit(2)
	}

	font_bytes, rerr := os.read_entire_file_from_path(os.args[1], context.allocator)
	if rerr != nil { fmt.eprintfln("read: %v", rerr); os.exit(1) }
	defer delete(font_bytes)

	font, ferr := runa.font_load(font_bytes)
	if ferr != .None { fmt.eprintfln("font_load: %v", ferr); os.exit(1) }
	defer runa.font_destroy(&font)

	cp: rune = '?'
	for r in os.args[2] { cp = r; break }
	size, _ := strconv.parse_f32(os.args[3])
	if size <= 0 { size = 64 }

	gid := runa.font_lookup_glyph(&font, cp)
	if gid == 0 { fmt.eprintfln("glyph for %v not in cmap", cp); os.exit(1) }

	if !runa.font_has_color_layers(&font, gid) {
		fmt.eprintfln("glyph %v (gid=%d) has no COLR layers", cp, gid)
		os.exit(1)
	}

	layers, lerr := runa.font_color_layers(&font, gid)
	if lerr != .None { fmt.eprintfln("layers: %v", lerr); os.exit(1) }
	defer delete(layers)
	fmt.printfln("found %d COLR layers", len(layers))

	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)

	bm, x_off, y_off, rrerr := raster.rasterize_colr_layers(
		layers, &font._cpal, 0, [4]u8{0, 0, 0, 255},
		&font._glyf, &font._loca, font.units_per_em, size, &edges,
	)
	if rrerr != .None { fmt.eprintfln("rasterize_colr: %v", rrerr); os.exit(1) }
	defer raster.color_bitmap_destroy(&bm)

	fmt.printfln("bitmap %dx%d, offset (%d, %d)", bm.width, bm.height, x_off, y_off)
	if bm.width == 0 || bm.height == 0 {
		fmt.eprintln("empty bitmap")
		os.exit(1)
	}

	// Composite over white for a PPM (no alpha channel in P6).
	rgb := make([]u8, bm.width * bm.height * 3)
	defer delete(rgb)
	for i in 0..<bm.width * bm.height {
		r := f32(bm.pixels[i*4 + 0])
		g := f32(bm.pixels[i*4 + 1])
		b := f32(bm.pixels[i*4 + 2])
		a := f32(bm.pixels[i*4 + 3]) / 255.0
		rgb[i*3 + 0] = u8(r * a + 255.0 * (1.0 - a))
		rgb[i*3 + 1] = u8(g * a + 255.0 * (1.0 - a))
		rgb[i*3 + 2] = u8(b * a + 255.0 * (1.0 - a))
	}

	header := fmt.tprintf("P6\n%d %d\n255\n", bm.width, bm.height)
	buf := make([]u8, len(header) + len(rgb))
	defer delete(buf)
	copy(buf[:len(header)], transmute([]u8)header)
	copy(buf[len(header):], rgb)
	if werr := os.write_entire_file(os.args[4], buf); werr != nil {
		fmt.eprintfln("write: %v", werr); os.exit(1)
	}
	fmt.printfln("wrote %s", os.args[4])

	_ = parse.cpal_lookup
}
