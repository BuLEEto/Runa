package parse

// CPAL — Color Palette Table.
//
// Holds one or more palettes of 32-bit colour values, looked up by
// `(palette_index, entry_index)`. COLR layers reference these by
// `entry_index`; the consumer chooses which palette is active.
//
// v0.1 supports CPAL version 0 only — v1 adds optional metadata
// (per-entry labels, palette types) but no new colour data.
//
// On-disk colours are stored BGRA (yes, in that order). The reader
// converts to RGBA when it returns colours.
//
// References: OpenType spec, "CPAL — Color Palette Table".

CPAL_VERSION_0 :: u16(0)
CPAL_VERSION_1 :: u16(1)

// One 8-bit-per-channel RGBA colour. Channel order is R, G, B, A
// post-conversion from the on-disk BGRA.
Cpal_Color :: struct {
	r, g, b, a: u8,
}

Cpal :: struct {
	data:                []u8,
	num_entries:         u16,   // entries per palette
	num_palettes:        u16,
	color_records_off:   u32,
	palette_indices_off: int,   // start of colorRecordIndices[]
}

new_cpal :: proc(data: []u8) -> (c: Cpal, err: Error) {
	r := Reader{data = data}
	version := read_u16(&r) or_return
	if version != CPAL_VERSION_0 && version != CPAL_VERSION_1 {
		err = .Unsupported_Format
		return
	}
	c.data            = data
	c.num_entries     = read_u16(&r) or_return
	c.num_palettes    = read_u16(&r) or_return
	_                 = read_u16(&r) or_return  // numColorRecords (u16 in v0, derived)
	c.color_records_off = read_u32(&r) or_return
	c.palette_indices_off = r.pos
	return
}

// cpal_lookup returns the colour at `(palette_idx, entry_idx)`. Returns
// zero (transparent black) if either index is out of range. The
// COLRv0 layer's `palette_index = 0xFFFF` sentinel is the caller's
// responsibility to handle — substitute the consumer's foreground
// colour and skip this lookup.
cpal_lookup :: proc(c: ^Cpal, palette_idx, entry_idx: u16) -> Cpal_Color {
	if palette_idx >= c.num_palettes { return {} }
	if entry_idx   >= c.num_entries  { return {} }

	// colorRecordIndices[palette_idx] -> u16 starting record index.
	pi_pos := c.palette_indices_off + int(palette_idx) * 2
	if pi_pos + 2 > len(c.data) { return {} }
	start_record := u16(c.data[pi_pos])<<8 | u16(c.data[pi_pos + 1])

	rec_off := c.color_records_off + u32(start_record + entry_idx) * 4
	if u64(rec_off) + 4 > u64(len(c.data)) { return {} }
	// On-disk order: B, G, R, A.
	return Cpal_Color{
		b = c.data[rec_off],
		g = c.data[rec_off + 1],
		r = c.data[rec_off + 2],
		a = c.data[rec_off + 3],
	}
}
