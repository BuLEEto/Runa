package parse

// MVAR — Metrics Variations Table.
//
// Font-wide metrics (ascender, descender, line gap, x-height, cap
// height, underline / strikeout offset & size) can vary across the
// font's design space. MVAR holds per-metric delta sets indexed by
// the same Item Variation Store machinery HVAR uses.
//
// At v0.5 we expose the deltas via tag lookup; callers ask for a
// specific metric (`mvar_lookup_delta(g, parse.tag("hasc"), …)`) and
// add the returned signed delta to the base value pulled from
// `hhea` / `OS/2` / etc.
//
// Inter, for example, ships MVAR records for `xhgt`, `unds`, `undo`,
// `strs`, `stro` — it intentionally keeps ascent/descent constant
// across weights so paragraphs don't relayout when bold switches on.
// Other fonts (e.g. Roboto Flex) carry full ascent/descent variation.
//
// References: OpenType spec, "MVAR — Metrics Variations Table".

MVAR_VERSION_1_0 :: u32(0x00010000)

Mvar :: struct {
	data:                   []u8,
	value_record_size:      u16,
	value_record_count:     u16,
	value_records_off:      u32,                 // absolute offset into MVAR data
	ivs_off:                u32,
}

parse_mvar :: proc(data: []u8) -> (m: Mvar, err: Error) {
	r := Reader{data = data}
	version := read_u32(&r) or_return
	if version != MVAR_VERSION_1_0 { err = .Unsupported_Format; return }

	skip(&r, 2) or_return                        // reserved
	m.value_record_size  = read_u16(&r) or_return
	m.value_record_count = read_u16(&r) or_return
	ivs_rel              := read_u16(&r) or_return
	m.ivs_off            = u32(ivs_rel)
	m.value_records_off  = u32(r.pos)
	m.data               = data
	return
}

// mvar_lookup_delta returns the signed delta (in font units) for the
// metric identified by `metric_tag` at the normalised axis tuple
// `axis_values`. Returns 0 if the font has no record for that tag
// (in which case the caller's base value is correct as-is).
//
// Common metric tags: `hasc` (horizontal ascender), `hdsc` (descender),
// `hlgp` (line gap), `xhgt` (x-height), `cpht` (cap height),
// `unds` / `undo` (underline size / offset),
// `strs` / `stro` (strikeout size / offset).
mvar_lookup_delta :: proc(m: ^Mvar, metric_tag: Tag, axis_values: []f32) -> i32 {
	rec_size := u32(m.value_record_size)
	for i in 0..<u32(m.value_record_count) {
		off := m.value_records_off + i * rec_size
		if u64(off) + 8 > u64(len(m.data)) { return 0 }
		tag := Tag(u32(m.data[off])<<24 | u32(m.data[off + 1])<<16 |
		           u32(m.data[off + 2])<<8  | u32(m.data[off + 3]))
		if tag != metric_tag { continue }
		outer := u16(m.data[off + 4])<<8 | u16(m.data[off + 5])
		inner := u16(m.data[off + 6])<<8 | u16(m.data[off + 7])
		return ivs_lookup_delta(m.data, m.ivs_off, outer, inner, axis_values)
	}
	return 0
}
