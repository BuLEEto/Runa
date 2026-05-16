/*
UAX #9 BD16 bracket-pair properties.

We hard-code the Unicode 17.0 `BidiBrackets.txt` table — 64 pairs,
small enough that a switch is faster than a lazy-parsed binary
search. The data drives N0 (resolving neutrals around bracket
pairs).

References: UAX #9 §3.3.5, `BidiBrackets.txt`.
*/
package bidi

// Bracket_Type for a paired bracket character.
Bracket_Type :: enum u8 {
	None,
	Open,
	Close,
}

// bidi_paired_bracket returns the codepoint of the matching bracket
// (so '(' returns ')', ']' returns '['), or 0 if `r` is not a paired
// bracket. The value is the canonical equivalent: paired-bracket
// canonical equivalence kicks in at lookup time.
bidi_paired_bracket :: proc(r: rune) -> rune {
	pair, _ := bracket_info(r)
	return pair
}

// bidi_paired_bracket_type returns Open / Close / None.
bidi_paired_bracket_type :: proc(r: rune) -> Bracket_Type {
	_, t := bracket_info(r)
	return t
}

// brackets_match reports whether `a` and `b` are the same bracket
// character modulo Unicode canonical equivalence. UAX #9 BD16 says
// the matching pair comparison happens after NFD normalization;
// for paired brackets the only canonical-equivalence groups are
// U+2329 ≡ U+3008 (angle bracket open) and U+232A ≡ U+3009 (close).
brackets_match :: proc(a, b: rune) -> bool {
	if a == b { return true }
	switch a {
	case 0x2329: return b == 0x3008
	case 0x3008: return b == 0x2329
	case 0x232A: return b == 0x3009
	case 0x3009: return b == 0x232A
	}
	return false
}

@(private)
bracket_info :: proc(r: rune) -> (pair: rune, kind: Bracket_Type) {
	switch r {
	case 0x0028: return 0x0029, .Open
	case 0x0029: return 0x0028, .Close
	case 0x005B: return 0x005D, .Open
	case 0x005D: return 0x005B, .Close
	case 0x007B: return 0x007D, .Open
	case 0x007D: return 0x007B, .Close
	case 0x0F3A: return 0x0F3B, .Open
	case 0x0F3B: return 0x0F3A, .Close
	case 0x0F3C: return 0x0F3D, .Open
	case 0x0F3D: return 0x0F3C, .Close
	case 0x169B: return 0x169C, .Open
	case 0x169C: return 0x169B, .Close
	case 0x2045: return 0x2046, .Open
	case 0x2046: return 0x2045, .Close
	case 0x207D: return 0x207E, .Open
	case 0x207E: return 0x207D, .Close
	case 0x208D: return 0x208E, .Open
	case 0x208E: return 0x208D, .Close
	case 0x2308: return 0x2309, .Open
	case 0x2309: return 0x2308, .Close
	case 0x230A: return 0x230B, .Open
	case 0x230B: return 0x230A, .Close
	case 0x2329: return 0x232A, .Open
	case 0x232A: return 0x2329, .Close
	case 0x2768: return 0x2769, .Open
	case 0x2769: return 0x2768, .Close
	case 0x276A: return 0x276B, .Open
	case 0x276B: return 0x276A, .Close
	case 0x276C: return 0x276D, .Open
	case 0x276D: return 0x276C, .Close
	case 0x276E: return 0x276F, .Open
	case 0x276F: return 0x276E, .Close
	case 0x2770: return 0x2771, .Open
	case 0x2771: return 0x2770, .Close
	case 0x2772: return 0x2773, .Open
	case 0x2773: return 0x2772, .Close
	case 0x2774: return 0x2775, .Open
	case 0x2775: return 0x2774, .Close
	case 0x27C5: return 0x27C6, .Open
	case 0x27C6: return 0x27C5, .Close
	case 0x27E6: return 0x27E7, .Open
	case 0x27E7: return 0x27E6, .Close
	case 0x27E8: return 0x27E9, .Open
	case 0x27E9: return 0x27E8, .Close
	case 0x27EA: return 0x27EB, .Open
	case 0x27EB: return 0x27EA, .Close
	case 0x27EC: return 0x27ED, .Open
	case 0x27ED: return 0x27EC, .Close
	case 0x27EE: return 0x27EF, .Open
	case 0x27EF: return 0x27EE, .Close
	case 0x2983: return 0x2984, .Open
	case 0x2984: return 0x2983, .Close
	case 0x2985: return 0x2986, .Open
	case 0x2986: return 0x2985, .Close
	case 0x2987: return 0x2988, .Open
	case 0x2988: return 0x2987, .Close
	case 0x2989: return 0x298A, .Open
	case 0x298A: return 0x2989, .Close
	case 0x298B: return 0x298C, .Open
	case 0x298C: return 0x298B, .Close
	case 0x298D: return 0x2990, .Open
	case 0x2990: return 0x298D, .Close
	case 0x298E: return 0x298F, .Close
	case 0x298F: return 0x298E, .Open
	case 0x2991: return 0x2992, .Open
	case 0x2992: return 0x2991, .Close
	case 0x2993: return 0x2994, .Open
	case 0x2994: return 0x2993, .Close
	case 0x2995: return 0x2996, .Open
	case 0x2996: return 0x2995, .Close
	case 0x2997: return 0x2998, .Open
	case 0x2998: return 0x2997, .Close
	case 0x29D8: return 0x29D9, .Open
	case 0x29D9: return 0x29D8, .Close
	case 0x29DA: return 0x29DB, .Open
	case 0x29DB: return 0x29DA, .Close
	case 0x29FC: return 0x29FD, .Open
	case 0x29FD: return 0x29FC, .Close
	case 0x2E22: return 0x2E23, .Open
	case 0x2E23: return 0x2E22, .Close
	case 0x2E24: return 0x2E25, .Open
	case 0x2E25: return 0x2E24, .Close
	case 0x2E26: return 0x2E27, .Open
	case 0x2E27: return 0x2E26, .Close
	case 0x2E28: return 0x2E29, .Open
	case 0x2E29: return 0x2E28, .Close
	case 0x2E55: return 0x2E56, .Open
	case 0x2E56: return 0x2E55, .Close
	case 0x2E57: return 0x2E58, .Open
	case 0x2E58: return 0x2E57, .Close
	case 0x2E59: return 0x2E5A, .Open
	case 0x2E5A: return 0x2E59, .Close
	case 0x2E5B: return 0x2E5C, .Open
	case 0x2E5C: return 0x2E5B, .Close
	case 0x3008: return 0x3009, .Open
	case 0x3009: return 0x3008, .Close
	case 0x300A: return 0x300B, .Open
	case 0x300B: return 0x300A, .Close
	case 0x300C: return 0x300D, .Open
	case 0x300D: return 0x300C, .Close
	case 0x300E: return 0x300F, .Open
	case 0x300F: return 0x300E, .Close
	case 0x3010: return 0x3011, .Open
	case 0x3011: return 0x3010, .Close
	case 0x3014: return 0x3015, .Open
	case 0x3015: return 0x3014, .Close
	case 0x3016: return 0x3017, .Open
	case 0x3017: return 0x3016, .Close
	case 0x3018: return 0x3019, .Open
	case 0x3019: return 0x3018, .Close
	case 0x301A: return 0x301B, .Open
	case 0x301B: return 0x301A, .Close
	case 0xFE59: return 0xFE5A, .Open
	case 0xFE5A: return 0xFE59, .Close
	case 0xFE5B: return 0xFE5C, .Open
	case 0xFE5C: return 0xFE5B, .Close
	case 0xFE5D: return 0xFE5E, .Open
	case 0xFE5E: return 0xFE5D, .Close
	case 0xFF08: return 0xFF09, .Open
	case 0xFF09: return 0xFF08, .Close
	case 0xFF3B: return 0xFF3D, .Open
	case 0xFF3D: return 0xFF3B, .Close
	case 0xFF5B: return 0xFF5D, .Open
	case 0xFF5D: return 0xFF5B, .Close
	case 0xFF5F: return 0xFF60, .Open
	case 0xFF60: return 0xFF5F, .Close
	case 0xFF62: return 0xFF63, .Open
	case 0xFF63: return 0xFF62, .Close
	}
	return 0, .None
}
