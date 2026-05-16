/*
UAX #29 extended grapheme cluster boundary detection.

A "grapheme cluster" is what users perceive as a single character —
the unit used for caret movement, click hit-testing, glyph selection,
and so on. The algorithm walks codepoints, classifies each by its
Grapheme_Cluster_Break property, and inserts a break between adjacent
classes per the GB1..GB13 rules in UAX #29 §3.1.1.

The property table embeds `GraphemeBreakProperty.txt` (Unicode 17.0)
and the Extended_Pictographic subset of `emoji-data.txt`. Both are
parsed lazily on first call and cached in a sorted range table
binary-searched per codepoint, mirroring `bidi/property.odin`.

References: UAX #29 §3.1.1; `GraphemeBreakProperty.txt`,
`emoji-data.txt`.
*/
package itemize

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"

// Grapheme_Cluster_Break values per UAX #29. `Other` is the default
// for unassigned codepoints.
GCB :: enum u8 {
	Other,
	CR,
	LF,
	Control,
	Extend,
	ZWJ,
	Regional_Indicator,
	Prepend,
	SpacingMark,
	L, V, T, LV, LVT,                                  // Hangul syllable parts
	Extended_Pictographic,                             // from emoji-data.txt
}

@(private="file")
GCB_Range :: struct {
	start, end: rune,
	cls:        GCB,
}

@(private="file") g_gcb_ranges:    []GCB_Range
@(private="file") g_gcb_load_once: sync.Once

@(private="file")
GCB_DATA :: #load("../tools/ucd/GraphemeBreakProperty.txt", string)
@(private="file")
EMOJI_DATA :: #load("../tools/ucd/emoji-data.txt", string)
@(private="file")
INCB_DATA :: #load("../tools/ucd/DerivedCoreProperties.txt", string)

// InCB (Indic_Conjunct_Break) values — drives UAX #29 GB9c, the
// "consonant linker consonant" no-break rule that keeps Devanagari /
// Bengali / Tamil / Telugu / Kannada / Malayalam / Gurmukhi /
// Gujarati conjunct stacks in a single grapheme cluster.
InCB :: enum u8 {
	None,
	Linker,
	Consonant,
	Extend,
}

@(private="file")
InCB_Range :: struct {
	start, end: rune,
	cls:        InCB,
}
@(private="file") g_incb_ranges:    []InCB_Range
@(private="file") g_incb_load_once: sync.Once

incb_class :: proc(r: rune) -> InCB {
	sync.once_do(&g_incb_load_once, init_incb_table)
	lo, hi := 0, len(g_incb_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_incb_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.cls
		}
	}
	return .None
}

@(private="file")
init_incb_table :: proc() {
	context.allocator = runtime.heap_allocator()
	tmp := make([dynamic]InCB_Range, 0, 512)
	data := INCB_DATA
	for line in strings.split_lines_iterator(&data) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' { continue }
		if hash := strings.index_byte(t, '#'); hash >= 0 {
			t = strings.trim_space(t[:hash])
		}
		// Format: <cp> ; <Property> ; <Value>
		parts := strings.split(t, ";", context.temp_allocator)
		if len(parts) != 3 { continue }
		prop := strings.trim_space(parts[1])
		if prop != "InCB" { continue }
		val := strings.trim_space(parts[2])
		cls: InCB
		switch val {
		case "Linker":    cls = .Linker
		case "Consonant": cls = .Consonant
		case "Extend":    cls = .Extend
		case:             continue
		}
		cp_part := strings.trim_space(parts[0])
		start, end: rune
		if dot := strings.index(cp_part, ".."); dot >= 0 {
			s, _ := strconv.parse_u64_of_base(cp_part[:dot], 16)
			e, _ := strconv.parse_u64_of_base(cp_part[dot + 2:], 16)
			start = rune(s); end = rune(e)
		} else {
			s, _ := strconv.parse_u64_of_base(cp_part, 16)
			start = rune(s); end = start
		}
		append(&tmp, InCB_Range{start = start, end = end, cls = cls})
	}
	for i in 1..<len(tmp) {
		j := i
		for j > 0 && tmp[j - 1].start > tmp[j].start {
			tmp[j - 1], tmp[j] = tmp[j], tmp[j - 1]
			j -= 1
		}
	}
	g_incb_ranges = tmp[:]
}

// gcb_class returns the Grapheme_Cluster_Break property for `r`.
gcb_class :: proc(r: rune) -> GCB {
	sync.once_do(&g_gcb_load_once, init_gcb_table)
	lo, hi := 0, len(g_gcb_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_gcb_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.cls
		}
	}
	return .Other
}

@(private="file")
init_gcb_table :: proc() {
	context.allocator = runtime.heap_allocator()
	tmp := make([dynamic]GCB_Range, 0, 1024)

	// Pass 1: GraphemeBreakProperty.txt — the bulk of the classes.
	gcb_data := GCB_DATA
	for line in strings.split_lines_iterator(&gcb_data) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }
		if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
			trimmed = strings.trim_space(trimmed[:hash])
		}
		semi := strings.index_byte(trimmed, ';')
		if semi < 0 { continue }
		cp_part   := strings.trim_space(trimmed[:semi])
		name_part := strings.trim_space(trimmed[semi + 1:])

		start, end: rune
		if dot := strings.index(cp_part, ".."); dot >= 0 {
			s, _ := strconv.parse_u64_of_base(cp_part[:dot], 16)
			e, _ := strconv.parse_u64_of_base(cp_part[dot + 2:], 16)
			start = rune(s); end = rune(e)
		} else {
			s, _ := strconv.parse_u64_of_base(cp_part, 16)
			start = rune(s); end = start
		}
		cls, ok := gcb_from_name(name_part)
		if !ok { continue }
		append(&tmp, GCB_Range{start = start, end = end, cls = cls})
	}

	// Pass 2: emoji-data.txt — Extended_Pictographic ranges. These
	// override Other but should NOT override an existing GCB class
	// from pass 1 (the spec splits the universes: Extended_Pictographic
	// is its own class only where no other GCB class applies).
	emoji_data := EMOJI_DATA
	for line in strings.split_lines_iterator(&emoji_data) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }
		if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
			trimmed = strings.trim_space(trimmed[:hash])
		}
		semi := strings.index_byte(trimmed, ';')
		if semi < 0 { continue }
		cp_part   := strings.trim_space(trimmed[:semi])
		name_part := strings.trim_space(trimmed[semi + 1:])
		if name_part != "Extended_Pictographic" { continue }

		start, end: rune
		if dot := strings.index(cp_part, ".."); dot >= 0 {
			s, _ := strconv.parse_u64_of_base(cp_part[:dot], 16)
			e, _ := strconv.parse_u64_of_base(cp_part[dot + 2:], 16)
			start = rune(s); end = rune(e)
		} else {
			s, _ := strconv.parse_u64_of_base(cp_part, 16)
			start = rune(s); end = start
		}
		append(&tmp, GCB_Range{start = start, end = end, cls = .Extended_Pictographic})
	}

	sort_gcb_ranges(tmp[:])
	g_gcb_ranges = tmp[:]
}

@(private="file")
sort_gcb_ranges :: proc(rs: []GCB_Range) {
	// Insertion sort: N ~ 1000, runs once at process startup.
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1].start > rs[j].start {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

@(private="file")
gcb_from_name :: proc(s: string) -> (GCB, bool) {
	switch s {
	case "CR":                 return .CR, true
	case "LF":                 return .LF, true
	case "Control":            return .Control, true
	case "Extend":             return .Extend, true
	case "ZWJ":                return .ZWJ, true
	case "Regional_Indicator": return .Regional_Indicator, true
	case "Prepend":            return .Prepend, true
	case "SpacingMark":        return .SpacingMark, true
	case "L":                  return .L, true
	case "V":                  return .V, true
	case "T":                  return .T, true
	case "LV":                 return .LV, true
	case "LVT":                return .LVT, true
	}
	return .Other, false
}

// is_grapheme_boundary reports whether a break is permitted *between*
// codepoints `a` (logically earlier) and `b` (logically later) per
// UAX #29 §3.1.1 GB rules.
//
// State for context-sensitive rules (GB11 emoji ZWJ sequences and
// GB12/13 regional-indicator pairs) is passed in via `state`. Callers
// using the iterator below don't need to touch the state directly.
GB_State :: struct {
	// True if the run immediately before `a` is an Extended_Pictographic
	// followed by zero or more Extend characters — the prefix that
	// permits GB11's "X (Extend|ZWJ)* ZWJ × Extended_Pictographic" no-
	// break.
	ext_pict_seq:   bool,
	// Parity of consecutive Regional_Indicator codepoints back to the
	// last non-RI boundary. GB12/13 disallow a break inside an even
	// pair, force one after.
	ri_count_odd:   bool,
	// GB9c (Indic_Conjunct_Break). We need to know whether the sequence
	// ending at `a` matches "Consonant (Extend|Linker)* Linker
	// (Extend|Linker)*" — only then is a following Consonant joined
	// without a break.
	incb_after_cons:    bool,
	incb_seen_linker:   bool,
}

// gb_init resets state for a fresh paragraph.
gb_init :: proc(s: ^GB_State) { s^ = {} }

// gb_advance updates the state machine with class `a` (the codepoint
// that just landed before the boundary we're about to test) and its
// InCB property. Call this once per codepoint *after* the boundary
// check; the iterator below threads it correctly.
gb_advance :: proc(s: ^GB_State, a: GCB, a_incb: InCB) {
	// GB11 prefix: starts on Extended_Pictographic, persists through
	// Extend / ZWJ, breaks on anything else.
	if a == .Extended_Pictographic {
		s.ext_pict_seq = true
	} else if a != .Extend && a != .ZWJ {
		s.ext_pict_seq = false
	}
	// GB12/13 RI parity.
	if a == .Regional_Indicator {
		s.ri_count_odd = !s.ri_count_odd
	} else {
		s.ri_count_odd = false
	}
	// GB9c InCB sequence tracking — "Consonant (Extend|Linker)*
	// Linker (Extend|Linker)*". Reset on anything outside the chain.
	switch a_incb {
	case .Consonant:
		s.incb_after_cons  = true
		s.incb_seen_linker = false
	case .Linker:
		if s.incb_after_cons { s.incb_seen_linker = true }
	case .Extend:
		// Stays in sequence.
	case .None:
		s.incb_after_cons  = false
		s.incb_seen_linker = false
	}
}

@(private)
is_grapheme_boundary :: proc(a, b: GCB, b_incb: InCB, state: ^GB_State) -> bool {
	// GB3.
	if a == .CR && b == .LF { return false }
	// GB4 — break after Control / CR / LF.
	if a == .Control || a == .CR || a == .LF { return true }
	// GB5 — break before Control / CR / LF.
	if b == .Control || b == .CR || b == .LF { return true }
	// GB6 / GB7 / GB8 — Hangul syllables stay together.
	if a == .L   && (b == .L  || b == .V  || b == .LV || b == .LVT) { return false }
	if (a == .LV || a == .V)  && (b == .V  || b == .T)              { return false }
	if (a == .LVT || a == .T) && b == .T                            { return false }
	// GB9 — × Extend, × ZWJ.
	if b == .Extend || b == .ZWJ { return false }
	// GB9a — × SpacingMark.
	if b == .SpacingMark { return false }
	// GB9b — Prepend ×.
	if a == .Prepend { return false }
	// GB11 — ExtPict (Extend|ZWJ)* ZWJ × ExtPict. We collapse the
	// star into the running `ext_pict_seq` flag — it's true iff the
	// sequence ending at `a` matches "ExtPict (Extend|ZWJ)*".
	if state.ext_pict_seq && a == .ZWJ && b == .Extended_Pictographic { return false }
	// GB9c — Indic conjunct: \p{InCB=Consonant} [\p{InCB=Extend} |
	// \p{InCB=Linker}]* \p{InCB=Linker} [\p{InCB=Extend} |
	// \p{InCB=Linker}]* × \p{InCB=Consonant}. The left side is
	// summarised in `state.incb_after_cons && state.incb_seen_linker`.
	if state.incb_after_cons && state.incb_seen_linker && b_incb == .Consonant { return false }
	// GB12 / GB13 — even-positioned RI pair stays together.
	if a == .Regional_Indicator && b == .Regional_Indicator && state.ri_count_odd { return false }
	// GB999 — default break.
	return true
}

// Grapheme_Iter yields (byte_start, byte_end) per cluster.
Grapheme_Iter :: struct {
	text:        string,
	byte_pos:    int,
}

grapheme_iter_make :: proc(text: string) -> Grapheme_Iter {
	return Grapheme_Iter{text = text, byte_pos = 0}
}

// grapheme_iter_next returns the next cluster's byte range, plus a
// flag that's false when iteration is finished.
grapheme_iter_next :: proc(it: ^Grapheme_Iter) -> (lo, hi: int, ok: bool) {
	if it.byte_pos >= len(it.text) { return }
	state: GB_State
	gb_init(&state)

	lo = it.byte_pos
	s := it.text[it.byte_pos:]
	cur_r, cur_sz := utf8_decode(s)
	cur := gcb_class(cur_r)
	cur_incb := incb_class(cur_r)
	gb_advance(&state, cur, cur_incb)
	pos := lo + cur_sz

	for pos < len(it.text) {
		next_r, next_sz := utf8_decode(it.text[pos:])
		next := gcb_class(next_r)
		next_incb := incb_class(next_r)
		if is_grapheme_boundary(cur, next, next_incb, &state) { break }
		gb_advance(&state, next, next_incb)
		cur = next
		cur_incb = next_incb
		pos += next_sz
	}
	hi = pos
	it.byte_pos = pos
	ok = true
	return
}

@(private)
utf8_decode :: proc(s: string) -> (r: rune, sz: int) {
	if len(s) == 0 { return 0xFFFD, 0 }
	b0 := s[0]
	if b0 < 0x80          { return rune(b0), 1 }
	if b0 < 0xC0          { return 0xFFFD, 1 }
	if b0 < 0xE0 && len(s) >= 2 {
		return rune(u32(b0 & 0x1F)<<6 | u32(s[1] & 0x3F), ), 2
	}
	if b0 < 0xF0 && len(s) >= 3 {
		return rune(u32(b0 & 0x0F)<<12 | u32(s[1] & 0x3F)<<6 | u32(s[2] & 0x3F)), 3
	}
	if b0 < 0xF8 && len(s) >= 4 {
		return rune(u32(b0 & 0x07)<<18 | u32(s[1] & 0x3F)<<12 | u32(s[2] & 0x3F)<<6 | u32(s[3] & 0x3F)), 4
	}
	return 0xFFFD, 1
}
