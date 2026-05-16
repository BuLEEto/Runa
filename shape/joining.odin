/*
Arabic / Syriac / Mandaic / N'Ko / etc. positional-shaping Joining
properties from UAX #9 Appendix B + ArabicShaping.txt.

This file ships the property lookup; the state-machine that turns
per-codepoint Joining_Type into the per-position joining form (and
selects which of `isol` / `init` / `medi` / `fina` to apply at GSUB
time) lives alongside it as `arabic_join_state`.

References: UAX §9, "Arabic Cursive Joining"; Unicode 17.0
`ArabicShaping.txt`.
*/
package shape

import "base:runtime"

import "core:strconv"
import "core:strings"
import "core:sync"

// Joining_Type values from ArabicShaping.txt.
//
//   U  Non_Joining — doesn't join (e.g. ZERO WIDTH NON-JOINER).
//   R  Right_Joining — joins from the right (Arabic Alef, Reh, …).
//   L  Left_Joining — joins from the left (rare; some Mongolian).
//   D  Dual_Joining — joins on both sides (most Arabic letters).
//   T  Transparent — combining marks; pass-through for join state.
//   C  Join_Causing — ZWJ / Kashida; force a join on adjacent sides.
//   X  (our sentinel) Not Arabic / Syriac / Mandaic — no joining.
Joining_Type :: enum u8 {
	X,        // default — not a joining script
	U,
	R,
	L,
	D,
	T,
	C,
}

@(private="file")
Range :: struct {
	start, end: rune,
	jt:         Joining_Type,
}

@(private="file") g_ranges:    []Range
@(private="file") g_load_once: sync.Once

@(private="file")
JOIN_DATA :: #load("../tools/ucd/ArabicShaping.txt", string)

@(private="file") JOIN_DATA_LINES := JOIN_DATA

// joining_type returns the Joining_Type of `r`. Characters not in
// `ArabicShaping.txt` default to `.X` (non-joining-script). The
// Arabic state machine treats `.X` as "interrupts joining" — same
// as `.U` for state-transition purposes.
joining_type :: proc(r: rune) -> Joining_Type {
	sync.once_do(&g_load_once, init_table)
	lo, hi := 0, len(g_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		row := g_ranges[mid]
		switch {
		case r < row.start: hi = mid
		case r > row.end:   lo = mid + 1
		case:               return row.jt
		}
	}
	return .X
}

@(private="file")
init_table :: proc() {
	context.allocator = runtime.heap_allocator()
	tmp := make([dynamic]Range, 0, 1024)
	for line in strings.split_lines_iterator(&JOIN_DATA_LINES) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }
		if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
			trimmed = strings.trim_space(trimmed[:hash])
		}
		// Format: CODE; NAME ; JOINING_TYPE ; JOINING_GROUP
		parts := strings.split(trimmed, ";", context.temp_allocator)
		if len(parts) < 3 { continue }
		cp_str := strings.trim_space(parts[0])
		jt_str := strings.trim_space(parts[2])
		jt: Joining_Type
		ok: bool
		switch jt_str {
		case "U": jt = .U; ok = true
		case "R": jt = .R; ok = true
		case "L": jt = .L; ok = true
		case "D": jt = .D; ok = true
		case "T": jt = .T; ok = true
		case "C": jt = .C; ok = true
		}
		if !ok { continue }
		// Single codepoint per line; ArabicShaping.txt doesn't use
		// ranges.
		s, _ := strconv.parse_u64_of_base(cp_str, 16)
		append(&tmp, Range{start = rune(s), end = rune(s), jt = jt})
	}
	sort_ranges(tmp[:])
	g_ranges = tmp[:]
}

@(private="file")
sort_ranges :: proc(rs: []Range) {
	for i in 1..<len(rs) {
		j := i
		for j > 0 && rs[j - 1].start > rs[j].start {
			rs[j - 1], rs[j] = rs[j], rs[j - 1]
			j -= 1
		}
	}
}

// Joining_Form — what shape the glyph takes given its neighbours.
// Maps directly to the OpenType GSUB feature tag that should fire
// for that character: `isol`, `init`, `medi`, `fina`.
Joining_Form :: enum u8 {
	Isolated,        // 'isol' — no join on either side
	Initial,         // 'init' — joins on the left (next char accepts)
	Medial,          // 'medi' — joins on both sides
	Final,           // 'fina' — joins on the right (previous char accepts)
}

// arabic_join_state walks `runes` and assigns each codepoint its
// Joining_Form. The state machine is the one from Unicode TR9
// Appendix B — informally:
//
//   right-joining (R) follows D / R / C → its joining form gains a
//   right-side link (becomes final or medial);
//   left-joining (L) precedes D / L / C → gains a left link
//   (becomes initial or medial);
//   transparent (T) passes through for state purposes;
//   non-joining (U / X) interrupts the chain.
//
// `forms` must be sized to `len(runes)`. Caller-owned slice.
arabic_join_state :: proc(runes: []rune, forms: []Joining_Form) {
	if len(runes) == 0 || len(forms) != len(runes) { return }

	// First pass: every character starts as Isolated. We'll add
	// init/medi/fina bits as we walk.
	for i in 0..<len(runes) { forms[i] = .Isolated }

	// `last_d_or_l_idx` tracks the most recent non-transparent
	// joining character that can attach to the *next* codepoint
	// (i.e., something that has a left-attaching tail).
	prev_join_idx := -1
	for i in 0..<len(runes) {
		jt := joining_type(runes[i])
		if jt == .T {
			continue                              // transparent; carry prev state forward
		}

		// Resolve THIS character's joining state by looking at
		// `prev_join_idx`'s joining type.
		links_right := false                       // this char's right side joins
		if prev_join_idx >= 0 {
			pjt := joining_type(runes[prev_join_idx])
			// Right-side join of THIS char requires the previous
			// non-transparent char to be D, L, or C.
			if pjt == .D || pjt == .L || pjt == .C {
				if jt == .R || jt == .D || jt == .C {
					links_right = true
				}
			}
		}

		// If this char attaches on its right side, AND the previous
		// joining character is currently Initial or Medial-eligible,
		// upgrade them.
		if links_right && prev_join_idx >= 0 {
			// THIS char becomes Final (or Medial if it can also link
			// left — that's resolved in the next iteration).
			forms[i] = .Final
			// Previous char's right side joined to us — bump it from
			// Isolated→Initial or Final→Medial.
			pform := forms[prev_join_idx]
			#partial switch pform {
			case .Isolated: forms[prev_join_idx] = .Initial
			case .Final:    forms[prev_join_idx] = .Medial
			}
		}

		// Only D/L/C/R/U advance the chain. U breaks it.
		if jt == .U || jt == .X {
			prev_join_idx = -1
		} else {
			prev_join_idx = i
		}
	}
}
