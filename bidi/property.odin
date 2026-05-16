/*
UAX #9 Bidi_Class property lookup.

Same shape as `linebreak/property.odin`: embed the UCD data, lazy-parse
into a sorted range table on first call, binary-search per codepoint.
Codegen-baked trie comes in the v0.6 polish.

References: UAX #9 §3.2 (Bidirectional Character Types),
`https://www.unicode.org/Public/UCD/latest/ucd/extracted/DerivedBidiClass.txt`.
*/
package bidi

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"

// Bidi_Class values per UAX #9. The naming matches the UCD short
// codes so a code reader can cross-reference the spec directly.
Bidi_Class :: enum u8 {
	// Strong types
	L,        // Left-to-Right
	R,        // Right-to-Left
	AL,       // Right-to-Left Arabic

	// Weak types
	EN,       // European Number
	ES,       // European Number Separator
	ET,       // European Number Terminator
	AN,       // Arabic Number
	CS,       // Common Number Separator
	NSM,      // Non-Spacing Mark
	BN,       // Boundary Neutral

	// Neutral types
	B,        // Paragraph Separator
	S,        // Segment Separator
	WS,       // Whitespace
	ON,       // Other Neutrals

	// Explicit formatting types
	LRE,      // Left-to-Right Embedding
	LRO,      // Left-to-Right Override
	RLE,      // Right-to-Left Embedding
	RLO,      // Right-to-Left Override
	PDF,      // Pop Directional Format
	LRI,      // Left-to-Right Isolate
	RLI,      // Right-to-Left Isolate
	FSI,      // First Strong Isolate
	PDI,      // Pop Directional Isolate

	// Default
	XX,       // Unassigned — treated as ON per UAX #9
}

@(private="file")
Range :: struct {
	start, end: rune,
	cls:        Bidi_Class,
}

@(private="file") g_ranges:    []Range
@(private="file") g_load_once: sync.Once

@(private="file")
BIDI_DATA :: #load("../tools/ucd/DerivedBidiClass.txt", string)

@(private="file") BIDI_DATA_LINES := BIDI_DATA

// bidi_class returns the Bidi_Class of `r`. Unassigned codepoints
// default to `ON` per UAX #9 (some specific blocks default to other
// classes, but we accept the small accuracy loss at v0.5 — the
// segmentation tests still pass with the simple default).
bidi_class :: proc(r: rune) -> Bidi_Class {
	sync.once_do(&g_load_once, init_table)
	lo, hi := 0, len(g_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.cls
		}
	}
	return .ON
}

@(private="file")
init_table :: proc() {
	context.allocator = runtime.heap_allocator()    // process-lifetime cache
	tmp := make([dynamic]Range, 0, 2048)
	for line in strings.split_lines_iterator(&BIDI_DATA_LINES) {
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
		cls, ok := class_from_short(name_part)
		if !ok { continue }
		append(&tmp, Range{start = start, end = end, cls = cls})
	}
	// DerivedBidiClass.txt isn't sorted by codepoint, so sort before
	// the binary search.
	sort_ranges(tmp[:])
	g_ranges = tmp[:]
}

@(private="file")
sort_ranges :: proc(rs: []Range) {
	// Insertion sort — N ~ 1500, runs once at process startup.
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1].start > rs[j].start {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

@(private="file")
class_from_short :: proc(s: string) -> (Bidi_Class, bool) {
	switch s {
	case "L":   return .L,   true
	case "R":   return .R,   true
	case "AL":  return .AL,  true
	case "EN":  return .EN,  true
	case "ES":  return .ES,  true
	case "ET":  return .ET,  true
	case "AN":  return .AN,  true
	case "CS":  return .CS,  true
	case "NSM": return .NSM, true
	case "BN":  return .BN,  true
	case "B":   return .B,   true
	case "S":   return .S,   true
	case "WS":  return .WS,  true
	case "ON":  return .ON,  true
	case "LRE": return .LRE, true
	case "LRO": return .LRO, true
	case "RLE": return .RLE, true
	case "RLO": return .RLO, true
	case "PDF": return .PDF, true
	case "LRI": return .LRI, true
	case "RLI": return .RLI, true
	case "FSI": return .FSI, true
	case "PDI": return .PDI, true
	}
	return .XX, false
}
