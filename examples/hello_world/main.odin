/*
"Hello, world! 🦊" — the runa-canonical end-to-end demo.

Loads two fonts (a Latin text font + a COLRv0 emoji font), runs
`layout_paragraph`, and renders the resulting glyphs into an RGBA
canvas. Mono glyphs are tinted to the foreground colour; COLR glyphs
are composited from their layer palette.

The output is a P6 (color) PPM — view directly or pipe through
ImageMagick: `convert out.ppm out.png`.

Run:
    odin run examples/hello_world -- \
        tests/fonts/Roboto-Regular.ttf \
        tests/fonts/Twemoji-Mozilla.ttf \
        /tmp/hello.ppm
*/
package main

import "core:fmt"
import "core:os"

import runa   "../.."
import raster "../../raster"

DEFAULT_TEXT :: "Hello, world! 🦊"
DEFAULT_SIZE :: f32(64.0)
CANVAS_PAD   :: 24
FG_COLOR     :: [4]u8{0, 0, 0, 255}             // black text
BG_COLOR     :: [4]u8{255, 255, 255, 255}       // white background

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: hello_world <text.ttf> <emoji.ttf> <out.ppm>")
		os.exit(2)
	}
	text_path  := os.args[1]
	emoji_path := os.args[2]
	out_path   := os.args[3]

	text_bytes, e1 := os.read_entire_file_from_path(text_path, context.allocator)
	if e1 != nil { fmt.eprintfln("read %s: %v", text_path, e1); os.exit(1) }
	defer delete(text_bytes)
	emoji_bytes, e2 := os.read_entire_file_from_path(emoji_path, context.allocator)
	if e2 != nil { fmt.eprintfln("read %s: %v", emoji_path, e2); os.exit(1) }
	defer delete(emoji_bytes)

	text_font, ferr1 := runa.font_load(text_bytes)
	if ferr1 != .None { fmt.eprintfln("font_load text: %v", ferr1); os.exit(1) }
	defer runa.font_destroy(&text_font)
	emoji_font, ferr2 := runa.font_load(emoji_bytes)
	if ferr2 != .None { fmt.eprintfln("font_load emoji: %v", ferr2); os.exit(1) }
	defer runa.font_destroy(&emoji_font)

	font_stack := runa.Font_Stack{&text_font, &emoji_font}
	opts := runa.Paragraph_Opts{
		fonts = font_stack,
		size  = DEFAULT_SIZE,
		align = .Start,
	}

	lines, lerr := runa.layout_paragraph(DEFAULT_TEXT, opts)
	if lerr != .None { fmt.eprintfln("layout: %v", lerr); os.exit(1) }
	defer {
		for &l in lines { runa.line_destroy(&l) }
		delete(lines)
	}

	if len(lines) == 0 { fmt.eprintln("no lines"); os.exit(1) }
	line := lines[0]
	canvas_w := int(line.width) + CANVAS_PAD * 2
	canvas_h := int(line.height) + CANVAS_PAD * 2
	canvas := make([]u8, canvas_w * canvas_h * 4)
	defer delete(canvas)
	for i in 0..<canvas_w * canvas_h {
		canvas[i*4 + 0] = BG_COLOR[0]
		canvas[i*4 + 1] = BG_COLOR[1]
		canvas[i*4 + 2] = BG_COLOR[2]
		canvas[i*4 + 3] = BG_COLOR[3]
	}

	pen_x: f32 = f32(CANVAS_PAD)
	baseline_y := CANVAS_PAD + int(line.baseline)

	outline := runa.Outline{}
	defer runa.outline_destroy(&outline)
	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)

	for pg in line.glyphs {
		// Branch by colour-base glyph or mono.
		if runa.font_has_color_layers(pg.font, pg.glyph_id) {
			layers, lerr2 := runa.font_color_layers(pg.font, pg.glyph_id)
			if lerr2 != .None { pen_x += pg.x_advance; continue }
			defer delete(layers)
			bm, xo, yo, rerr := raster.rasterize_colr_layers(
				layers, &pg.font._cpal, 0, FG_COLOR,
				&pg.font._glyf, &pg.font._loca, pg.font.units_per_em, opts.size, &edges,
			)
			if rerr != .None { pen_x += pg.x_advance; continue }
			defer raster.color_bitmap_destroy(&bm)

			gx := int(pen_x + pg.x_offset) + xo
			gy := baseline_y + yo + int(pg.y_offset)
			composite_rgba(canvas, canvas_w, canvas_h, bm.pixels, bm.width, bm.height, gx, gy)
		} else {
			oerr := runa.font_glyph_outline(pg.font, pg.glyph_id, &outline)
			if oerr != .None { pen_x += pg.x_advance; continue }
			if len(outline.contour_ends) == 0 { pen_x += pg.x_advance; continue }
			bm, xo, yo, rerr := raster.rasterize(&outline, pg.font.units_per_em, opts.size, &edges)
			if rerr != .None { pen_x += pg.x_advance; continue }
			defer raster.bitmap_destroy(&bm)

			gx := int(pen_x + pg.x_offset) + xo
			gy := baseline_y + yo + int(pg.y_offset)
			composite_mono(canvas, canvas_w, canvas_h, bm.pixels, bm.width, bm.height, gx, gy, FG_COLOR)
		}
		pen_x += pg.x_advance
	}

	if !write_ppm_p6(out_path, canvas, canvas_w, canvas_h) {
		os.exit(1)
	}
	fmt.printfln("wrote %s (%dx%d)", out_path, canvas_w, canvas_h)
}

// composite_mono draws an alpha bitmap onto the RGBA canvas tinted
// `color`. Source alpha is the bitmap coverage; destination alpha is
// updated using straight-alpha OVER.
@(private)
composite_mono :: proc(canvas: []u8, cw, ch: int, src: []u8, sw, sh: int, dx, dy: int, color: [4]u8) {
	for sy in 0..<sh {
		ty := dy + sy
		if ty < 0 || ty >= ch { continue }
		for sx in 0..<sw {
			tx := dx + sx
			if tx < 0 || tx >= cw { continue }
			cov := src[sy * sw + sx]
			if cov == 0 { continue }
			alpha := f32(cov) * f32(color[3]) / (255.0 * 255.0)
			i := (ty * cw + tx) * 4
			dst_a := f32(canvas[i + 3]) / 255.0
			out_a := alpha + dst_a * (1.0 - alpha)
			if out_a <= 0 { continue }
			or := (f32(color[0])/255.0 * alpha + f32(canvas[i + 0])/255.0 * dst_a * (1 - alpha)) / out_a
			og := (f32(color[1])/255.0 * alpha + f32(canvas[i + 1])/255.0 * dst_a * (1 - alpha)) / out_a
			ob := (f32(color[2])/255.0 * alpha + f32(canvas[i + 2])/255.0 * dst_a * (1 - alpha)) / out_a
			canvas[i + 0] = u8(or * 255.0 + 0.5)
			canvas[i + 1] = u8(og * 255.0 + 0.5)
			canvas[i + 2] = u8(ob * 255.0 + 0.5)
			canvas[i + 3] = u8(out_a * 255.0 + 0.5)
		}
	}
}

// composite_rgba copies an RGBA source over the canvas with
// straight-alpha OVER.
@(private)
composite_rgba :: proc(canvas: []u8, cw, ch: int, src: []u8, sw, sh: int, dx, dy: int) {
	for sy in 0..<sh {
		ty := dy + sy
		if ty < 0 || ty >= ch { continue }
		for sx in 0..<sw {
			tx := dx + sx
			if tx < 0 || tx >= cw { continue }
			si := (sy * sw + sx) * 4
			alpha := f32(src[si + 3]) / 255.0
			if alpha <= 0 { continue }
			i := (ty * cw + tx) * 4
			dst_a := f32(canvas[i + 3]) / 255.0
			out_a := alpha + dst_a * (1.0 - alpha)
			if out_a <= 0 { continue }
			or := (f32(src[si + 0])/255.0 * alpha + f32(canvas[i + 0])/255.0 * dst_a * (1 - alpha)) / out_a
			og := (f32(src[si + 1])/255.0 * alpha + f32(canvas[i + 1])/255.0 * dst_a * (1 - alpha)) / out_a
			ob := (f32(src[si + 2])/255.0 * alpha + f32(canvas[i + 2])/255.0 * dst_a * (1 - alpha)) / out_a
			canvas[i + 0] = u8(or * 255.0 + 0.5)
			canvas[i + 1] = u8(og * 255.0 + 0.5)
			canvas[i + 2] = u8(ob * 255.0 + 0.5)
			canvas[i + 3] = u8(out_a * 255.0 + 0.5)
		}
	}
}

@(private)
write_ppm_p6 :: proc(path: string, rgba: []u8, w, h: int) -> bool {
	// P6 wants RGB only; drop the alpha channel by compositing against
	// white. The canvas is already on a white background, so simply
	// strip alpha — channels are in straight-alpha form.
	rgb := make([]u8, w * h * 3)
	defer delete(rgb)
	for i in 0..<w * h {
		rgb[i*3 + 0] = rgba[i*4 + 0]
		rgb[i*3 + 1] = rgba[i*4 + 1]
		rgb[i*3 + 2] = rgba[i*4 + 2]
	}
	header := fmt.tprintf("P6\n%d %d\n255\n", w, h)
	buf := make([]u8, len(header) + len(rgb))
	defer delete(buf)
	copy(buf[:len(header)], transmute([]u8)header)
	copy(buf[len(header):], rgb)
	if werr := os.write_entire_file(path, buf); werr != nil {
		fmt.eprintfln("write: %v", werr)
		return false
	}
	return true
}
