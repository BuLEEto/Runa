/*
Atlas allocator tests. Exercises shelf packing, page growth, dirty
tracking, and the slot maths.
*/
package atlas_test

import "core:mem"
import "core:testing"

import raster "../../raster"
import runa "../.."

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

@(test)
test_dirty_snapshot_can_be_retried :: proc(t: ^testing.T) {
	a := raster.atlas_make(8, 8)
	defer raster.atlas_destroy(&a)
	pixels := [4]u8{1, 2, 3, 4}
	_, err := raster.atlas_pack_alpha(&a, pixels[:], 2, 2, {})
	testing.expect_value(t, err, raster.Atlas_Error.None)

	first := raster.atlas_dirty_snapshot(&a)
	second := raster.atlas_dirty_snapshot(&a)
	defer delete(second)
	testing.expect_value(t, len(first), 1)
	testing.expect_value(t, len(second), 1)
	testing.expect_value(t, first[0], second[0])
	testing.expect(t, a.pages_alpha[0].is_dirty, "snapshot must not clear the page")
	testing.expect_value(t, first[0].x, u16(0))
	testing.expect_value(t, first[0].y, u16(0))
	testing.expect_value(t, first[0].w, u16(2))
	testing.expect_value(t, first[0].h, u16(2))

	// Abandon the first upload and discard its metadata without acknowledging.
	delete(first)
	retry := raster.atlas_dirty_snapshot(&a)
	defer delete(retry)
	testing.expect_value(t, len(retry), 1)
	testing.expect_value(t, retry[0], second[0])
	raster.atlas_dirty_ack(&a, retry)
	raster.atlas_dirty_ack(&a, retry)
	clean := raster.atlas_dirty_snapshot(&a)
	defer delete(clean)
	testing.expect_value(t, len(clean), 0)
}

@(test)
test_dirty_ack_preserves_later_write :: proc(t: ^testing.T) {
	a := raster.atlas_make(8, 8)
	defer raster.atlas_destroy(&a)
	pixel := [1]u8{255}
	_, err := raster.atlas_pack_alpha(&a, pixel[:], 1, 1, {})
	testing.expect_value(t, err, raster.Atlas_Error.None)
	older := raster.atlas_dirty_snapshot(&a)
	defer delete(older)

	_, err = raster.atlas_pack_alpha(&a, pixel[:], 1, 1, {})
	testing.expect_value(t, err, raster.Atlas_Error.None)
	raster.atlas_dirty_ack(&a, older)
	raster.atlas_dirty_ack(&a, older)
	newer := raster.atlas_dirty_snapshot(&a)
	defer delete(newer)
	testing.expect_value(t, len(newer), 1)
	testing.expect(t, newer[0].generation > older[0].generation)
	testing.expect_value(t, newer[0].w, u16(2))
	raster.atlas_dirty_ack(&a, newer)
	testing.expect(t, !a.pages_alpha[0].is_dirty)

	// An already acknowledged token must not clear a new dirty interval either.
	_, err = raster.atlas_pack_alpha(&a, pixel[:], 1, 1, {})
	testing.expect_value(t, err, raster.Atlas_Error.None)
	raster.atlas_dirty_ack(&a, older)
	raster.atlas_dirty_ack(&a, newer)
	latest := raster.atlas_dirty_snapshot(&a)
	defer delete(latest)
	testing.expect_value(t, len(latest), 1)
	testing.expect(t, latest[0].generation > newer[0].generation)
	testing.expect_value(t, latest[0].x, u16(2))
}

@(test)
test_dirty_ack_preserves_write_inside_existing_bounds :: proc(t: ^testing.T) {
	a := raster.atlas_make(8, 8)
	defer raster.atlas_destroy(&a)
	first_shelf := [12]u8{}
	second_shelf := [8]u8{}
	gap := [2]u8{77, 88}
	_, e1 := raster.atlas_pack_alpha(&a, first_shelf[:], 6, 2, {})
	_, e2 := raster.atlas_pack_alpha(&a, second_shelf[:], 8, 1, {})
	testing.expect_value(t, e1, raster.Atlas_Error.None)
	testing.expect_value(t, e2, raster.Atlas_Error.None)
	before := raster.atlas_dirty_snapshot(&a)
	defer delete(before)
	testing.expect_value(t, len(before), 1)
	testing.expect_value(t, before[0].w, u16(8))
	testing.expect_value(t, before[0].h, u16(3))

	// Fill the first shelf's remaining width, wholly inside the old dirty bbox.
	_, e3 := raster.atlas_pack_alpha(&a, gap[:], 2, 1, {})
	testing.expect_value(t, e3, raster.Atlas_Error.None)
	raster.atlas_dirty_ack(&a, before)
	after := raster.atlas_dirty_snapshot(&a)
	defer delete(after)
	if !testing.expect_value(t, len(after), 1) { return }
	testing.expect_value(t, after[0].x, before[0].x)
	testing.expect_value(t, after[0].y, before[0].y)
	testing.expect_value(t, after[0].w, before[0].w)
	testing.expect_value(t, after[0].h, before[0].h)
	testing.expect(t, after[0].generation > before[0].generation)
	testing.expect_value(t, a.pages_alpha[0].pixels[6], u8(77))
	testing.expect_value(t, a.pages_alpha[0].pixels[7], u8(88))
	raster.atlas_dirty_ack(&a, after)
	testing.expect(t, !a.pages_alpha[0].is_dirty)
}

@(test)
test_dirty_ack_can_acknowledge_individual_alpha_and_rgba_pages :: proc(t: ^testing.T) {
	a := raster.atlas_make(8, 8)
	defer raster.atlas_destroy(&a)
	alpha := [64]u8{}
	color := [4]u8{1, 2, 3, 255}
	_, e1 := raster.atlas_pack_alpha(&a, alpha[:], 8, 8, {})
	_, e2 := raster.atlas_pack_alpha(&a, alpha[:], 8, 8, {})
	_, e3 := raster.atlas_pack_rgba(&a, color[:], 1, 1, {})
	testing.expect_value(t, e1, raster.Atlas_Error.None)
	testing.expect_value(t, e2, raster.Atlas_Error.None)
	testing.expect_value(t, e3, raster.Atlas_Error.None)
	snapshot := raster.atlas_dirty_snapshot(&a)
	defer delete(snapshot)
	testing.expect_value(t, len(snapshot), 3)
	for entry, i in snapshot {
		if !entry.is_color && entry.page_index == 0 {
			raster.atlas_dirty_ack(&a, snapshot[i:i+1])
		}
	}
	testing.expect(t, !a.pages_alpha[0].is_dirty)
	testing.expect(t, a.pages_alpha[1].is_dirty)
	testing.expect(t, a.pages_color[0].is_dirty, "RGBA page 0 is independent of alpha page 0")
	remaining := raster.atlas_dirty_snapshot(&a)
	defer delete(remaining)
	testing.expect_value(t, len(remaining), 2)
	raster.atlas_dirty_ack(&a, snapshot)
	testing.expect(t, !a.pages_alpha[1].is_dirty && !a.pages_color[0].is_dirty)
}

@(test)
test_dirty_snapshot_preserves_legacy_flush_behavior :: proc(t: ^testing.T) {
	a := raster.atlas_make(8, 8)
	defer raster.atlas_destroy(&a)
	pixel := [1]u8{255}
	_, err := raster.atlas_pack_alpha(&a, pixel[:], 1, 1, {})
	testing.expect_value(t, err, raster.Atlas_Error.None)
	snapshot := raster.atlas_dirty_snapshot(&a)
	defer delete(snapshot)
	flushed := raster.atlas_flush_dirty(&a)
	defer delete(flushed)
	testing.expect_value(t, len(flushed), 1)
	testing.expect_value(t, flushed[0].page_index, snapshot[0].page_index)
	testing.expect_value(t, flushed[0].is_color, snapshot[0].is_color)
	testing.expect_value(t, flushed[0].x, snapshot[0].x)
	testing.expect_value(t, flushed[0].y, snapshot[0].y)
	testing.expect_value(t, flushed[0].w, snapshot[0].w)
	testing.expect_value(t, flushed[0].h, snapshot[0].h)
	clean := raster.atlas_dirty_snapshot(&a)
	defer delete(clean)
	testing.expect_value(t, len(clean), 0)
	flushed_again := raster.atlas_flush_dirty(&a)
	defer delete(flushed_again)
	testing.expect_value(t, len(flushed_again), 0)

	_, err = raster.atlas_pack_alpha(&a, pixel[:], 1, 1, {})
	testing.expect_value(t, err, raster.Atlas_Error.None)
	raster.atlas_dirty_ack(&a, snapshot)
	testing.expect(t, a.pages_alpha[0].is_dirty, "flush must not reset the write generation")
}

@(test)
test_dirty_ack_ignores_invalid_page_or_rectangle :: proc(t: ^testing.T) {
	a := raster.atlas_make(8, 8)
	defer raster.atlas_destroy(&a)
	pixel := [1]u8{1}
	_, err := raster.atlas_pack_alpha(&a, pixel[:], 1, 1, {})
	testing.expect_value(t, err, raster.Atlas_Error.None)
	snapshot := raster.atlas_dirty_snapshot(&a)
	defer delete(snapshot)
	invalid := [3]raster.Atlas_Dirty_Snapshot{snapshot[0], snapshot[0], snapshot[0]}
	invalid[0].page_index = 1
	invalid[1].is_color = true
	invalid[2].w = 8
	raster.atlas_dirty_ack(&a, invalid[:])
	testing.expect(t, a.pages_alpha[0].is_dirty)
	raster.atlas_dirty_ack(&a, nil)
	testing.expect(t, a.pages_alpha[0].is_dirty)
	raster.atlas_dirty_ack(&a, snapshot)
	testing.expect(t, !a.pages_alpha[0].is_dirty)
}

Snapshot_Allocator_State :: struct {
	backing: mem.Allocator,
	allocations, frees, resizes: int,
	allocated_bytes, freed_bytes: int,
	allocated_pointer, freed_pointer: rawptr,
}

snapshot_allocator_proc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location,
) -> ([]u8, mem.Allocator_Error) {
	s := cast(^Snapshot_Allocator_State)data
	result, err := s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, loc)
	if err != .None { return result, err }
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		s.allocations += 1
		s.allocated_bytes += size
		s.allocated_pointer = raw_data(result)
	case .Free:
		if old_memory != nil {
			s.frees += 1
			s.freed_bytes += old_size
			s.freed_pointer = old_memory
		}
	case .Resize, .Resize_Non_Zeroed:
		s.resizes += 1
	}
	return result, err
}

@(test)
test_dirty_snapshot_uses_exact_size_and_requested_allocator :: proc(t: ^testing.T) {
	a := raster.atlas_make(8, 8)
	defer raster.atlas_destroy(&a)
	full := [64]u8{}
	pixel := [1]u8{1}
	_, e1 := raster.atlas_pack_alpha(&a, full[:], 8, 8, {})
	_, e2 := raster.atlas_pack_alpha(&a, full[:], 8, 8, {})
	testing.expect_value(t, e1, raster.Atlas_Error.None)
	testing.expect_value(t, e2, raster.Atlas_Error.None)
	flushed := raster.atlas_flush_dirty(&a)
	defer delete(flushed)
	_, e3 := raster.atlas_pack_alpha(&a, pixel[:], 1, 1, {})
	testing.expect_value(t, e3, raster.Atlas_Error.None)
	testing.expect_value(t, len(a.pages_alpha), 3)

	state := Snapshot_Allocator_State{backing = context.allocator}
	allocator := mem.Allocator{procedure = snapshot_allocator_proc, data = &state}
	snapshot := raster.atlas_dirty_snapshot(&a, allocator)
	testing.expect_value(t, len(snapshot), 1)
	testing.expect_value(t, snapshot[0].page_index, u16(2))
	testing.expect_value(t, state.allocations, 1)
	testing.expect_value(t, state.resizes, 0)
	testing.expect_value(t, state.allocated_bytes, size_of(raster.Atlas_Dirty_Snapshot))
	raster.atlas_dirty_ack(&a, snapshot)
	delete(snapshot, allocator)
	testing.expect_value(t, state.frees, 1)
	testing.expect_value(t, state.freed_bytes, state.allocated_bytes)
	testing.expect_value(t, state.freed_pointer, state.allocated_pointer)

	clean := raster.atlas_dirty_snapshot(&a, allocator)
	testing.expect_value(t, len(clean), 0)
	testing.expect(t, raw_data(clean) == nil)
	delete(clean, allocator)
	testing.expect(t, state.allocations == 1, "clean snapshot must not allocate")
	testing.expect_value(t, state.frees, 1)
}

@(test)
test_dirty_snapshot_public_facade :: proc(t: ^testing.T) {
	a := runa.atlas_make(8, 8)
	defer runa.atlas_destroy(&a)
	pixel := [1]u8{1}
	_, err := runa.atlas_pack_alpha(&a, pixel[:], 1, 1, {})
	testing.expect_value(t, err, raster.Atlas_Error.None)
	snapshot: []runa.Atlas_Dirty_Snapshot = runa.atlas_dirty_snapshot(&a)
	defer delete(snapshot)
	testing.expect_value(t, len(snapshot), 1)
	runa.atlas_dirty_ack(&a, snapshot)
	testing.expect(t, !a.pages_alpha[0].is_dirty)
}
