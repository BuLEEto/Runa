package parse

// cmap — Character to Glyph Index Mapping Table.
//
// Modern fonts ship one or more cmap subtables under a directory of
// `(platform_id, encoding_id)` records. The parser picks the
// Unicode-capable subtable with the widest coverage:
//
//   1. format 12 (full Unicode) — Microsoft platform 3 / encoding 10
//                                  or Unicode platform 0 / encoding 4 / 6
//   2. format 4  (BMP only)     — Microsoft platform 3 / encoding 1
//                                  or Unicode platform 0 / encoding 3
//
// Other formats (0, 2, 6, 8, 10, 13, 14) are tolerated but not
// preferred at v0.1. A font with no recognised subtable returns
// `Unsupported_Format`.
//
// References: OpenType spec, "cmap — Character to Glyph Index Mapping
// Table"; Apple TrueType Reference Manual, "cmap" for the historical
// format details.

// Cmap is the parsed result for *one* selected subtable. The variant
// stored in `format` tells lookups which arrays to consult.
//
// All slices are allocated from the allocator passed to `parse_cmap`
// and freed by `cmap_destroy`.
Cmap :: struct {
	format:     Cmap_Format,
	// Format 4 (BMP):
	seg_end:    []u16,
	seg_start:  []u16,
	seg_delta:  []i16,
	seg_offset: []u16,
	// `glyph_id_array` holds the residual u16 array that idRangeOffset
	// indexes into. Stored as a single contiguous slice rather than
	// scattered per-segment pointers so the lookup can compute a flat
	// index. `offset_base` records the on-disk position of the first
	// `idRangeOffset` entry so the offsetting math works out.
	glyph_id_array: []u16,
	// Format 12 (full Unicode):
	groups: []Cmap_Group,
}

Cmap_Format :: enum u8 {
	Unknown,
	Format_4,
	Format_12,
}

Cmap_Group :: struct {
	start_char: u32,
	end_char:   u32,
	start_glyph: u32,
}

// Platform / encoding pair codes. Listed in our selection priority
// order so the scan can early-out on the best match.
@(private)
Cmap_Encoding :: struct {
	platform: u16,
	encoding: u16,
}

@(private)
PREFERRED_FORMAT_12_ENCODINGS := [?]Cmap_Encoding{
	{3, 10},   // Microsoft / Unicode UCS-4
	{0, 6},    // Unicode / Unicode full repertoire
	{0, 4},    // Unicode / Unicode 2.0+ full
}

@(private)
PREFERRED_FORMAT_4_ENCODINGS := [?]Cmap_Encoding{
	{3, 1},    // Microsoft / Unicode BMP
	{0, 3},    // Unicode / Unicode 2.0+ BMP
	{0, 2},    // Unicode / Unicode 1.1
	{0, 1},    // Unicode / Unicode 1.0
	{0, 0},    // Unicode / default
}

// parse_cmap parses the `cmap` table out of its raw byte slice. Allocates
// from `allocator`; caller frees with `cmap_destroy`.
//
// The procedure walks the encoding directory twice: first preferring a
// full-Unicode (format 12) subtable, then falling back to a BMP-only
// (format 4) subtable. Fonts in the wild often ship both for
// compatibility — picking format 12 unlocks emoji codepoints above
// U+FFFF.
parse_cmap :: proc(data: []u8, allocator := context.allocator) -> (c: Cmap, err: Error) {
	r := Reader{data = data}

	version := read_u16(&r) or_return
	if version != 0 { err = .Invalid_Table; return }

	num_tables := read_u16(&r) or_return

	// Track candidate subtable offsets while we scan the encoding
	// directory. We pick the best after the scan rather than mid-walk
	// so a later, higher-priority candidate can override an earlier
	// match.
	chosen_offset: u32
	chosen_priority: int = -1   // higher == better

	for i in 0..<int(num_tables) {
		platform_id := read_u16(&r) or_return
		encoding_id := read_u16(&r) or_return
		offset      := read_u32(&r) or_return

		prio := cmap_priority(platform_id, encoding_id)
		if prio > chosen_priority {
			chosen_priority = prio
			chosen_offset = offset
		}
	}

	if chosen_priority < 0 {
		err = .Unsupported_Format
		return
	}

	if u64(chosen_offset) + 2 > u64(len(data)) { err = .Invalid_Table; return }
	sub_format := u16(data[chosen_offset])<<8 | u16(data[chosen_offset + 1])

	switch sub_format {
	case 4:
		c, err = parse_cmap_format_4(data[chosen_offset:], allocator)
	case 12:
		c, err = parse_cmap_format_12(data[chosen_offset:], allocator)
	case:
		err = .Unsupported_Format
	}
	return
}

// cmap_priority ranks an encoding by how much Unicode coverage we expect
// from its subtable. Returns -1 for encodings we don't accept at v0.1.
@(private)
cmap_priority :: proc(platform_id, encoding_id: u16) -> int {
	for enc, i in PREFERRED_FORMAT_12_ENCODINGS {
		if enc.platform == platform_id && enc.encoding == encoding_id {
			// Format 12 candidates score higher than every format 4.
			return 100 - i
		}
	}
	for enc, i in PREFERRED_FORMAT_4_ENCODINGS {
		if enc.platform == platform_id && enc.encoding == encoding_id {
			return 50 - i
		}
	}
	return -1
}

// cmap_destroy releases the allocations made by `parse_cmap`. The
// allocator must match the one passed at parse.
cmap_destroy :: proc(c: ^Cmap, allocator := context.allocator) {
	delete(c.seg_end,        allocator)
	delete(c.seg_start,      allocator)
	delete(c.seg_delta,      allocator)
	delete(c.seg_offset,     allocator)
	delete(c.glyph_id_array, allocator)
	delete(c.groups,         allocator)
	c^ = {}
}

// cmap_lookup returns the glyph ID for a Unicode codepoint, or 0 (the
// .notdef glyph) if the codepoint isn't covered by the selected
// subtable. By spec, glyph 0 is always present and is the
// missing-glyph indicator.
cmap_lookup :: proc(c: ^Cmap, codepoint: rune) -> Glyph_ID {
	switch c.format {
	case .Format_4:
		return cmap_lookup_format_4(c, codepoint)
	case .Format_12:
		return cmap_lookup_format_12(c, codepoint)
	case .Unknown:
		return 0
	}
	return 0
}

// ---- Format 4 -------------------------------------------------------

@(private)
parse_cmap_format_4 :: proc(data: []u8, allocator := context.allocator) -> (c: Cmap, err: Error) {
	r := Reader{data = data}

	skip(&r, 2) or_return                    // format (already known = 4)
	length := read_u16(&r) or_return
	if int(length) > len(data) { err = .Invalid_Table; return }
	skip(&r, 2) or_return                    // language

	seg_count_x2 := read_u16(&r) or_return
	if seg_count_x2 % 2 != 0 { err = .Invalid_Table; return }
	seg_count := int(seg_count_x2 / 2)
	if seg_count == 0 { err = .Invalid_Table; return }

	skip(&r, 6) or_return                    // searchRange, entrySelector, rangeShift

	// Allocate the four parallel segment arrays + the residual
	// glyph_id_array. On failure of any allocation, free what we have.
	seg_end    := make([]u16, seg_count, allocator)
	seg_start  := make([]u16, seg_count, allocator)
	seg_delta  := make([]i16, seg_count, allocator)
	seg_offset := make([]u16, seg_count, allocator)
	if seg_end == nil || seg_start == nil || seg_delta == nil || seg_offset == nil {
		delete(seg_end, allocator); delete(seg_start, allocator)
		delete(seg_delta, allocator); delete(seg_offset, allocator)
		err = .Out_Of_Memory
		return
	}

	for i in 0..<seg_count {
		seg_end[i] = read_u16(&r) or_return
	}
	// Per spec, the final endCode segment is 0xFFFF.
	if seg_end[seg_count - 1] != 0xFFFF {
		delete(seg_end, allocator); delete(seg_start, allocator)
		delete(seg_delta, allocator); delete(seg_offset, allocator)
		err = .Invalid_Table
		return
	}
	skip(&r, 2) or_return                    // reservedPad

	for i in 0..<seg_count {
		seg_start[i] = read_u16(&r) or_return
	}
	for i in 0..<seg_count {
		seg_delta[i] = read_i16(&r) or_return
	}

	// idRangeOffset is special: each entry, if non-zero, is a byte offset
	// from *its own position* into glyphIdArray. Capture the on-disk
	// position of seg_offset[0] so the lookup can reproduce the offset
	// arithmetic by indexing into glyph_id_array.
	id_range_offset_pos := r.pos

	for i in 0..<seg_count {
		seg_offset[i] = read_u16(&r) or_return
	}

	// glyphIdArray runs from r.pos to (id_range_offset_pos + length) or
	// to end-of-table.
	gia_bytes := int(length) - r.pos
	if gia_bytes < 0 { gia_bytes = 0 }
	gia_count := gia_bytes / 2

	glyph_id_array := make([]u16, gia_count, allocator)
	if glyph_id_array == nil && gia_count > 0 {
		delete(seg_end, allocator); delete(seg_start, allocator)
		delete(seg_delta, allocator); delete(seg_offset, allocator)
		err = .Out_Of_Memory
		return
	}
	for i in 0..<gia_count {
		glyph_id_array[i] = read_u16(&r) or_return
	}

	// Re-write the seg_offset entries so they encode an index into
	// glyph_id_array rather than a byte offset on disk. Sentinel 0
	// stays 0 (means "use idDelta path"). This is the cosmic-text /
	// ttf-parser canonicalisation — collapses lookup to one
	// table-aware branch instead of one disk-aware branch per call.
	for i in 0..<seg_count {
		if seg_offset[i] == 0 { continue }
		// Byte position the spec wants to read from:
		//   base = id_range_offset_pos + 2*i + seg_offset[i]
		byte_pos := id_range_offset_pos + 2*i + int(seg_offset[i])
		gia_byte_pos := byte_pos - (id_range_offset_pos + seg_count * 2)
		if gia_byte_pos < 0 || gia_byte_pos % 2 != 0 {
			delete(seg_end, allocator); delete(seg_start, allocator)
			delete(seg_delta, allocator); delete(seg_offset, allocator)
			delete(glyph_id_array, allocator)
			err = .Invalid_Table
			return
		}
		// Store (gia_index + 1) so 0 stays the "no override" sentinel.
		seg_offset[i] = u16(gia_byte_pos / 2 + 1)
	}

	c = Cmap{
		format         = .Format_4,
		seg_end        = seg_end,
		seg_start      = seg_start,
		seg_delta      = seg_delta,
		seg_offset     = seg_offset,
		glyph_id_array = glyph_id_array,
	}
	return
}

@(private)
cmap_lookup_format_4 :: proc(c: ^Cmap, codepoint: rune) -> Glyph_ID {
	if codepoint < 0 || codepoint > 0xFFFF { return 0 }
	cp := u16(codepoint)

	// Linear scan first — modern format-4 cmaps run 100..400 segments,
	// which is still fast enough that binary search isn't strictly
	// required. Profiling can swap this for a bsearch later.
	for i in 0..<len(c.seg_end) {
		if c.seg_end[i] >= cp {
			if c.seg_start[i] > cp { return 0 }
			off := c.seg_offset[i]
			if off == 0 {
				return Glyph_ID(u16(i32(cp) + i32(c.seg_delta[i])))
			}
			// off is the canonicalised "index into glyph_id_array + 1"
			// (see parse_cmap_format_4). Recover the index, then add
			// (cp - seg_start) per spec.
			base := int(off - 1)
			idx  := base + int(cp - c.seg_start[i])
			if idx < 0 || idx >= len(c.glyph_id_array) { return 0 }
			g := c.glyph_id_array[idx]
			if g == 0 { return 0 }
			return Glyph_ID(u16(i32(g) + i32(c.seg_delta[i])))
		}
	}
	return 0
}

// ---- Format 12 ------------------------------------------------------

@(private)
parse_cmap_format_12 :: proc(data: []u8, allocator := context.allocator) -> (c: Cmap, err: Error) {
	r := Reader{data = data}

	skip(&r, 2) or_return                    // format (= 12)
	skip(&r, 2) or_return                    // reserved (= 0)
	length := read_u32(&r) or_return
	if u64(length) > u64(len(data)) { err = .Invalid_Table; return }
	skip(&r, 4) or_return                    // language

	num_groups := read_u32(&r) or_return
	groups := make([]Cmap_Group, num_groups, allocator)
	if groups == nil && num_groups > 0 { err = .Out_Of_Memory; return }

	prev_end: u32 = 0
	first := true
	for i in 0..<int(num_groups) {
		sc := read_u32(&r) or_return
		ec := read_u32(&r) or_return
		sg := read_u32(&r) or_return
		if ec < sc {
			delete(groups, allocator)
			err = .Invalid_Table
			return
		}
		// Groups must be sorted by startCharCode ascending and not overlap.
		// A malformed font violating this can break binary search; reject.
		if !first && sc <= prev_end {
			delete(groups, allocator)
			err = .Invalid_Table
			return
		}
		groups[i] = Cmap_Group{start_char = sc, end_char = ec, start_glyph = sg}
		prev_end = ec
		first = false
	}

	c = Cmap{format = .Format_12, groups = groups}
	return
}

@(private)
cmap_lookup_format_12 :: proc(c: ^Cmap, codepoint: rune) -> Glyph_ID {
	if codepoint < 0 { return 0 }
	cp := u32(codepoint)

	// Binary search by start_char. Groups are sorted + non-overlapping
	// per parser-time invariant.
	lo, hi := 0, len(c.groups)
	for lo < hi {
		mid := (lo + hi) / 2
		if c.groups[mid].end_char < cp {
			lo = mid + 1
		} else if c.groups[mid].start_char > cp {
			hi = mid
		} else {
			g := c.groups[mid]
			return Glyph_ID(g.start_glyph + (cp - g.start_char))
		}
	}
	return 0
}
