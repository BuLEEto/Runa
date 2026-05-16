/*
End-to-end visual check of Arabic cursive shaping. Renders بنت
("girl"), كتاب ("book"), and a mixed-direction string with Latin +
Arabic. Each Arabic letter should appear in its joined positional
form, not the isolated cmap form.

Run:
    odin run tools/arabic_demo.odin -file -o:speed
*/
package main

import "core:fmt"
import "core:os"

import runa   "../"
import raster "../raster"

main :: proc() {
	latn_bytes,   _ := os.read_entire_file_from_path("tests/fonts/Roboto-Regular.ttf",      context.allocator)
	arab_bytes,   _ := os.read_entire_file_from_path("tests/fonts/NotoSansArabic-Regular.ttf", context.allocator)
	defer delete(latn_bytes)
	defer delete(arab_bytes)

	latn, _ := runa.font_load(latn_bytes)
	arab, _ := runa.font_load(arab_bytes)
	defer runa.font_destroy(&latn)
	defer runa.font_destroy(&arab)

	stack := runa.Font_Stack{&latn, &arab}
	opts  := runa.Paragraph_Opts{fonts = stack, size = 36}

	outline := runa.Outline{}
	defer runa.outline_destroy(&outline)
	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)

	cases := [?]string{"بنت", "كتاب", "Hello كتاب World"}

	for text in cases {
		fmt.printfln("=== %q ===", text)
		lines, _ := runa.layout_paragraph(text, opts)
		defer { for &l in lines { runa.line_destroy(&l) }; delete(lines) }

		l := lines[0]
		w := int(l.width) + 16
		h := int(l.height) + 16
		canvas := make([]u8, w * h); defer delete(canvas)
		baseline := 8 + int(l.baseline)

		pen: f32 = 8
		for g in l.glyphs {
			if runa.font_glyph_outline(g.font, g.glyph_id, &outline) != .None { pen += g.x_advance; continue }
			if len(outline.contour_ends) == 0 { pen += g.x_advance; continue }
			bm, xo, yo, _ := raster.rasterize(&outline, g.font.units_per_em, opts.size, &edges)
			defer raster.bitmap_destroy(&bm)
			gx := int(pen + g.x_offset) + xo
			gy := baseline + yo + int(g.y_offset)
			for sy in 0..<bm.height {
				ty := gy + sy
				if ty < 0 || ty >= h { continue }
				for sx in 0..<bm.width {
					tx := gx + sx
					if tx < 0 || tx >= w { continue }
					v := bm.pixels[sy * bm.width + sx]
					if v > canvas[ty * w + tx] { canvas[ty * w + tx] = v }
				}
			}
			pen += g.x_advance
		}

		ramp := []u8{' ', '.', ':', '-', '=', '+', '*', '#', '@'}
		for y in 0..<h {
			for x in 0..<w {
				a := canvas[y * w + x]
				if a < 30 { fmt.printf(" "); continue }
				idx := int(a) * (len(ramp) - 1) / 255
				fmt.printf("%c", rune(ramp[idx]))
			}
			fmt.println()
		}
		fmt.println()
	}
}
