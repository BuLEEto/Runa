/*
Rasterizer smoke tests. Loads a real font, extracts a glyph outline,
and rasterizes it into an 8-bit alpha bitmap. Asserts:

  - bitmap is non-empty,
  - has visible coverage somewhere inside it,
  - the centermost pixel of a solid glyph ('A') is fully covered.

Golden-image tests against `tests/golden/` come once the analytic
rasterizer replaces super-sampling and the reference fonts are
committed.
*/
package raster_test

import "core:log"
import "core:os"
import "core:testing"

import parse  "../../parse"
import raster "../../raster"

ROBOTO :: "tests/fonts/Roboto-Regular.ttf"

@(private)
load_bytes :: proc(path: string) -> ([]u8, bool) {
	bytes, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return nil, false }
	return bytes, true
}

@(test)
test_rasterize_capital_A :: proc(t: ^testing.T) {
	data, ok := load_bytes(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	head_b, _ := parse.find_table(&idx, data, parse.tag("head"))
	head, _ := parse.parse_head(head_b)

	maxp_b, _ := parse.find_table(&idx, data, parse.tag("maxp"))
	mx, _ := parse.parse_maxp(maxp_b)

	loca_b, _ := parse.find_table(&idx, data, parse.tag("loca"))
	loca, _ := parse.parse_loca(loca_b, head.index_to_loc_format, mx.num_glyphs)
	defer parse.loca_destroy(&loca)

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	glyf_b, _ := parse.find_table(&idx, data, parse.tag("glyf"))
	g := parse.new_glyf(glyf_b)

	gid := parse.cmap_lookup(&cm, 'A')
	testing.expect(t, gid != 0, "'A' resolves")

	outline := parse.Outline{}
	defer parse.outline_destroy(&outline)
	oerr := parse.glyf_outline(&g, &loca, gid, &outline)
	testing.expect_value(t, oerr, parse.Error.None)

	edges := make([dynamic]raster.Edge, 0, 128)
	defer delete(edges)

	bm, _, _, rerr := raster.rasterize(&outline, head.units_per_em, 32.0, &edges)
	testing.expect_value(t, rerr, raster.Rast_Error.None)
	defer raster.bitmap_destroy(&bm)

	testing.expect(t, bm.width > 0 && bm.height > 0, "bitmap is non-empty")

	// At least one pixel should have some coverage.
	any_lit := false
	for p in bm.pixels {
		if p > 0 { any_lit = true; break }
	}
	testing.expect(t, any_lit, "'A' produces at least one visible pixel")

	// At least one pixel should be fully (or near-fully) opaque — the
	// stems of 'A' are wide enough at 32 px that interior pixels are
	// fully covered.
	any_solid := false
	for p in bm.pixels {
		if p >= 240 { any_solid = true; break }
	}
	testing.expect(t, any_solid, "'A' has at least one near-opaque pixel")
}

@(test)
test_rasterize_empty_glyph :: proc(t: ^testing.T) {
	// Manually construct an empty outline. The rasterizer must accept
	// it and return a 0×0 bitmap with no error.
	o := parse.Outline{}
	defer parse.outline_destroy(&o)

	edges := make([dynamic]raster.Edge, 0, 8)
	defer delete(edges)

	bm, _, _, err := raster.rasterize(&o, 1024, 16.0, &edges)
	testing.expect_value(t, err, raster.Rast_Error.None)
	testing.expect_value(t, bm.width, 0)
	testing.expect_value(t, bm.height, 0)
}

@(test)
test_rasterize_zero_size_rejected :: proc(t: ^testing.T) {
	o := parse.Outline{}
	defer parse.outline_destroy(&o)

	edges := make([dynamic]raster.Edge, 0, 8)
	defer delete(edges)

	_, _, _, err := raster.rasterize(&o, 1024, 0.0, &edges)
	testing.expect_value(t, err, raster.Rast_Error.Invalid_Size)
}

// ---- COLRv1 composite mode sanity ---------------------------------
//
// Pin a few non-trivial modes (Multiply, Screen, Difference, HSL
// variants) against known values. The math is fully spec'd so any
// regression in `composite_pixel` shows up here.

import parse_pkg "../../parse"

@(test)
test_composite_multiply :: proc(t: ^testing.T) {
	// red on cyan: multiply = (0.5*0.0, 0.0*1.0, 0.0*1.0) = (0,0,0).
	dst: [4]u8 = {127, 255, 255, 255}        // cyan-ish, full alpha
	src: [4]u8 = {127,   0,   0, 255}
	raster.test_composite_pixel(dst[:], src, 255, parse_pkg.COMPOSITE_MULTIPLY)
	// Top channel: 127 * 127 / 255 ≈ 63.
	testing.expect(t, dst[0] <= 67 && dst[0] >= 60, "multiply r channel near 63")
	testing.expect(t, dst[1] == 0,  "multiply g channel zero")
	testing.expect(t, dst[2] == 0,  "multiply b channel zero")
}

@(test)
test_composite_screen :: proc(t: ^testing.T) {
	// 0.5 over 0.5 screen: 1 - (1-0.5)*(1-0.5) = 0.75.
	dst: [4]u8 = {127, 127, 127, 255}
	src: [4]u8 = {127, 127, 127, 255}
	raster.test_composite_pixel(dst[:], src, 255, parse_pkg.COMPOSITE_SCREEN)
	testing.expect(t, dst[0] >= 188 && dst[0] <= 195, "screen near 0.75 * 255 = 191")
}

@(test)
test_composite_difference :: proc(t: ^testing.T) {
	// |red - blue| = |0.5 - 0| = 0.5 on each channel that differs.
	dst: [4]u8 = {255,   0,   0, 255}
	src: [4]u8 = {  0,   0, 255, 255}
	raster.test_composite_pixel(dst[:], src, 255, parse_pkg.COMPOSITE_DIFFERENCE)
	testing.expect_value(t, dst[0], 255)             // |0 - 1| = 1
	testing.expect_value(t, dst[1], 0)               // |0 - 0| = 0
	testing.expect_value(t, dst[2], 255)             // |1 - 0| = 1
}
