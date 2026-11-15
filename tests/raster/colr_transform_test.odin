/*
COLRv1 transforms in the brush rasterizer, on a synthetic glyph: a
100-unit square (glyph 1) in a hand-built glyf/loca pair, at 100 units
per em and 10 px, so one pixel is 10 units.

  - a layer's glyph transform moves its outline (a 200-unit translation
    puts the square 20 px to the right),
  - a layer's brush transform moves its fill (a gradient rotated 180°
    about the square's centre runs the other way).
*/
package raster_test

import "core:testing"

import parse  "../../parse"
import raster "../../raster"

// glyf and loca for two glyphs: 0 empty, 1 the square (0, 0)–(100, 100).
@(private)
square_font :: proc(t: ^testing.T) -> (glyf: parse.Glyf, loca: parse.Loca) {
	@(static) glyf_bytes := [?]u8{
		0, 1,                   // numberOfContours
		0, 0, 0, 0, 0, 100, 0, 100, // xMin, yMin, xMax, yMax
		0, 3,                   // endPtsOfContours[0]
		0, 0,                   // instructionLength
		1, 1, 1, 1,             // flags: on curve, x and y as int16 deltas
		// Clockwise, as TrueType outer contours are: (0, 0), (0, 100),
		// (100, 100), (100, 0).
		0, 0, 0, 0, 0, 100, 0, 0,       // x deltas: 0, 0, 100, 0
		0, 0, 0, 100, 0, 0, 0xFF, 0x9C, // y deltas: 0, 100, 0, -100
	}
	// Short loca (offsets / 2): glyph 0 is 0..0, glyph 1 is 0..34.
	@(static) loca_bytes := [?]u8{0, 0, 0, 0, 0, 17}
	err: parse.Error
	loca, err = parse.parse_loca(loca_bytes[:], .Short, 2)
	testing.expect_value(t, err, parse.Error.None)
	return parse.new_glyf(glyf_bytes[:]), loca
}

// The leftmost and rightmost columns with any coverage in `bm`.
@(private)
covered_columns :: proc(bm: raster.Color_Bitmap) -> (first, last: int) {
	first, last = bm.width, -1
	for y in 0..<bm.height {
		for x in 0..<bm.width {
			if bm.pixels[(y * bm.width + x) * 4 + 3] == 0 { continue }
			first, last = min(first, x), max(last, x)
		}
	}
	return
}

@(test)
test_colr_glyph_transform_moves_outline :: proc(t: ^testing.T) {
	glyf, loca := square_font(t)
	defer delete(loca.offsets)
	palette: parse.Cpal
	edges := make([dynamic]raster.Edge, 0, 16)
	defer delete(edges)

	layer := parse.Colr_Brush_Layer{
		glyph_id = 1,
		brush = parse.Colr_Brush{kind = .Solid, palette_index = parse.COLR_FOREGROUND_PALETTE_INDEX, alpha = 1},
		composite_mode = parse.COMPOSITE_SRC_OVER, // the parser's default; the zero value is Clear
		transformed = true,
		glyph_transform = parse.Affine{xx = 1, yy = 1, dx = 200},
		brush_transform = parse.Affine{xx = 1, yy = 1, dx = 200},
	}
	layers := [1]parse.Colr_Brush_Layer{layer}
	bm, x_offset, _, err := raster.rasterize_colr_brush_layers(layers[:], &palette, 0, {0, 0, 0, 255}, &glyf, &loca, 100, 10, &edges)
	defer raster.color_bitmap_destroy(&bm)
	testing.expect_value(t, err, raster.Rast_Error.None)
	first, last := covered_columns(bm)
	// Untransformed the square covers pixels 0..9; moved 200 units, 20..29.
	testing.expect(t, abs(x_offset + first - 20) <= 1, "the outline moved 20 px right")
	testing.expect(t, abs(last - first + 1 - 10) <= 1, "and kept its 10 px width")
}

@(test)
test_colr_brush_transform_rotates_gradient :: proc(t: ^testing.T) {
	glyf, loca := square_font(t)
	defer delete(loca.offsets)
	palette: parse.Cpal
	edges := make([dynamic]raster.Edge, 0, 16)
	defer delete(edges)

	// Transparent at x = 0, opaque at x = 100 (the foreground colour).
	stops := [2]parse.Color_Stop{
		{offset = 0, palette_index = parse.COLR_FOREGROUND_PALETTE_INDEX, alpha = 0},
		{offset = 1, palette_index = parse.COLR_FOREGROUND_PALETTE_INDEX, alpha = 1},
	}
	brush := parse.Colr_Brush{kind = .Linear, palette_index = parse.COLR_FOREGROUND_PALETTE_INDEX, alpha = 1,
	                          p0 = {0, 0}, p1 = {100, 0}, stops = stops[:]}
	// Rotated 180° about (50, 50): the gradient now runs right to left.
	turned := parse.Affine{xx = -1, yy = -1, dx = 100, dy = 100}

	alpha_at :: proc(t: ^testing.T, layer: parse.Colr_Brush_Layer, glyf: ^parse.Glyf, loca: ^parse.Loca,
	                 palette: ^parse.Cpal, edges: ^[dynamic]raster.Edge) -> (left, right: u8) {
		layers := [1]parse.Colr_Brush_Layer{layer}
		bm, _, _, err := raster.rasterize_colr_brush_layers(layers[:], palette, 0, {0, 0, 0, 255}, glyf, loca, 100, 10, edges)
		defer raster.color_bitmap_destroy(&bm)
		testing.expect_value(t, err, raster.Rast_Error.None)
		if bm.width < 3 || bm.height < 3 { return }
		row := bm.height / 2
		return bm.pixels[(row * bm.width + 1) * 4 + 3], bm.pixels[(row * bm.width + bm.width - 2) * 4 + 3]
	}

	// SrcOver: the parser's default (the zero value is Clear).
	plain := parse.Colr_Brush_Layer{glyph_id = 1, brush = brush, composite_mode = parse.COMPOSITE_SRC_OVER}
	left, right := alpha_at(t, plain, &glyf, &loca, &palette, &edges)
	testing.expect(t, left < 64 && right > 192, "untransformed: transparent left, opaque right")

	rotated := parse.Colr_Brush_Layer{glyph_id = 1, brush = brush, composite_mode = parse.COMPOSITE_SRC_OVER, transformed = true,
	                                  glyph_transform = parse.AFFINE_IDENTITY, brush_transform = turned}
	left, right = alpha_at(t, rotated, &glyf, &loca, &palette, &edges)
	testing.expect(t, left > 192 && right < 64, "rotated 180°: opaque left, transparent right")
}
