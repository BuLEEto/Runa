package parse

// hmtx — Horizontal Metrics Table.
//
// The on-disk format is two sections back-to-back:
//
//   long_metrics[number_of_h_metrics]:
//     advance_width: u16
//     left_side_bearing: i16
//
//   trailing_lsbs[num_glyphs - number_of_h_metrics]: i16
//
// Glyphs whose ID lands in `trailing_lsbs` share the advance width of
// the last long_metrics entry — a common compression for monospace or
// CJK fonts where many glyphs have identical advances.
//
// The parser holds the table as raw bytes plus the counts it needs to
// pick the right section. Lookups read the two i16/u16 values directly
// from the byte slice — no per-glyph allocation.
//
// References: OpenType spec, "hmtx — Horizontal Metrics Table".

Hmtx_Table :: struct {
	data:                []u8,
	number_of_h_metrics: u16,
	num_glyphs:          u16,
}

// new_hmtx wraps a slice of the on-disk hmtx table with the counts it
// needs to do per-glyph lookups. Cheap — no allocation, no copy. The
// caller's `data` must outlive the Hmtx_Table.
new_hmtx :: proc(data: []u8, number_of_h_metrics: u16, num_glyphs: u16) -> (h: Hmtx_Table, err: Error) {
	if number_of_h_metrics == 0 { err = .Invalid_Table; return }
	if number_of_h_metrics > num_glyphs { err = .Invalid_Table; return }

	// Minimum required length:
	//   4*number_of_h_metrics + 2*(num_glyphs - number_of_h_metrics)
	min_len := int(number_of_h_metrics)*4 + (int(num_glyphs) - int(number_of_h_metrics))*2
	if len(data) < min_len { err = .Invalid_Table; return }

	h = Hmtx_Table{
		data                = data,
		number_of_h_metrics = number_of_h_metrics,
		num_glyphs          = num_glyphs,
	}
	return
}

// H_Metric is the per-glyph horizontal layout pair: advance width and
// left side bearing. Both are in font units.
H_Metric :: struct {
	advance_width:    u16,
	left_side_bearing: i16,
}

// hmtx_glyph_metric returns the horizontal metric for `gid`. Glyphs
// beyond `number_of_h_metrics` share the last `advance_width`; their
// per-glyph LSB still lives in the trailing array.
//
// Out-of-range glyph IDs return zero metrics rather than an error —
// the call site is usually a hot path that doesn't want to branch on
// errors. Use `gid < hmtx.num_glyphs` to guard explicitly if needed.
hmtx_glyph_metric :: proc(hmtx: ^Hmtx_Table, gid: Glyph_ID) -> H_Metric {
	if u16(gid) >= hmtx.num_glyphs { return {} }
	if u16(gid) < hmtx.number_of_h_metrics {
		off := int(gid) * 4
		aw  := u16(hmtx.data[off])<<8     | u16(hmtx.data[off + 1])
		lsb := i16(u16(hmtx.data[off + 2])<<8 | u16(hmtx.data[off + 3]))
		return H_Metric{advance_width = aw, left_side_bearing = lsb}
	}
	// In the trailing LSB array.
	last := int(hmtx.number_of_h_metrics) - 1
	last_off := last * 4
	aw := u16(hmtx.data[last_off])<<8 | u16(hmtx.data[last_off + 1])

	trail_idx := int(gid) - int(hmtx.number_of_h_metrics)
	lsb_off := int(hmtx.number_of_h_metrics)*4 + trail_idx*2
	lsb := i16(u16(hmtx.data[lsb_off])<<8 | u16(hmtx.data[lsb_off + 1]))
	return H_Metric{advance_width = aw, left_side_bearing = lsb}
}
