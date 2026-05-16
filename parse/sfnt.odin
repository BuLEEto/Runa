package parse

// SFNT directory parsing — the entry point into an OpenType / TrueType
// font file. Every font starts with a 12-byte offset table followed by
// `numTables` 16-byte table records.
//
// References: OpenType spec, "Organization of an OpenType Font".

// SFNT magic values for the version field. The version tells the reader
// whether glyph data lives in `glyf` (TrueType outlines) or `CFF` /
// `CFF2` (PostScript outlines).
SFNT_VERSION_TT      :: u32(0x00010000)            // 'true' TrueType outlines
SFNT_VERSION_CFF     :: u32(0x4F54544F)            // 'OTTO' — CFF outlines
SFNT_VERSION_TRUE    :: u32(0x74727565)            // 'true' — Apple legacy TT
SFNT_VERSION_TYP1    :: u32(0x74797031)            // 'typ1' — Apple legacy

// TTC (TrueType Collection) header magic — multi-font containers. v0.1
// loads only single-font files; collections come later if needed.
TTC_TAG              :: u32(0x74746366)            // 'ttcf'

// Table_Record points at one table inside the font buffer. Offsets are
// absolute from the start of the file; checksums are not validated by
// the parser (the OpenType spec marks them informational, and chasing
// every CVE-worthy checksum bug isn't worth the complexity at v0.1).
Table_Record :: struct {
	tag:    Tag,
	offset: u32,
	length: u32,
}

// Table_Index is the parsed SFNT directory. Records are sorted by tag
// (the on-disk form is too, so we keep that invariant for binary search
// later if profiling demands it). Linear scan is fine for the ~20–40
// tables in a real font.
Table_Index :: struct {
	sfnt_version: u32,
	records:      []Table_Record,
}

// parse_table_index reads the SFNT offset table at the start of `data`
// and returns one Table_Record per declared table. Allocates `records`
// from `allocator`; the caller frees with `delete(idx.records, allocator)`.
//
// Rejects TTC (TrueType Collection) inputs with `Unsupported_Format` —
// font collections need an explicit index choice that the loader hasn't
// been built for yet.
parse_table_index :: proc(data: []u8, allocator := context.allocator) -> (idx: Table_Index, err: Error) {
	r := Reader{data = data}

	version := read_u32(&r) or_return

	if version == TTC_TAG {
		err = .Unsupported_Format
		return
	}

	switch version {
	case SFNT_VERSION_TT, SFNT_VERSION_CFF, SFNT_VERSION_TRUE, SFNT_VERSION_TYP1:
		// fine
	case:
		err = .Invalid_Table
		return
	}

	num_tables := read_u16(&r) or_return
	// searchRange, entrySelector, rangeShift — derived from numTables and
	// historically used for binary search. We ignore them; modern parsers
	// don't trust them and recompute when needed.
	skip(&r, 6) or_return

	records := make([]Table_Record, num_tables, allocator)
	if records == nil && num_tables > 0 {
		err = .Out_Of_Memory
		return
	}

	for i in 0..<int(num_tables) {
		tag    := read_tag(&r) or_return
		_       = read_u32(&r) or_return        // checksum — ignored
		offset := read_u32(&r) or_return
		length := read_u32(&r) or_return

		// Each table must lie entirely inside the file. The spec doesn't
		// require this for unused tables, but a malicious offset/length
		// could later flow into a slice index and panic.
		if u64(offset) + u64(length) > u64(len(data)) {
			delete(records, allocator)
			err = .Invalid_Table
			return
		}

		records[i] = Table_Record{tag = tag, offset = offset, length = length}
	}

	idx = Table_Index{sfnt_version = version, records = records}
	return
}

// table_index_destroy frees the records slice allocated by
// `parse_table_index`. `allocator` must match the one passed at parse.
table_index_destroy :: proc(idx: ^Table_Index, allocator := context.allocator) {
	delete(idx.records, allocator)
	idx.records = nil
}

// find_table returns the byte range of the named table, or `Table_Not_Found`
// if the SFNT directory doesn't carry it. The returned slice aliases
// `data` — do not modify it.
find_table :: proc(idx: ^Table_Index, data: []u8, t: Tag) -> (b: []u8, err: Error) {
	for &rec in idx.records {
		if rec.tag == t {
			b = data[rec.offset:rec.offset + rec.length]
			return
		}
	}
	err = .Table_Not_Found
	return
}

// has_table reports whether the named table exists in the SFNT directory.
// Used by optional-feature probes — `head` is required, `COLR` isn't.
has_table :: proc(idx: ^Table_Index, t: Tag) -> bool {
	for &rec in idx.records {
		if rec.tag == t { return true }
	}
	return false
}

// is_truetype reports whether the SFNT carries TrueType outlines in
// `glyf` (vs. CFF / CFF2 PostScript outlines). The parser's outline
// pipeline picks the right code path based on this.
is_truetype :: proc(idx: ^Table_Index) -> bool {
	return idx.sfnt_version == SFNT_VERSION_TT ||
	       idx.sfnt_version == SFNT_VERSION_TRUE ||
	       idx.sfnt_version == SFNT_VERSION_TYP1
}

// is_cff reports whether the SFNT carries CFF / CFF2 PostScript outlines.
is_cff :: proc(idx: ^Table_Index) -> bool {
	return idx.sfnt_version == SFNT_VERSION_CFF
}
