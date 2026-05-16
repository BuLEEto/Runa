/*
First-light demo. Loads a font and renders a string into an 8-bit
grayscale PPM image — no shaping, no line wrapping, no atlas. Proves
the lowest-level "outline -> rasterized glyphs -> composite" path
end-to-end.

Run:
    odin run examples/basic -- tests/fonts/Roboto-Regular.ttf out.pgm

The output is a binary PGM (P5) — view with any image viewer, or pipe
through ImageMagick: `convert out.pgm out.png`.
*/
package main

import "core:fmt"
import "core:os"

import runa   "../.."
import raster "../../raster"

DEFAULT_TEXT :: "office final fish"   // multiple ligatures: ffi, fi, fi
DEFAULT_SIZE :: f32(48.0)
CANVAS_PAD   :: 16                            // pixel padding around the text

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: basic <font.ttf> <output.pgm>")
		os.exit(2)
	}

	font_path := os.args[1]
	out_path  := os.args[2]

	font_bytes, read_err := os.read_entire_file_from_path(font_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("read font: %v", read_err)
		os.exit(1)
	}
	defer delete(font_bytes)

	font, ferr := runa.font_load(font_bytes)
	if ferr != .None {
		fmt.eprintfln("font_load: %v", ferr)
		os.exit(1)
	}
	defer runa.font_destroy(&font)

	if !draw_string_to_pgm(&font, DEFAULT_TEXT, DEFAULT_SIZE, out_path) {
		os.exit(1)
	}
	fmt.printfln("wrote %s", out_path)
}

@(private)
draw_string_to_pgm :: proc(font: ^runa.Font, text: string, size_px: f32, out_path: string) -> bool {
	scale := size_px / f32(font.units_per_em)
	ascent_px  := font.ascent  * scale
	descent_px := font.descent * scale
	line_h     := ascent_px - descent_px        // descent is negative

	// Shape the run — GSUB ligatures fire, GPOS kerning is applied,
	// advances are in pixel space.
	glyphs := make([dynamic]runa.Shaped_Glyph, 0, 64)
	defer delete(glyphs)
	runa.shape_text(font, text, size_px, &glyphs)

	// Compute total run width = sum of advances.
	total_x: f32 = 0
	for sg in glyphs { total_x += sg.x_advance }

	canvas_w := int(total_x) + CANVAS_PAD * 2
	canvas_h := int(line_h) + CANVAS_PAD * 2
	if canvas_w <= 0 || canvas_h <= 0 { return false }

	canvas := make([]u8, canvas_w * canvas_h)
	defer delete(canvas)

	baseline_y := CANVAS_PAD + int(ascent_px)

	outline := runa.Outline{}
	defer runa.outline_destroy(&outline)

	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)

	pen_x: f32 = 0
	for sg in glyphs {
		err := runa.font_glyph_outline(font, sg.glyph_id, &outline)
		if err != .None { pen_x += sg.x_advance; continue }
		if len(outline.contour_ends) == 0 { pen_x += sg.x_advance; continue }

		bm, gx_off, gy_off, rerr := raster.rasterize(&outline, font.units_per_em, size_px, &edges)
		if rerr != .None { pen_x += sg.x_advance; continue }
		defer raster.bitmap_destroy(&bm)

		gx := int(pen_x + sg.x_offset) + gx_off + CANVAS_PAD
		gy := baseline_y + gy_off + int(sg.y_offset)
		composite_max(canvas, canvas_w, canvas_h, bm, gx, gy)

		pen_x += sg.x_advance
	}

	_ = scale
	return write_pgm(out_path, canvas, canvas_w, canvas_h)
}

// composite_max writes `src` into `dst` at (dx, dy), taking the per-pixel
// maximum (white-on-black). Good enough for the demo — proper alpha
// blending arrives once the atlas + colour pipeline lands.
@(private)
composite_max :: proc(dst: []u8, dw, dh: int, src: raster.Bitmap, dx, dy: int) {
	for sy in 0..<src.height {
		ty := dy + sy
		if ty < 0 || ty >= dh { continue }
		for sx in 0..<src.width {
			tx := dx + sx
			if tx < 0 || tx >= dw { continue }
			a := src.pixels[sy * src.width + sx]
			i := ty * dw + tx
			if a > dst[i] { dst[i] = a }
		}
	}
}

// write_pgm dumps an 8-bit single-channel image as a binary PGM (P5).
// PGM is the simplest "open by any tool" raster format — header lines
// followed by raw bytes.
@(private)
write_pgm :: proc(path: string, pixels: []u8, w, h: int) -> bool {
	header := fmt.tprintf("P5\n%d %d\n255\n", w, h)
	buf := make([]u8, len(header) + len(pixels))
	defer delete(buf)
	copy(buf[:len(header)], transmute([]u8)header)
	copy(buf[len(header):], pixels)
	if werr := os.write_entire_file(path, buf); werr != nil {
		fmt.eprintfln("write %s: %v", path, werr)
		return false
	}
	return true
}
