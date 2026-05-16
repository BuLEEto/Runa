package parse

// Reader is a bounds-checked cursor over a byte slice. Every read advances
// the cursor and surfaces overruns as `Error.Invalid_Table` — no panic,
// no slice-bounds trap on malformed input.
//
// The reader holds a pointer into the caller's buffer, never a copy.
// The buffer must outlive the reader.
Reader :: struct {
	data: []u8,
	pos:  int,
}

// reader_at returns a Reader scoped to data[offset:]. Returns
// `Error.Invalid_Table` if offset is out of range. Length checks happen
// at each read; this is the cheap version that only validates the
// starting point.
reader_at :: proc(data: []u8, offset: int) -> (r: Reader, err: Error) {
	if offset < 0 || offset > len(data) {
		err = .Invalid_Table
		return
	}
	r = Reader{data = data[offset:], pos = 0}
	return
}

// reader_slice returns a Reader scoped to data[offset:offset+length]. The
// returned reader's bounds are tighter than `reader_at`'s, so subsequent
// reads can never escape the declared table extent even if the table
// itself encodes bad offsets internally.
reader_slice :: proc(data: []u8, offset: int, length: int) -> (r: Reader, err: Error) {
	if offset < 0 || length < 0 || offset > len(data) || offset + length > len(data) {
		err = .Invalid_Table
		return
	}
	r = Reader{data = data[offset:offset + length], pos = 0}
	return
}

@(private)
read_check :: #force_inline proc(r: ^Reader, n: int) -> Error {
	if r.pos + n > len(r.data) {
		return .Invalid_Table
	}
	return .None
}

// read_u8 reads one byte and advances the cursor.
read_u8 :: proc(r: ^Reader) -> (v: u8, err: Error) {
	err = read_check(r, 1)
	if err != .None { return }
	v = r.data[r.pos]
	r.pos += 1
	return
}

// read_u16 reads a big-endian u16 and advances the cursor.
read_u16 :: proc(r: ^Reader) -> (v: u16, err: Error) {
	err = read_check(r, 2)
	if err != .None { return }
	v = u16(r.data[r.pos])<<8 | u16(r.data[r.pos + 1])
	r.pos += 2
	return
}

// read_i16 reads a big-endian i16 and advances the cursor.
read_i16 :: proc(r: ^Reader) -> (v: i16, err: Error) {
	u, e := read_u16(r)
	return i16(u), e
}

// read_u32 reads a big-endian u32 and advances the cursor.
read_u32 :: proc(r: ^Reader) -> (v: u32, err: Error) {
	err = read_check(r, 4)
	if err != .None { return }
	v = u32(r.data[r.pos])<<24 | u32(r.data[r.pos + 1])<<16 |
	    u32(r.data[r.pos + 2])<<8 | u32(r.data[r.pos + 3])
	r.pos += 4
	return
}

// read_i32 reads a big-endian i32 and advances the cursor.
read_i32 :: proc(r: ^Reader) -> (v: i32, err: Error) {
	u, e := read_u32(r)
	return i32(u), e
}

// read_u64 reads a big-endian u64 and advances the cursor.
read_u64 :: proc(r: ^Reader) -> (v: u64, err: Error) {
	err = read_check(r, 8)
	if err != .None { return }
	v = u64(r.data[r.pos])<<56 | u64(r.data[r.pos + 1])<<48 |
	    u64(r.data[r.pos + 2])<<40 | u64(r.data[r.pos + 3])<<32 |
	    u64(r.data[r.pos + 4])<<24 | u64(r.data[r.pos + 5])<<16 |
	    u64(r.data[r.pos + 6])<<8  | u64(r.data[r.pos + 7])
	r.pos += 8
	return
}

// read_tag reads a 4-byte OpenType tag. Bytes are kept in big-endian
// order so `Tag` values compare byte-for-byte equal to the on-disk form.
read_tag :: proc(r: ^Reader) -> (t: Tag, err: Error) {
	u, e := read_u32(r)
	return Tag(u), e
}

// read_bytes returns a slice of n bytes from the underlying buffer and
// advances the cursor. The returned slice aliases the buffer — do not
// modify it.
read_bytes :: proc(r: ^Reader, n: int) -> (b: []u8, err: Error) {
	err = read_check(r, n)
	if err != .None { return }
	b = r.data[r.pos:r.pos + n]
	r.pos += n
	return
}

// skip advances the cursor by n bytes.
skip :: proc(r: ^Reader, n: int) -> Error {
	if err := read_check(r, n); err != .None { return err }
	r.pos += n
	return .None
}

// remaining returns the number of bytes still available in the reader.
remaining :: proc(r: ^Reader) -> int {
	return len(r.data) - r.pos
}

// tag converts a 4-character ASCII string to a Tag. Used at compile time
// for table tag constants — e.g. `tag("head")`. Panics if the string is
// not exactly four bytes; this is intentional, because table tags are
// always literal in source code.
tag :: proc(s: string) -> Tag {
	assert(len(s) == 4, "OpenType tag must be exactly 4 bytes")
	return Tag(u32(s[0])<<24 | u32(s[1])<<16 | u32(s[2])<<8 | u32(s[3]))
}
