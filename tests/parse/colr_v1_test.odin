/*
COLRv1 paint-tree tests on synthetic tables: no font file needed.

Each test builds a minimal COLR version 1 table (header, a BaseGlyphList
with one record, then a chain of paints, each followed directly by its
child) and checks what the parser makes of it:

  - a glyph present only in the BaseGlyphList is a colour base glyph,
  - transform paints above and below a PaintGlyph reach the layer as
    its glyph and brush transforms,
  - skew and uniform-scale paints (formats 20–23 and 28–31) are walked,
    not dropped,
  - the Affine helpers compose and invert.
*/
package parse_test

import "core:math"
import "core:testing"

import parse "../../parse"

@(private)
put_u16 :: proc(b: ^[dynamic]u8, v: u16) { append(b, u8(v >> 8), u8(v)) }

@(private)
put_u24 :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v >> 16), u8(v >> 8), u8(v)) }

@(private)
put_u32 :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)) }

@(private)
put_i16 :: proc(b: ^[dynamic]u8, v: i16) { put_u16(b, u16(v)) }

// F2DOT14: 1.0 is 16384.
@(private)
put_f2dot14 :: proc(b: ^[dynamic]u8, v: f32) { put_i16(b, i16(math.round(v * 16384))) }

// Paints with one child. The child follows directly, so its Offset24
// (relative to the paint itself) is the paint's size.
@(private)
paint_glyph :: proc(b: ^[dynamic]u8, gid: u16) { append(b, parse.PAINT_GLYPH); put_u24(b, 6); put_u16(b, gid) }

@(private)
paint_translate :: proc(b: ^[dynamic]u8, dx, dy: i16) {
	append(b, parse.PAINT_TRANSLATE); put_u24(b, 8); put_i16(b, dx); put_i16(b, dy)
}

// `half_turns`: 1.0 is 180 degrees, counter-clockwise.
@(private)
paint_rotate :: proc(b: ^[dynamic]u8, half_turns: f32) {
	append(b, parse.PAINT_ROTATE); put_u24(b, 6); put_f2dot14(b, half_turns)
}

@(private)
paint_skew :: proc(b: ^[dynamic]u8, x_half_turns, y_half_turns: f32) {
	append(b, parse.PAINT_SKEW); put_u24(b, 8); put_f2dot14(b, x_half_turns); put_f2dot14(b, y_half_turns)
}

@(private)
paint_scale_uniform :: proc(b: ^[dynamic]u8, scale: f32) {
	append(b, parse.PAINT_SCALE_UNIFORM); put_u24(b, 6); put_f2dot14(b, scale)
}

// The leaf: palette entry 0, opaque.
@(private)
paint_solid :: proc(b: ^[dynamic]u8) { append(b, parse.PAINT_SOLID); put_u16(b, 0); put_f2dot14(b, 1) }

// A COLR version 1 table whose only base glyph, `gid`, has `paints` as
// its paint tree (no version 0 records, no LayerList, no ClipList).
@(private)
colr_v1_table :: proc(gid: u16, paints: []u8, allocator := context.allocator) -> []u8 {
	HEADER :: 34 // version 1 header: 2+2+4+4+2 then five Offset32s
	b := make([dynamic]u8, 0, HEADER + 10 + len(paints), allocator)
	put_u16(&b, 1)      // version
	put_u16(&b, 0)      // numBaseGlyphRecords
	put_u32(&b, 0)      // baseGlyphRecordsOffset
	put_u32(&b, 0)      // layerRecordsOffset
	put_u16(&b, 0)      // numLayerRecords
	put_u32(&b, HEADER) // baseGlyphListOffset
	put_u32(&b, 0)      // layerListOffset
	put_u32(&b, 0)      // clipListOffset
	put_u32(&b, 0)      // varIndexMapOffset
	put_u32(&b, 0)      // itemVariationStoreOffset
	// BaseGlyphList: count, then one BaseGlyphPaintRecord whose Offset32
	// is relative to the list's start (4 + 6: just past the record).
	put_u32(&b, 1)
	put_u16(&b, gid)
	put_u32(&b, 10)
	append(&b, ..paints)
	return b[:]
}

@(private)
near :: proc(a, b: f32) -> bool { return abs(a - b) < 1e-4 }

@(private)
affine_near :: proc(a, b: parse.Affine) -> bool {
	return near(a.xx, b.xx) && near(a.yx, b.yx) && near(a.xy, b.xy) &&
	       near(a.yy, b.yy) && near(a.dx, b.dx) && near(a.dy, b.dy)
}

// The brush layers of base glyph `gid`; the caller destroys them.
@(private)
v1_layers :: proc(t: ^testing.T, table: []u8, gid: u16) -> (layers: [dynamic]parse.Colr_Brush_Layer) {
	c, err := parse.new_colr(table)
	testing.expect_value(t, err, parse.Error.None)
	layers = make([dynamic]parse.Colr_Brush_Layer)
	testing.expect(t, parse.colr_v1_brush_layers(&c, parse.Glyph_ID(gid), &layers), "base glyph has a paint tree")
	return
}

@(test)
test_colr_v1_only_glyph_is_base :: proc(t: ^testing.T) {
	paints := make([dynamic]u8, context.temp_allocator)
	paint_glyph(&paints, 3)
	paint_solid(&paints)
	table := colr_v1_table(5, paints[:], context.temp_allocator)

	c, err := parse.new_colr(table)
	testing.expect_value(t, err, parse.Error.None)
	// No version 0 record: the BaseGlyphList alone makes it a colour glyph.
	testing.expect(t, parse.colr_is_base(&c, 5), "a glyph only in the BaseGlyphList is a colour base")
	testing.expect(t, !parse.colr_is_base(&c, 4), "a glyph in neither list is not")

	layers := v1_layers(t, table, 5)
	defer parse.colr_brush_layers_destroy(&layers)
	testing.expect_value(t, len(layers), 1)
	if len(layers) != 1 { return }
	testing.expect_value(t, layers[0].glyph_id, parse.Glyph_ID(3))
	testing.expect(t, !layers[0].transformed, "no transform paints: identity")
}

@(test)
test_colr_v1_transforms_reach_layer :: proc(t: ^testing.T) {
	// PaintTranslate(100, -50) > PaintGlyph(3) > PaintRotate(90°) > PaintSolid:
	// the translation places the outline; the brush is placed by both.
	paints := make([dynamic]u8, context.temp_allocator)
	paint_translate(&paints, 100, -50)
	paint_glyph(&paints, 3)
	paint_rotate(&paints, 0.5)
	paint_solid(&paints)
	table := colr_v1_table(5, paints[:], context.temp_allocator)

	layers := v1_layers(t, table, 5)
	defer parse.colr_brush_layers_destroy(&layers)
	testing.expect_value(t, len(layers), 1)
	if len(layers) != 1 { return }
	layer := layers[0]
	testing.expect(t, layer.transformed, "transform paints mark the layer")
	translate := parse.Affine{xx = 1, yy = 1, dx = 100, dy = -50}
	testing.expect(t, affine_near(layer.glyph_transform, translate), "glyph transform is the translation above PaintGlyph")
	// Rotating (1, 0) by 90° counter-clockwise gives (0, 1), then translated.
	rotated := parse.Affine{xx = 0, yx = 1, xy = -1, yy = 0, dx = 100, dy = -50}
	testing.expect(t, affine_near(layer.brush_transform, rotated), "brush transform is translation then rotation")
	x, y := parse.affine_apply(layer.brush_transform, 1, 0)
	testing.expect(t, near(x, 100) && near(y, -49), "brush transform maps (1, 0) to (100, -49)")
}

@(test)
test_colr_v1_skew_and_uniform_scale_walked :: proc(t: ^testing.T) {
	// Formats 28 (skew) and 20 (uniform scale) were once numbered as other
	// formats and dropped with everything under them.
	skewed := make([dynamic]u8, context.temp_allocator)
	paint_skew(&skewed, 0.25, 0) // 45°
	paint_glyph(&skewed, 3)
	paint_solid(&skewed)
	layers := v1_layers(t, colr_v1_table(5, skewed[:], context.temp_allocator), 5)
	testing.expect_value(t, len(layers), 1)
	if len(layers) == 1 {
		// x' = x - tan(45°)·y: a positive x angle leans verticals towards -x.
		testing.expect(t, affine_near(layers[0].glyph_transform, parse.Affine{xx = 1, xy = -1, yy = 1}), "skew x 45°")
	}
	parse.colr_brush_layers_destroy(&layers)

	scaled := make([dynamic]u8, context.temp_allocator)
	paint_scale_uniform(&scaled, 0.5)
	paint_glyph(&scaled, 3)
	paint_solid(&scaled)
	layers = v1_layers(t, colr_v1_table(5, scaled[:], context.temp_allocator), 5)
	defer parse.colr_brush_layers_destroy(&layers)
	testing.expect_value(t, len(layers), 1)
	if len(layers) == 1 {
		testing.expect(t, affine_near(layers[0].glyph_transform, parse.Affine{xx = 0.5, yy = 0.5}), "uniform scale 0.5")
	}
}

@(test)
test_affine_compose_and_invert :: proc(t: ^testing.T) {
	translate := parse.Affine{xx = 1, yy = 1, dx = 10, dy = 20}
	scale := parse.Affine{xx = 2, yy = 3}
	// `inner` first: scale (1, 1) to (2, 3), then translate to (12, 23).
	m := parse.affine_multiply(translate, scale)
	x, y := parse.affine_apply(m, 1, 1)
	testing.expect(t, near(x, 12) && near(y, 23), "multiply applies inner first")

	inverse, ok := parse.affine_invert(m)
	testing.expect(t, ok, "a non-singular transform inverts")
	testing.expect(t, affine_near(parse.affine_multiply(inverse, m), parse.AFFINE_IDENTITY), "inverse composes to identity")
	_, singular_ok := parse.affine_invert(parse.Affine{xx = 0, yy = 1})
	testing.expect(t, !singular_ok, "a zero scale has no inverse")
}
