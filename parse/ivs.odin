package parse

// ivs.odin — Item Variation Store helpers shared between HVAR, MVAR,
// and CFF2.
//
// The Item Variation Store ("IVS") is the OpenType regression engine
// for variable fonts: each "variation region" defines a triangular
// influence over normalised axis-coordinate space, and per-region
// deltas blend into a single scalar adjustment for any given
// interior point. HVAR uses one IVS to interpolate advance widths,
// MVAR to interpolate global metrics, CFF2 to interpolate
// charstring operands (point coordinates, hints, etc.).
//
// This module exposes the per-region scalar weight evaluator —
// callers translate (vsindex, output index) into a delta-set,
// then sum deltas weighted by the scalars these helpers produce.
//
// Reference: OpenType spec, "Item Variation Store" / "Variation
// Region List" / "Variation Region".

// ivs_region_axis_count reads the axisCount u16 from the
// VariationRegionList header. Returns 0 on out-of-bounds.
ivs_region_axis_count :: proc(data: []u8, regions_abs: u32) -> int {
	if u64(regions_abs) + 4 > u64(len(data)) { return 0 }
	return int(u16(data[regions_abs])<<8 | u16(data[regions_abs + 1]))
}

// ivs_region_count reads the regionCount u16 from the
// VariationRegionList header.
ivs_region_count :: proc(data: []u8, regions_abs: u32) -> int {
	if u64(regions_abs) + 4 > u64(len(data)) { return 0 }
	return int(u16(data[regions_abs + 2])<<8 | u16(data[regions_abs + 3]))
}

// ivs_region_scalar computes the scalar weight for `region_idx`
// at the normalised axis tuple `axis_values`. Region geometry is
// read directly from the VariationRegionList that begins at
// `regions_abs` (an absolute offset into `data`). Returns 0 if
// the axis tuple falls outside the region's triangular influence,
// otherwise a value in (0, 1].
ivs_region_scalar :: proc(data: []u8, regions_abs: u32, region_idx: u16, axis_values: []f32) -> f32 {
	axis_count   := ivs_region_axis_count(data, regions_abs)
	region_count := ivs_region_count(data, regions_abs)
	if axis_count == 0 || region_count == 0 { return 0 }
	if int(region_idx) >= region_count { return 0 }
	if axis_count != len(axis_values) { return 0 }

	region_size := u32(axis_count) * 6
	regions_data_off := regions_abs + 4
	region_base := regions_data_off + u32(region_idx) * region_size

	weight: f32 = 1.0
	for k in 0..<axis_count {
		ap := region_base + u32(k) * 6
		if u64(ap) + 6 > u64(len(data)) { return 0 }
		start_raw := i16(u16(data[ap])<<8     | u16(data[ap + 1]))
		peak_raw  := i16(u16(data[ap + 2])<<8 | u16(data[ap + 3]))
		end_raw   := i16(u16(data[ap + 4])<<8 | u16(data[ap + 5]))
		start := f32(start_raw) / 16384.0
		peak  := f32(peak_raw)  / 16384.0
		end   := f32(end_raw)   / 16384.0
		v := axis_values[k]

		// Spec: a peak of 0 means this axis contributes 1 to the
		// product (the region applies fully along this dimension).
		if peak == 0 { continue }
		if v == peak { continue }
		if v <= start || v >= end { return 0 }
		if v < peak {
			if peak == start { return 0 }
			weight *= (v - start) / (peak - start)
		} else {
			if end == peak { return 0 }
			weight *= (end - v) / (end - peak)
		}
	}
	return weight
}
