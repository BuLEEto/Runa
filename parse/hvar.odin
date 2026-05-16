package parse

// HVAR — Horizontal Metrics Variations Table.
//
// Companion to `hmtx` for variable fonts. The base `hmtx` advance is
// the *default-instance* advance; HVAR carries per-axis deltas that
// shift the advance as the caller drives axes off their defaults.
//
// Without HVAR, bold-weight glyphs land on the regular-weight pen —
// letter spacing visibly drifts ("tight" at heavy weight, "loose" at
// light). With HVAR, advance widths follow the chosen instance.
//
// HVAR also optionally carries LSB and RSB delta sets; v0.1 reads
// only the advance-width side (the only one any consumer asks for
// today). LSB / RSB deltas are wire-readable but unused.
//
// References: OpenType spec, "HVAR — Horizontal Metrics Variations".

HVAR_VERSION_1_0 :: u32(0x00010000)

Hvar :: struct {
	data:                 []u8,
	ivs_off:              u32,
	advance_mapping_off:  u32,                          // 0 if absent → inner = gid, outer = 0
}

parse_hvar :: proc(data: []u8) -> (h: Hvar, err: Error) {
	r := Reader{data = data}
	version := read_u32(&r) or_return
	if version != HVAR_VERSION_1_0 { err = .Unsupported_Format; return }

	h.data = data
	h.ivs_off            = read_u32(&r) or_return
	h.advance_mapping_off = read_u32(&r) or_return
	// LSB / RSB mapping offsets follow but aren't used at v0.5.
	return
}

// hvar_advance_delta returns the signed advance-width delta (in font
// units) that should be added to `hmtx`'s base advance for `gid`
// at the normalised axis tuple `axis_values`. Returns 0 if the
// glyph has no variation data or any required structure is missing.
hvar_advance_delta :: proc(h: ^Hvar, gid: Glyph_ID, axis_values: []f32) -> i32 {
	outer, inner, ok := hvar_resolve_index(h, gid)
	if !ok { return 0 }
	return ivs_lookup_delta(h.data, h.ivs_off, outer, inner, axis_values)
}

// hvar_resolve_index maps a glyph ID to (outerIndex, innerIndex)
// inside the Item Variation Store. If HVAR's advance-mapping is
// absent, the spec says outer = 0 and inner = gid.
@(private)
hvar_resolve_index :: proc(h: ^Hvar, gid: Glyph_ID) -> (outer: u16, inner: u16, ok: bool) {
	if h.advance_mapping_off == 0 {
		return 0, u16(gid), true
	}
	base := h.advance_mapping_off
	if u64(base) + 4 > u64(len(h.data)) { return }
	entry_format := u16(h.data[base])<<8 | u16(h.data[base + 1])
	map_count    := u16(h.data[base + 2])<<8 | u16(h.data[base + 3])

	if u16(gid) >= map_count {
		// Out-of-table glyphs collapse to the last entry per spec.
		return 0, map_count - 1, true
	}

	// entry_format layout: low 4 bits = "inner index size − 1" in bits
	// (so 0 = 1 bit, 15 = 16 bits), bits 4–5 = "map entry size − 1"
	// in bytes (0..3 → 1..4 bytes).
	inner_bits := int(entry_format & 0x000F) + 1
	entry_size := int((entry_format & 0x0030) >> 4) + 1

	row := base + 4 + u32(gid) * u32(entry_size)
	if u64(row) + u64(entry_size) > u64(len(h.data)) { return }

	raw: u32
	for i in 0..<entry_size {
		raw = (raw << 8) | u32(h.data[row + u32(i)])
	}
	inner_mask: u32 = (u32(1) << uint(inner_bits)) - 1
	inner = u16(raw & inner_mask)
	outer = u16(raw >> uint(inner_bits))
	ok = true
	return
}

// ivs_lookup_delta walks the Item Variation Store at `ivs_off`,
// finds delta-set (outer, inner), computes the region-weight scalar
// for each region the delta-set references, and returns the
// accumulated signed delta.
@(private)
ivs_lookup_delta :: proc(d: []u8, ivs_off: u32, outer, inner: u16, axis_values: []f32) -> i32 {
	if u64(ivs_off) + 8 > u64(len(d)) { return 0 }
	format       := u16(d[ivs_off])<<8 | u16(d[ivs_off + 1])
	if format != 1 { return 0 }                              // only format 1 defined
	regions_off  := u32(d[ivs_off + 2])<<24 | u32(d[ivs_off + 3])<<16 | u32(d[ivs_off + 4])<<8 | u32(d[ivs_off + 5])
	ivd_count    := u16(d[ivs_off + 6])<<8 | u16(d[ivs_off + 7])
	if outer >= ivd_count { return 0 }

	// ItemVariationData offsets are u32, after the count.
	ivd_off_pos := ivs_off + 8 + u32(outer) * 4
	if u64(ivd_off_pos) + 4 > u64(len(d)) { return 0 }
	ivd_rel_off := u32(d[ivd_off_pos])<<24 | u32(d[ivd_off_pos + 1])<<16 |
	               u32(d[ivd_off_pos + 2])<<8  | u32(d[ivd_off_pos + 3])
	ivd_off := ivs_off + ivd_rel_off

	// ItemVariationData header: itemCount u16, shortDeltaCount u16,
	// regionIndexCount u16.
	if u64(ivd_off) + 6 > u64(len(d)) { return 0 }
	item_count          := u16(d[ivd_off])<<8     | u16(d[ivd_off + 1])
	short_delta_count   := u16(d[ivd_off + 2])<<8 | u16(d[ivd_off + 3])
	region_index_count  := u16(d[ivd_off + 4])<<8 | u16(d[ivd_off + 5])
	if inner >= item_count { return 0 }

	region_indices_off := ivd_off + 6
	if u64(region_indices_off) + u64(region_index_count) * 2 > u64(len(d)) { return 0 }

	// Delta sets follow the region-index array. Each delta-set is
	// (short_delta_count i16 entries) + (region_index_count -
	// short_delta_count i8 entries).
	per_row_size := u32(short_delta_count) * 2 + u32(region_index_count - short_delta_count)
	delta_sets_off := region_indices_off + u32(region_index_count) * 2
	row_off := delta_sets_off + u32(inner) * per_row_size
	if u64(row_off) + u64(per_row_size) > u64(len(d)) { return 0 }

	// Compute the per-region scalar weights. The IVS's
	// `variationRegionListOffset` is *IVS-relative*, so we anchor it
	// back to the absolute HVAR offset.
	regions_abs := ivs_off + regions_off
	if u64(regions_abs) + 4 > u64(len(d)) { return 0 }
	axis_count := u16(d[regions_abs])<<8 | u16(d[regions_abs + 1])
	if int(axis_count) != len(axis_values) { return 0 }
	region_count := u16(d[regions_abs + 2])<<8 | u16(d[regions_abs + 3])

	region_size := u32(axis_count) * 6                       // 3 F2DOT14 per axis
	regions_data_off := regions_abs + 4

	total: i32 = 0
	for ri_idx in 0..<int(region_index_count) {
		rip := region_indices_off + u32(ri_idx) * 2
		region_idx := u16(d[rip])<<8 | u16(d[rip + 1])
		if region_idx >= region_count { continue }

		weight: f32 = 1.0
		region_base := regions_data_off + u32(region_idx) * region_size
		for k in 0..<int(axis_count) {
			ap := region_base + u32(k) * 6
			if u64(ap) + 6 > u64(len(d)) { weight = 0; break }
			start_raw := i16(u16(d[ap])<<8     | u16(d[ap + 1]))
			peak_raw  := i16(u16(d[ap + 2])<<8 | u16(d[ap + 3]))
			end_raw   := i16(u16(d[ap + 4])<<8 | u16(d[ap + 5]))
			start := f32(start_raw) / 16384.0
			peak  := f32(peak_raw)  / 16384.0
			end   := f32(end_raw)   / 16384.0
			v := axis_values[k]

			if peak == 0 || (start <= 0 && end >= 0 && peak != 0 && (start != 0 || end != 0)) {
				// Per spec: if peak == 0, this axis contributes 1
				// (region applies fully along this axis dimension).
				if peak == 0 { continue }
			}

			if v == peak { continue }
			if v <= start || v >= end { weight = 0; break }
			if v < peak {
				if peak == start { weight = 0; break }
				weight *= (v - start) / (peak - start)
			} else {
				if end == peak { weight = 0; break }
				weight *= (end - v) / (end - peak)
			}
		}
		if weight == 0 { continue }

		// Read the delta for this region.
		delta: i32
		if ri_idx < int(short_delta_count) {
			dp := row_off + u32(ri_idx) * 2
			delta = i32(i16(u16(d[dp])<<8 | u16(d[dp + 1])))
		} else {
			dp := row_off + u32(short_delta_count) * 2 + u32(ri_idx - int(short_delta_count))
			delta = i32(i8(d[dp]))
		}
		total += i32(f32(delta) * weight)
	}
	return total
}
