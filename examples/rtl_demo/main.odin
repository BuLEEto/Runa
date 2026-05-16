/*
RTL demo — renders mixed-direction text (Latin, Hebrew, Arabic)
through runa's UAX #9 bidi pipeline + Arabic cursive shaper into
a PPM. Demonstrates v0.5 RTL capabilities visually.

Run:
    odin run examples/rtl_demo -- \
        tests/fonts/Roboto-Regular.ttf \
        tests/fonts/NotoSansHebrew-Regular.ttf \
        tests/fonts/NotoSansArabic-Regular.ttf \
        /tmp/rtl.ppm
*/
package main

import "core:fmt"
import "core:os"

import runa "../.."
import raster "../../raster"

// "hello שלום السلام" — Latin, Hebrew (peace), Arabic (peace).
DEMO_TEXT  :: "hello שלום السلام"
DEMO_SIZE  :: f32(48.0)
CANVAS_PAD :: 24
FG         :: [4]u8{0, 0, 0, 255}
BG         :: [4]u8{248, 248, 248, 255}

main :: proc() {
	if len(os.args) < 5 {
		fmt.eprintln("usage: rtl_demo <latin.ttf> <hebrew.ttf> <arabic.ttf> <out.ppm>")
		os.exit(2)
	}

	fonts: [3]runa.Font
	for i in 0..<3 {
		path := os.args[1 + i]
		bytes, e := os.read_entire_file_from_path(path, context.allocator)
		if e != nil { fmt.eprintfln("read %s: %v", path, e); os.exit(1) }
		defer delete(bytes)
		f, ferr := runa.font_load(bytes)
		if ferr != .None { fmt.eprintfln("font_load %s: %v", path, ferr); os.exit(1) }
		fonts[i] = f
	}
	defer for &f in fonts { runa.font_destroy(&f) }

	out_path := os.args[4]

	stack := runa.Font_Stack{&fonts[0], &fonts[1], &fonts[2]}
	opts  := runa.Paragraph_Opts{fonts = stack, size = DEMO_SIZE, align = .Start, max_width = 2048}

	lines, lerr := runa.layout_paragraph(DEMO_TEXT, opts)
	if lerr != .None { fmt.eprintfln("layout: %v", lerr); os.exit(1) }
	defer { for &l in lines { runa.line_destroy(&l) }; delete(lines) }
	if len(lines) == 0 { fmt.eprintln("no lines"); os.exit(1) }

	line := lines[0]
	cw := int(line.width) + CANVAS_PAD * 2
	ch := int(line.height) + CANVAS_PAD * 2
	canvas := make([]u8, cw * ch * 4)
	defer delete(canvas)
	for i in 0..<cw * ch {
		canvas[i*4 + 0] = BG[0]; canvas[i*4 + 1] = BG[1]
		canvas[i*4 + 2] = BG[2]; canvas[i*4 + 3] = BG[3]
	}

	pen_x: f32 = f32(CANVAS_PAD)
	baseline_y := CANVAS_PAD + int(line.baseline)
	outline := runa.Outline{}
	defer runa.outline_destroy(&outline)
	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)

	for pg in line.glyphs {
		if oerr := runa.font_glyph_outline(pg.font, pg.glyph_id, &outline); oerr != .None {
			pen_x += pg.x_advance; continue
		}
		if len(outline.contour_ends) == 0 { pen_x += pg.x_advance; continue }
		bm, xo, yo, rerr := raster.rasterize(&outline, pg.font.units_per_em, opts.size, &edges)
		if rerr != .None { pen_x += pg.x_advance; continue }
		defer raster.bitmap_destroy(&bm)
		gx := int(pen_x + pg.x_offset) + xo
		gy := baseline_y + yo + int(pg.y_offset)
		for sy in 0..<bm.height {
			ty := gy + sy
			if ty < 0 || ty >= ch { continue }
			for sx in 0..<bm.width {
				tx := gx + sx
				if tx < 0 || tx >= cw { continue }
				cov := bm.pixels[sy * bm.width + sx]
				if cov == 0 { continue }
				alpha := f32(cov) / 255.0
				i := (ty * cw + tx) * 4
				canvas[i + 0] = u8(f32(FG[0]) * alpha + f32(canvas[i + 0]) * (1 - alpha))
				canvas[i + 1] = u8(f32(FG[1]) * alpha + f32(canvas[i + 1]) * (1 - alpha))
				canvas[i + 2] = u8(f32(FG[2]) * alpha + f32(canvas[i + 2]) * (1 - alpha))
				canvas[i + 3] = 255
			}
		}
		pen_x += pg.x_advance
	}

	f, ferr := os.open(out_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if ferr != nil { fmt.eprintfln("open %s: %v", out_path, ferr); os.exit(1) }
	defer os.close(f)
	header := fmt.tprintf("P6\n%d %d\n255\n", cw, ch)
	os.write_string(f, header)
	rgb := make([]u8, cw * ch * 3)
	defer delete(rgb)
	for i in 0..<cw * ch {
		rgb[i*3 + 0] = canvas[i*4 + 0]
		rgb[i*3 + 1] = canvas[i*4 + 1]
		rgb[i*3 + 2] = canvas[i*4 + 2]
	}
	os.write(f, rgb)
	fmt.printfln("wrote %s (%dx%d)", out_path, cw, ch)
}
