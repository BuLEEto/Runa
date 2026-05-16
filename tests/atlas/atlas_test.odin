/*
Atlas allocator tests. Exercises shelf packing, page growth, dirty
tracking, and the slot maths.
*/
package atlas_test

import "core:testing"

import raster "../../raster"

@(test)
test_pack_single_glyph :: proc(t: ^testing.T) {
	a := raster.atlas_make(64, 64)
	defer raster.atlas_destroy(&a)

	src := make([]u8, 8 * 8)
	defer delete(src)
	for i in 0..<len(src) { src[i] = u8(i) }

	slot, err := raster.atlas_pack_alpha(&a, src, 8, 8, [2]f32{0, 0})
	testing.expect_value(t, err, raster.Atlas_Error.None)
	testing.expect_value(t, slot.is_color, false)
	testing.expect_value(t, slot.px_size, [2]u16{8, 8})
	testing.expect_value(t, slot.page_index, u16(0))
	testing.expect(t, slot.uv_rect[0] == 0, "u0 at origin")
	testing.expect(t, slot.uv_rect[1] == 0, "v0 at origin")
	testing.expect_value(t, len(a.pages_alpha), 1)
}

@(test)
test_shelf_packing_fits_multiple :: proc(t: ^testing.T) {
	a := raster.atlas_make(64, 64)
	defer raster.atlas_destroy(&a)

	src := make([]u8, 16 * 8)
	defer delete(src)

	// Three 16×8 slots should share one shelf.
	for i in 0..<3 {
		s, e := raster.atlas_pack_alpha(&a, src, 16, 8, [2]f32{0, 0})
		testing.expect_value(t, e, raster.Atlas_Error.None)
		testing.expect_value(t, s.page_index, u16(0))
	}
	testing.expect_value(t, len(a.pages_alpha), 1)
}

@(test)
test_new_page_when_full :: proc(t: ^testing.T) {
	a := raster.atlas_make(32, 32)
	defer raster.atlas_destroy(&a)

	src := make([]u8, 32 * 32)
	defer delete(src)

	// One 32×32 fills page 1.
	_, e1 := raster.atlas_pack_alpha(&a, src, 32, 32, [2]f32{0, 0})
	testing.expect_value(t, e1, raster.Atlas_Error.None)
	testing.expect_value(t, len(a.pages_alpha), 1)

	// Second 32×32 needs page 2.
	s2, e2 := raster.atlas_pack_alpha(&a, src, 32, 32, [2]f32{0, 0})
	testing.expect_value(t, e2, raster.Atlas_Error.None)
	testing.expect_value(t, s2.page_index, u16(1))
	testing.expect_value(t, len(a.pages_alpha), 2)
}

@(test)
test_slot_larger_than_page_rejected :: proc(t: ^testing.T) {
	a := raster.atlas_make(16, 16)
	defer raster.atlas_destroy(&a)
	src := make([]u8, 32 * 32)
	defer delete(src)

	_, err := raster.atlas_pack_alpha(&a, src, 32, 32, [2]f32{0, 0})
	testing.expect_value(t, err, raster.Atlas_Error.Slot_Too_Large)
}

@(test)
test_rgba_and_alpha_pages_separate :: proc(t: ^testing.T) {
	a := raster.atlas_make(64, 64)
	defer raster.atlas_destroy(&a)

	mono := make([]u8, 8 * 8)
	defer delete(mono)
	rgba := make([]u8, 8 * 8 * 4)
	defer delete(rgba)

	s1, _ := raster.atlas_pack_alpha(&a, mono, 8, 8, [2]f32{0, 0})
	s2, _ := raster.atlas_pack_rgba (&a, rgba, 8, 8, [2]f32{0, 0})

	testing.expect_value(t, s1.is_color, false)
	testing.expect_value(t, s2.is_color, true)
	testing.expect_value(t, len(a.pages_alpha), 1)
	testing.expect_value(t, len(a.pages_color), 1)
}

@(test)
test_dirty_tracking :: proc(t: ^testing.T) {
	a := raster.atlas_make(64, 64)
	defer raster.atlas_destroy(&a)

	src := make([]u8, 8 * 8)
	defer delete(src)
	raster.atlas_pack_alpha(&a, src, 8, 8, [2]f32{0, 0})
	raster.atlas_pack_alpha(&a, src, 8, 8, [2]f32{0, 0})

	dirty := raster.atlas_flush_dirty(&a)
	defer delete(dirty)

	testing.expect_value(t, len(dirty), 1)
	d := dirty[0]
	testing.expect_value(t, d.x, u16(0))
	testing.expect_value(t, d.y, u16(0))
	testing.expect_value(t, d.w, u16(16))      // two 8-wide slots
	testing.expect_value(t, d.h, u16(8))

	// Second flush — clean now, returns empty.
	dirty2 := raster.atlas_flush_dirty(&a)
	defer delete(dirty2)
	testing.expect_value(t, len(dirty2), 0)
}
