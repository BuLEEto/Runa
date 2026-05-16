package parse

// gvar — Glyph Variations Table.
//
// For each glyph that varies along one or more axes, gvar carries a
// list of *tuple variations*. Each tuple defines:
//
//   - a peak in normalised axis space (e.g. wght = +1.0 corresponds
//     to the heaviest weight),
//   - optional intermediate start/end coords for asymmetric ramps,
//   - a list of affected point indices (or "all points"),
//   - per-point x and y delta values.
//
// At render time, for a caller-chosen axis tuple, we compute a scalar
// weight per tuple variation (product of per-axis 1-D weights) and
// accumulate `weight × delta` into the base outline's point
// positions.
//
// `gvar` works against the glyf-table outlines we already extract;
// `apply_glyph_variations` mutates the `Outline.points` slice
// in-place after a `glyf_outline` call.
//
// References: OpenType spec, "gvar — Glyph Variations Table".

GVAR_VERSION_1_0 :: u32(0x00010000)

GVAR_FLAG_LONG_OFFSETS :: u16(0x0001)

// Tuple variation header flags.
TUPLE_EMBEDDED_PEAK   :: u16(0x8000)
TUPLE_INTERMEDIATE    :: u16(0x4000)
TUPLE_PRIVATE_POINTS  :: u16(0x2000)
TUPLE_INDEX_MASK      :: u16(0x0FFF)

Gvar :: struct {
	data:                []u8,
	axis_count:          u16,
	shared_tuples_off:   u32,
	shared_tuple_count:  u16,
	glyph_offsets:       []u32,        // per-glyph offset into glyph_data section, length glyph_count + 1
	glyph_data_off:      u32,
}

parse_gvar :: proc(data: []u8, allocator := context.allocator) -> (g: Gvar, err: Error) {
	r := Reader{data = data}
	version := read_u32(&r) or_return
	if version != GVAR_VERSION_1_0 { err = .Unsupported_Format; return }

	axis_count          := read_u16(&r) or_return
	shared_tuple_count  := read_u16(&r) or_return
	shared_tuples_off   := read_u32(&r) or_return
	glyph_count         := read_u16(&r) or_return
	flags               := read_u16(&r) or_return
	glyph_data_off      := read_u32(&r) or_return

	long_offsets := flags & GVAR_FLAG_LONG_OFFSETS != 0

	// Per-glyph offsets follow the header. Promote 16-bit offsets
	// (×2 per spec) to u32 so the rest of the code works on one type.
	offs := make([]u32, glyph_count + 1, allocator)
	if offs == nil && glyph_count > 0 { err = .Out_Of_Memory; return }
	if long_offsets {
		for i in 0..<int(glyph_count) + 1 {
			v, e := read_u32(&r); if e != .None { delete(offs, allocator); err = e; return }
			offs[i] = v
		}
	} else {
		for i in 0..<int(glyph_count) + 1 {
			v, e := read_u16(&r); if e != .None { delete(offs, allocator); err = e; return }
			offs[i] = u32(v) * 2
		}
	}

	g = Gvar{
		data               = data,
		axis_count         = axis_count,
		shared_tuples_off  = shared_tuples_off,
		shared_tuple_count = shared_tuple_count,
		glyph_offsets      = offs,
		glyph_data_off     = glyph_data_off,
	}
	return
}

gvar_destroy :: proc(g: ^Gvar, allocator := context.allocator) {
	delete(g.glyph_offsets, allocator)
	g^ = {}
}

// apply_glyph_variations mutates `outline.points` in-place, applying
// gvar deltas for `gid` at the normalised axis tuple `axis_values`.
// `axis_values` must have length `g.axis_count`.
//
// A glyph with no variation data (offset[gid] == offset[gid+1])
// passes through unmodified — returns `.None`. Malformed tuple
// headers or out-of-range tuple indices return `.Invalid_Table`;
// the outline ends up unchanged on error.
apply_glyph_variations :: proc(g: ^Gvar, gid: Glyph_ID, axis_values: []f32, outline: ^Outline) -> Error {
	if int(gid) + 1 >= len(g.glyph_offsets) { return .None }
	if len(axis_values) != int(g.axis_count) { return .Invalid_Table }

	start := g.glyph_data_off + g.glyph_offsets[gid]
	end   := g.glyph_data_off + g.glyph_offsets[gid + 1]
	if end <= start { return .None }                       // no variation data
	if u64(end) > u64(len(g.data)) { return .Invalid_Table }

	glyph_data := g.data[start:end]
	r := Reader{data = glyph_data}

	tvc_raw := read_u16(&r) or_return
	data_off := read_u16(&r) or_return
	tuple_count    := tvc_raw & TUPLE_INDEX_MASK
	has_shared_pts := tvc_raw & 0x8000 != 0

	// Serialised data (point numbers + deltas) starts at `data_off`
	// from the glyph variation data start.
	if int(data_off) > len(glyph_data) { return .Invalid_Table }
	serialised := glyph_data[data_off:]
	serial_cursor := 0

	num_points := len(outline.points) + 4   // +4 phantom points (per spec)

	// Shared point numbers (used by all tuples that don't carry their
	// own) live at the start of the serialised data.
	shared_points: []u16
	if has_shared_pts {
		pts, consumed, ok := decode_packed_points(serialised, num_points)
		if !ok { return .Invalid_Table }
		shared_points = pts
		serial_cursor += consumed
	}
	defer if shared_points != nil { delete(shared_points, context.temp_allocator) }

	axis_count := int(g.axis_count)

	for t in 0..<int(tuple_count) {
		var_data_size := read_u16(&r) or_return
		tuple_idx     := read_u16(&r) or_return

		// Peak: shared table index OR embedded inline.
		peak := make([]f32, axis_count, context.temp_allocator)
		defer delete(peak, context.temp_allocator)

		if tuple_idx & TUPLE_EMBEDDED_PEAK != 0 {
			for k in 0..<axis_count {
				v, e := read_i16(&r); if e != .None { return e }
				peak[k] = f32(v) / 16384.0
			}
		} else {
			si := int(tuple_idx & TUPLE_INDEX_MASK)
			if si >= int(g.shared_tuple_count) { return .Invalid_Table }
			base := g.shared_tuples_off + u32(si * axis_count * 2)
			if u64(base) + u64(axis_count * 2) > u64(len(g.data)) { return .Invalid_Table }
			for k in 0..<axis_count {
				p := base + u32(k * 2)
				v := i16(u16(g.data[p])<<8 | u16(g.data[p + 1]))
				peak[k] = f32(v) / 16384.0
			}
		}

		// Optional intermediate start/end tuples for asymmetric ramps.
		has_intermediate := tuple_idx & TUPLE_INTERMEDIATE != 0
		istart := make([]f32, axis_count, context.temp_allocator)
		iend   := make([]f32, axis_count, context.temp_allocator)
		defer delete(istart, context.temp_allocator)
		defer delete(iend,   context.temp_allocator)
		if has_intermediate {
			for k in 0..<axis_count {
				v, e := read_i16(&r); if e != .None { return e }
				istart[k] = f32(v) / 16384.0
			}
			for k in 0..<axis_count {
				v, e := read_i16(&r); if e != .None { return e }
				iend[k] = f32(v) / 16384.0
			}
		}

		// Compute scalar weight for this tuple at axis_values.
		weight := compute_tuple_weight(peak, istart, iend, axis_values, has_intermediate)

		// Per-tuple data lives in `serialised`. Decode points (private
		// or shared), then x deltas, then y deltas.
		tuple_payload_end := serial_cursor + int(var_data_size)
		if tuple_payload_end > len(serialised) { return .Invalid_Table }
		payload := serialised[serial_cursor:tuple_payload_end]
		serial_cursor = tuple_payload_end

		pcursor := 0
		points: []u16
		if tuple_idx & TUPLE_PRIVATE_POINTS != 0 {
			pts, consumed, ok := decode_packed_points(payload, num_points)
			if !ok { return .Invalid_Table }
			points = pts
			pcursor = consumed
		} else {
			points = shared_points
		}
		defer if tuple_idx & TUPLE_PRIVATE_POINTS != 0 && points != nil { delete(points, context.temp_allocator) }

		// "All points" sentinel — `decode_packed_points` returns nil
		// for the 0-count case, which means deltas are dense over all
		// points 0..num_points - 1.
		applies_all := points == nil
		delta_count := applies_all ? num_points : len(points)

		dxs, dyc1, ok1 := decode_packed_deltas(payload[pcursor:], delta_count)
		if !ok1 { return .Invalid_Table }
		defer delete(dxs, context.temp_allocator)
		dys, _, ok2 := decode_packed_deltas(payload[pcursor + dyc1:], delta_count)
		if !ok2 { return .Invalid_Table }
		defer delete(dys, context.temp_allocator)

		// Tuple deltas only meaningfully change the outline when
		// weight is non-zero. Saves a fair bit of loop overhead for
		// glyphs whose tuple peaks don't match the requested axis.
		if weight == 0 { continue }

		if applies_all {
			n := min(len(dxs), len(outline.points))
			for i in 0..<n {
				outline.points[i].x += i32(f32(dxs[i]) * weight)
				outline.points[i].y += i32(f32(dys[i]) * weight)
			}
		} else {
			for i in 0..<len(points) {
				pi := int(points[i])
				if pi >= len(outline.points) { continue }
				if i >= len(dxs) || i >= len(dys) { break }
				outline.points[pi].x += i32(f32(dxs[i]) * weight)
				outline.points[pi].y += i32(f32(dys[i]) * weight)
			}
		}
	}
	return .None
}

// compute_tuple_weight is the per-axis product from the OpenType spec
// section "Algorithm for interpolation of instances".
@(private)
compute_tuple_weight :: proc(peak, istart, iend, axis_values: []f32, has_intermediate: bool) -> f32 {
	weight: f32 = 1.0
	for k in 0..<len(axis_values) {
		v := axis_values[k]
		p := peak[k]
		if p == 0 { continue }                          // axis doesn't affect this tuple
		if v == 0 || (v < 0) != (p < 0) { return 0 }    // sign mismatch / default → no contribution
		axis_w: f32
		if !has_intermediate {
			if v == p { axis_w = 1 } else {
				if (p > 0 && v > p) || (p < 0 && v < p) {
					return 0
				}
				axis_w = v / p
			}
		} else {
			s := istart[k]
			e := iend[k]
			if v <= s || v >= e { return 0 }
			if v == p           { axis_w = 1 }
			else if v < p       { axis_w = (v - s) / (p - s) }
			else                { axis_w = (e - v) / (e - p) }
		}
		weight *= axis_w
	}
	return weight
}

// decode_packed_points returns the indexed point list. Returns
// (nil, 1, true) for the "all points" sentinel (first byte == 0).
// Allocates from `context.temp_allocator`.
@(private)
decode_packed_points :: proc(data: []u8, num_points: int) -> (pts: []u16, consumed: int, ok: bool) {
	if len(data) == 0 { return nil, 0, false }
	first := data[0]
	if first == 0 {
		// All points implied.
		return nil, 1, true
	}
	cursor := 1
	count: int
	if first & 0x80 != 0 {
		if cursor >= len(data) { return nil, 0, false }
		count = (int(first & 0x7F) << 8) | int(data[cursor])
		cursor += 1
	} else {
		count = int(first)
	}

	out := make([dynamic]u16, 0, count, context.temp_allocator)
	prev: u16 = 0
	for len(out) < count {
		if cursor >= len(data) { return nil, 0, false }
		control := data[cursor]
		cursor += 1
		run := int(control & 0x7F) + 1
		short := control & 0x80 == 0
		for i in 0..<run {
			if len(out) >= count { break }
			delta: u16
			if short {
				if cursor >= len(data) { return nil, 0, false }
				delta = u16(data[cursor])
				cursor += 1
			} else {
				if cursor + 1 >= len(data) { return nil, 0, false }
				delta = u16(data[cursor])<<8 | u16(data[cursor + 1])
				cursor += 2
			}
			prev += delta
			append(&out, prev)
		}
	}
	return out[:], cursor, true
}

// decode_packed_deltas reads `count` packed signed-integer deltas.
// Format: control byte (high 2 bits encode value format, low 6 bits
// encode run length − 1) followed by zero or more value bytes.
@(private)
decode_packed_deltas :: proc(data: []u8, count: int) -> (out: []i16, consumed: int, ok: bool) {
	values := make([dynamic]i16, 0, count, context.temp_allocator)
	cursor := 0
	for len(values) < count {
		if cursor >= len(data) { return nil, 0, false }
		control := data[cursor]
		cursor += 1
		run := int(control & 0x3F) + 1
		switch control & 0xC0 {
		case 0x80:                                   // zero run
			for i in 0..<run {
				if len(values) >= count { break }
				append(&values, i16(0))
			}
		case 0x40:                                   // 16-bit signed values
			for i in 0..<run {
				if len(values) >= count { break }
				if cursor + 1 >= len(data) { return nil, 0, false }
				v := i16(u16(data[cursor])<<8 | u16(data[cursor + 1]))
				cursor += 2
				append(&values, v)
			}
		case 0x00:                                   // 8-bit signed values
			for i in 0..<run {
				if len(values) >= count { break }
				if cursor >= len(data) { return nil, 0, false }
				v := i16(i8(data[cursor]))
				cursor += 1
				append(&values, v)
			}
		case:                                        // 0xC0 reserved
			return nil, 0, false
		}
	}
	return values[:], cursor, true
}
