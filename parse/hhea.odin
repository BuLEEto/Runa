package parse

// hhea — Horizontal Header.
//
// Carries the font-wide horizontal metrics that the layout engine consumes
// to size lines: ascender, descender, line gap, plus the count of "long"
// horizontal metric records that `hmtx` carries (the rest of the glyphs
// share the last advance).
//
// Values are in font units; divide by `head.units_per_em` and multiply by
// pixel size to convert.
//
// References: OpenType spec, "hhea — Horizontal Header Table".

Hhea_Table :: struct {
	ascender:               i16,
	descender:              i16,
	line_gap:               i16,
	advance_width_max:      u16,
	min_left_side_bearing:  i16,
	min_right_side_bearing: i16,
	x_max_extent:           i16,
	caret_slope_rise:       i16,
	caret_slope_run:        i16,
	caret_offset:           i16,
	number_of_h_metrics:    u16,
}

// parse_hhea decodes the `hhea` table. Rejects non-zero `metricDataFormat`
// (the only defined value is 0 — anything else is a future spec change
// the parser hasn't been built for).
parse_hhea :: proc(data: []u8) -> (h: Hhea_Table, err: Error) {
	r := Reader{data = data}

	skip(&r, 4) or_return                    // major + minor version

	h.ascender               = read_i16(&r) or_return
	h.descender              = read_i16(&r) or_return
	h.line_gap               = read_i16(&r) or_return
	h.advance_width_max      = read_u16(&r) or_return
	h.min_left_side_bearing  = read_i16(&r) or_return
	h.min_right_side_bearing = read_i16(&r) or_return
	h.x_max_extent           = read_i16(&r) or_return
	h.caret_slope_rise       = read_i16(&r) or_return
	h.caret_slope_run        = read_i16(&r) or_return
	h.caret_offset           = read_i16(&r) or_return

	skip(&r, 8) or_return                    // 4 reserved i16, must be 0

	metric_data_format := read_i16(&r) or_return
	if metric_data_format != 0 { err = .Unsupported_Format; return }

	h.number_of_h_metrics = read_u16(&r) or_return
	return
}
