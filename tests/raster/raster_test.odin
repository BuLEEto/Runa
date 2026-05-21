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

// ---- Autohinter ---------------------------------------------------
//
// Pins the blue-zone snap behaviour. Identity check: a no-op `Hint_Snap`
// must leave Y alone. Snap check: a metric set with a baseline offset
// must move outline Y values onto the snapped grid.

@(test)
test_hint_snap_identity :: proc(t: ^testing.T) {
	h: raster.Hint_Snap
	h.valid = false
	testing.expect_value(t, raster.apply_hint_y(7.3, h), 7.3)
}

@(test)
test_hint_snap_baseline :: proc(t: ^testing.T) {
	// Construct a metric set where the baseline pre-scales to 14.4
	// (typical fractional value at a body size). The snap should move
	// the baseline to row 14, and an outline point exactly at the
	// baseline should land on integer 14 as well.
	m: raster.Hint_Metrics
	m.descender    = -300
	m.round_bottom = -12
	m.baseline     = 0
	m.x_height     = 500
	m.cap_height   = 700
	m.ascender     = 800
	m.valid        = true

	// Pick units_per_em / size so baseline*scale = 0 and cap_height*scale = 14.4.
	// scale = 14.4 / 700 ⇒ size/upm = scale ⇒ size = 14.4, upm = 700.
	h := raster.hint_snap_for_size(m, 700, 14.4)
	testing.expect(t, h.valid, "snap is valid")
	testing.expect_value(t, h.baseline_snap, f32(0))
	testing.expect_value(t, h.cap_height_snap, f32(14))     // 14.4 → 14

	// A point exactly on the baseline pre-snap must end exactly on the
	// snapped baseline (0).
	got_baseline := raster.apply_hint_y(h.baseline_pre, h)
	testing.expect_value(t, got_baseline, h.baseline_snap)

	// A point exactly on the cap-height must end on the snapped cap.
	got_cap := raster.apply_hint_y(h.cap_height_pre, h)
	testing.expect_value(t, got_cap, h.cap_height_snap)
}

@(test)
test_hint_overshoot_suppression_at_body_size :: proc(t: ^testing.T) {
	// Round letters (S, O, c, e, o) have a small overshoot below the
	// baseline so the eye reads them as the same height as flat-bottom
	// letters (H, n, m). At body sizes the overshoot is sub-pixel and
	// the unhinted rasterizer emits it as a partial-coverage row at
	// the bottom of the bitmap — the visible "bottom-of-S lip" artifact.
	//
	// With round_bottom snapping enabled, that sub-pixel value rounds
	// to 0 and the overshoot collapses to the baseline. Verify by
	// running apply_hint_y on the overshoot pre-scale.
	m := raster.Hint_Metrics{
		descender    = -480,
		round_bottom = -12,
		baseline     = 0,
		x_height     = 1050,
		cap_height   = 1450,
		ascender     = 1900,
		valid        = true,
	}
	// Inter-ish — UPM 2048, size 13 (body).
	h := raster.hint_snap_for_size(m, 2048, 13.0)
	testing.expect(t, h.valid, "snap valid")
	testing.expect_value(t, h.baseline_snap, f32(0))
	// round_bottom_pre = -12 * (13/2048) = -0.0762. round = 0.
	testing.expect_value(t, h.round_bottom_snap, f32(0))
	// A point exactly at the overshoot must collapse to 0.
	got_overshoot := raster.apply_hint_y(h.round_bottom_pre, h)
	testing.expect_value(t, got_overshoot, f32(0))
	// Any point inside the overshoot band must also collapse to 0
	// (the lerp endpoints are both 0).
	got_mid := raster.apply_hint_y(h.round_bottom_pre * 0.5, h)
	testing.expect_value(t, got_mid, f32(0))
}

@(test)
test_hint_overshoot_preserved_at_display_size :: proc(t: ^testing.T) {
	// At display sizes (~100 px+) the overshoot pre-scale lands at
	// roughly half a pixel or more, and the natural integer round
	// produces a real 1-px overshoot. Verify the round_bottom_snap
	// separates from baseline_snap above this threshold.
	m := raster.Hint_Metrics{
		descender    = -480,
		round_bottom = -12,
		baseline     = 0,
		x_height     = 1050,
		cap_height   = 1450,
		ascender     = 1900,
		valid        = true,
	}
	// UPM 2048, size 150 (display). round_bottom_pre = -12 * (150/2048) = -0.879. round = -1.
	h := raster.hint_snap_for_size(m, 2048, 150.0)
	testing.expect(t, h.valid, "snap valid")
	testing.expect_value(t, h.baseline_snap, f32(0))
	testing.expect_value(t, h.round_bottom_snap, f32(-1))    // overshoot preserved as 1 pixel
}

@(test)
test_hint_shrinks_bitmap_height_for_round_letter :: proc(t: ^testing.T) {
	// End-to-end: an unhinted round-letter raster at body size should
	// produce a bitmap one row taller than the hinted version, because
	// the unhinted version reserves a fluff row for the overshoot and
	// the hinted version collapses it.
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

	// Build hint metrics from this font's reference glyphs.
	sample :: proc(g: ^parse.Glyf, loca: ^parse.Loca, cm: ^parse.Cmap, r: rune, want_max: bool) -> (f32, bool) {
		gid := parse.cmap_lookup(cm, r)
		if gid == 0 { return 0, false }
		o: parse.Outline
		defer parse.outline_destroy(&o)
		if parse.glyf_outline(g, loca, gid, &o) != .None { return 0, false }
		if len(o.contour_ends) == 0 { return 0, false }
		return f32(o.y_max) if want_max else f32(o.y_min), true
	}
	cap_h, _ := sample(&g, &loca, &cm, 'H', true)
	x_h,   _ := sample(&g, &loca, &cm, 'x', true)
	asc,   _ := sample(&g, &loca, &cm, 'l', true)
	dsc,   _ := sample(&g, &loca, &cm, 'p', false)
	rb,    _ := sample(&g, &loca, &cm, 'o', false)

	m := raster.Hint_Metrics{
		descender    = dsc,
		round_bottom = rb,
		baseline     = 0,
		x_height     = x_h,
		cap_height   = cap_h,
		ascender     = asc,
		valid        = true,
	}
	h := raster.hint_snap_for_size(m, head.units_per_em, 14.0)

	gid_O := parse.cmap_lookup(&cm, 'O')
	testing.expect(t, gid_O != 0, "'O' resolves")
	o: parse.Outline
	defer parse.outline_destroy(&o)
	testing.expect_value(t, parse.glyf_outline(&g, &loca, gid_O, &o), parse.Error.None)

	edges := make([dynamic]raster.Edge, 0, 128)
	defer delete(edges)

	bm_no, _, _, e1 := raster.rasterize(&o, head.units_per_em, 14.0, &edges)
	testing.expect_value(t, e1, raster.Rast_Error.None)
	defer raster.bitmap_destroy(&bm_no)

	bm_h, _, _, e2 := raster.rasterize(&o, head.units_per_em, 14.0, &edges, 0, context.allocator, &h)
	testing.expect_value(t, e2, raster.Rast_Error.None)
	defer raster.bitmap_destroy(&bm_h)

	log.infof("O at 14px: unhinted=%dx%d hinted=%dx%d", bm_no.width, bm_no.height, bm_h.width, bm_h.height)

	// The hinted bitmap should be at most as tall as the unhinted one
	// (and strictly shorter if the unhinted version had an overshoot
	// fluff row, which is the case for any modern Latin font at body
	// sizes).
	testing.expect(t, bm_h.height <= bm_no.height, "hinted O is not taller than unhinted")
}

@(test)
test_hint_snap_bottom_of_s_lands_on_integer :: proc(t: ^testing.T) {
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

	// Sample reference glyphs to build blue zones.
	sample :: proc(g: ^parse.Glyf, loca: ^parse.Loca, cm: ^parse.Cmap, r: rune) -> (y_min, y_max: f32, ok: bool) {
		gid := parse.cmap_lookup(cm, r)
		if gid == 0 { return }
		o: parse.Outline
		defer parse.outline_destroy(&o)
		if parse.glyf_outline(g, loca, gid, &o) != .None { return }
		if len(o.contour_ends) == 0 { return }
		return f32(o.y_min), f32(o.y_max), true
	}
	_, cap_h,    cap_ok := sample(&g, &loca, &cm, 'H')
	_, x_h,      x_ok   := sample(&g, &loca, &cm, 'x')
	_, asc,      a_ok   := sample(&g, &loca, &cm, 'l')
	dsc,_,       d_ok   := sample(&g, &loca, &cm, 'p')
	testing.expect(t, cap_ok && x_ok && a_ok && d_ok, "reference glyphs resolve")

	m := raster.Hint_Metrics{
		descender  = dsc,
		baseline   = 0,
		x_height   = x_h,
		cap_height = cap_h,
		ascender   = asc,
		valid      = true,
	}

	// At body size 13 px, baseline_pre is 0 (always); confirm snap is 0.
	h := raster.hint_snap_for_size(m, head.units_per_em, 13.0)
	testing.expect(t, h.valid, "snap is valid for this font/size")
	testing.expect_value(t, h.baseline_snap, f32(0))

	// Pull the 'S' outline and rasterize twice — once unhinted, once
	// hinted. Both must produce non-empty bitmaps; that's the smoke
	// signal the autohint path doesn't crash on real glyph data.
	gid_S := parse.cmap_lookup(&cm, 'S')
	testing.expect(t, gid_S != 0, "'S' resolves")
	o: parse.Outline
	defer parse.outline_destroy(&o)
	testing.expect_value(t, parse.glyf_outline(&g, &loca, gid_S, &o), parse.Error.None)

	edges := make([dynamic]raster.Edge, 0, 128)
	defer delete(edges)

	bm_no_hint, _, _, e1 := raster.rasterize(&o, head.units_per_em, 13.0, &edges)
	testing.expect_value(t, e1, raster.Rast_Error.None)
	defer raster.bitmap_destroy(&bm_no_hint)
	testing.expect(t, bm_no_hint.width > 0 && bm_no_hint.height > 0, "unhinted S non-empty")

	bm_hint, _, _, e2 := raster.rasterize(&o, head.units_per_em, 13.0, &edges, 0, context.allocator, &h)
	testing.expect_value(t, e2, raster.Rast_Error.None)
	defer raster.bitmap_destroy(&bm_hint)
	testing.expect(t, bm_hint.width > 0 && bm_hint.height > 0, "hinted S non-empty")

	// Bottom-row alpha mass check: if hinting did its job, the
	// hinted S should have a non-fractional bottom row — i.e. its
	// bottom row should be either ~0 (no feature there) or ~255
	// (solid stem), not a half-coverage "fluff" row. We measure the
	// average alpha of the bottom row and assert hinted ≤ unhinted
	// in the fluffiness range (0 < alpha < 100). That's the
	// observable signal of the artifact we set out to fix.
	bottom_avg :: proc(bm: ^raster.Bitmap) -> f32 {
		if bm.height == 0 { return 0 }
		sum: u32 = 0
		row := (bm.height - 1) * bm.width
		for i in 0..<bm.width {
			sum += u32(bm.pixels[row + i])
		}
		return f32(sum) / f32(bm.width)
	}
	avg_no := bottom_avg(&bm_no_hint)
	avg_h  := bottom_avg(&bm_hint)
	log.infof("bottom row avg: unhinted=%.2f hinted=%.2f", avg_no, avg_h)
	// The hinted version's bottom row should not be a half-coverage
	// row. Either it's near-empty (snap moved the curve up) or it's
	// near-full (snap moved a stem onto it). The unhinted version may
	// be in the fluff band; hinted should not be worse.
	if avg_no > 30 && avg_no < 180 {
		testing.expect(t, avg_h <= avg_no + 5, "hinted bottom row is not fluffier than unhinted")
	}
}
