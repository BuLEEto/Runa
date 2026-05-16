package parse

// head — Font Header Table.
//
// Carries global font metrics that every other table refers back to:
// `units_per_em` is the scale factor (font units → em), `index_to_loc_format`
// tells the `loca` parser whether offsets are 16- or 32-bit, and the bounding
// box gives the union of all glyph extents.
//
// References: OpenType spec, "head — Font Header Table".

// HEAD_MAGIC is the table's self-identifying magic number (Apple legacy).
// A `head` table that disagrees is malformed.
HEAD_MAGIC :: u32(0x5F0F3CF5)

// Index_To_Loc_Format selects the on-disk size of each `loca` entry.
// Small fonts pack offsets into u16 (Short); larger ones use u32 (Long).
Index_To_Loc_Format :: enum i16 {
	Short = 0,
	Long  = 1,
}

// Head_Table holds the parsed fields of the `head` table. Date fields and
// flags that nothing else depends on are dropped — adding them is cheap if
// a future call site needs them.
Head_Table :: struct {
	units_per_em:         u16,
	index_to_loc_format:  Index_To_Loc_Format,
	x_min, y_min:         i16,
	x_max, y_max:         i16,
	mac_style:            u16,
	lowest_rec_ppem:      u16,
	flags:                u16,
}

// parse_head decodes the `head` table from its raw bytes. Rejects any
// table whose magic doesn't match (`Invalid_Table`), whose units-per-em
// is outside the spec-mandated 16..16384 range, or whose
// `indexToLocFormat` is neither 0 nor 1.
parse_head :: proc(data: []u8) -> (h: Head_Table, err: Error) {
	r := Reader{data = data}

	skip(&r, 4) or_return                    // majorVersion / minorVersion
	skip(&r, 4) or_return                    // fontRevision (Fixed)
	skip(&r, 4) or_return                    // checkSumAdjustment

	magic := read_u32(&r) or_return
	if magic != HEAD_MAGIC {
		err = .Invalid_Table
		return
	}

	h.flags        = read_u16(&r) or_return
	h.units_per_em = read_u16(&r) or_return
	if h.units_per_em < 16 || h.units_per_em > 16384 {
		err = .Invalid_Table
		return
	}

	skip(&r, 16) or_return                   // created, modified (8 bytes each)

	h.x_min = read_i16(&r) or_return
	h.y_min = read_i16(&r) or_return
	h.x_max = read_i16(&r) or_return
	h.y_max = read_i16(&r) or_return

	h.mac_style       = read_u16(&r) or_return
	h.lowest_rec_ppem = read_u16(&r) or_return

	skip(&r, 2) or_return                    // fontDirectionHint (deprecated)

	loc_fmt := read_i16(&r) or_return
	if loc_fmt != 0 && loc_fmt != 1 {
		err = .Invalid_Table
		return
	}
	h.index_to_loc_format = Index_To_Loc_Format(loc_fmt)

	glyph_data_format := read_i16(&r) or_return
	if glyph_data_format != 0 {
		err = .Unsupported_Format
		return
	}

	return
}
