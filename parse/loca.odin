package parse

// loca — Index to Location.
//
// One entry per glyph plus a sentinel: entry[N+1] - entry[N] gives the
// byte length of glyph N inside the `glyf` table. The on-disk encoding
// depends on `head.index_to_loc_format`:
//
//   Short format (0): u16 offsets, each scaled by 2 on disk.
//   Long  format (1): u32 offsets, byte-accurate.
//
// Both are materialised into a single `[]u32` of byte offsets so the
// rest of the library deals with one type.
//
// References: OpenType spec, "loca — Index to Location".

Loca :: struct {
	// One offset per glyph + 1 trailing sentinel, total `num_glyphs + 1`.
	offsets: []u32,
}

// parse_loca decodes the `loca` table into a u32 byte-offset array. The
// `format` and `num_glyphs` values come from `head` and `maxp`
// respectively — the parser refuses to guess.
parse_loca :: proc(data: []u8, format: Index_To_Loc_Format, num_glyphs: u16, allocator := context.allocator) -> (l: Loca, err: Error) {
	count := int(num_glyphs) + 1
	offsets := make([]u32, count, allocator)
	if offsets == nil { err = .Out_Of_Memory; return }

	switch format {
	case .Short:
		min_len := count * 2
		if len(data) < min_len {
			delete(offsets, allocator)
			err = .Invalid_Table
			return
		}
		for i in 0..<count {
			p := i * 2
			v := u32(data[p])<<8 | u32(data[p + 1])
			// Short format: spec says multiply by 2 to recover byte offset.
			offsets[i] = v * 2
		}
	case .Long:
		min_len := count * 4
		if len(data) < min_len {
			delete(offsets, allocator)
			err = .Invalid_Table
			return
		}
		for i in 0..<count {
			p := i * 4
			offsets[i] = u32(data[p])<<24 | u32(data[p + 1])<<16 |
			             u32(data[p + 2])<<8  | u32(data[p + 3])
		}
	}

	l = Loca{offsets = offsets}
	return
}

// loca_destroy releases the allocation made by `parse_loca`.
loca_destroy :: proc(l: ^Loca, allocator := context.allocator) {
	delete(l.offsets, allocator)
	l.offsets = nil
}

// loca_glyph_range returns the (start, length) byte range for glyph
// `gid` inside the `glyf` table. A zero-length range means an empty
// glyph (e.g. space).
loca_glyph_range :: proc(l: ^Loca, gid: Glyph_ID) -> (start: u32, length: u32, ok: bool) {
	if int(gid) + 1 >= len(l.offsets) {
		return 0, 0, false
	}
	start = l.offsets[gid]
	end   := l.offsets[gid + 1]
	if end < start { return 0, 0, false }
	return start, end - start, true
}
