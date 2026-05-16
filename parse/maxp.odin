package parse

// maxp — Maximum Profile.
//
// Tiny but load-bearing — `num_glyphs` is the global glyph-ID upper bound
// every other table is sized against. Version 0.5 is the CFF flavour
// (header + numGlyphs only); version 1.0 adds TrueType-specific maxima
// that v0.1 doesn't need.
//
// References: OpenType spec, "maxp — Maximum Profile".

MAXP_VERSION_0_5 :: u32(0x00005000)            // CFF-flavoured
MAXP_VERSION_1_0 :: u32(0x00010000)            // TrueType-flavoured

Maxp_Table :: struct {
	num_glyphs: u16,
}

// parse_maxp decodes the `maxp` table. Only `num_glyphs` is consumed at
// v0.1; the v1.0 TrueType maxima (`max_points`, `max_contours`,
// `max_storage`, ...) are tolerated but not parsed.
parse_maxp :: proc(data: []u8) -> (m: Maxp_Table, err: Error) {
	r := Reader{data = data}

	version := read_u32(&r) or_return
	if version != MAXP_VERSION_0_5 && version != MAXP_VERSION_1_0 {
		err = .Unsupported_Format
		return
	}

	m.num_glyphs = read_u16(&r) or_return
	return
}
