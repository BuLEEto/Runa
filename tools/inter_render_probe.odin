/*
Render each of the bug-report strings using runa's own pipeline
(font_load → shape_text → glyf → rasterize → composite) into a PPM
so we can eyeball what the engine actually emits. If the strings
render correctly here but wrong in Skald, the bug is downstream.
*/
package main

import "core:fmt"
import "core:os"

import runa   "../"
import raster "../raster"

CASES :: [?]string{
	"(Tibs)",
	"goblin. Excellent whiskers",
	"6564 prompt + 31 completion",
	"= 6595 tokens",
}

main :: proc() {
	bytes, _ := os.read_entire_file_from_path("tests/fonts/InterVariable.ttf", context.allocator)
	defer delete(bytes)

	font, ferr := runa.font_load(bytes)
	if ferr != .None { fmt.eprintfln("load: %v", ferr); os.exit(1) }
	defer runa.font_destroy(&font)

	for s, i in CASES {
		out := fmt.tprintf("/tmp/inter_bug_%d.pgm", i)
		render(&font, s, 24.0, out)
		fmt.printfln("[%d] %q → %s", i, s, out)
	}
}

render :: proc(font: ^runa.Font, text: string, size: f32, out_path: string) {
	scale := size / f32(font.units_per_em)
	ascent_px  := font.ascent  * scale
	descent_px := font.descent * scale
	line_h := ascent_px - descent_px

	glyphs := make([dynamic]runa.Shaped_Glyph, 0, 64)
	defer delete(glyphs)
	runa.shape_text(font, text, size, &glyphs)

	total_x: f32 = 0
	for g in glyphs { total_x += g.x_advance }
	pad :: 8
	cw := int(total_x) + pad * 2
	ch := int(line_h) + pad * 2
	canvas := make([]u8, cw * ch)
	defer delete(canvas)

	baseline := pad + int(ascent_px)
	outline := runa.Outline{}
	defer runa.outline_destroy(&outline)
	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)

	pen: f32 = 0
	for g in glyphs {
		if runa.font_glyph_outline(font, g.glyph_id, &outline) != .None { pen += g.x_advance; continue }
		if len(outline.contour_ends) == 0 { pen += g.x_advance; continue }
		bm, xo, yo, _ := raster.rasterize(&outline, font.units_per_em, size, &edges)
		defer raster.bitmap_destroy(&bm)
		gx := int(pen) + xo + pad
		gy := baseline + yo
		for sy in 0..<bm.height {
			ty := gy + sy
			if ty < 0 || ty >= ch { continue }
			for sx in 0..<bm.width {
				tx := gx + sx
				if tx < 0 || tx >= cw { continue }
				v := bm.pixels[sy * bm.width + sx]
				if v > canvas[ty * cw + tx] { canvas[ty * cw + tx] = v }
			}
		}
		pen += g.x_advance
	}

	header := fmt.tprintf("P5\n%d %d\n255\n", cw, ch)
	buf := make([]u8, len(header) + len(canvas))
	defer delete(buf)
	copy(buf[:len(header)], transmute([]u8)header)
	copy(buf[len(header):], canvas)
	_ = os.write_entire_file(out_path, buf)
}
