package raster

// autohint.odin — minimal Latin grid-fitting.
//
// Unhinted outline rasterization produces correct AA but at small
// body sizes (~10-14 px on 96 DPI) horizontal features like the
// bottom curve of S, e, c, a, o land at fractional pixel rows.
// The rasterizer splits coverage across two rows, which the eye
// reads as a fuzzy 2-pixel band instead of a crisp 1-pixel stroke.
//
// Real grid-fitting needs per-glyph stem analysis (FreeType's
// autohinter is ~3 kloc). This is the cheap version: precompute
// per-font blue zone positions (baseline, x-height, cap-height,
// ascender, descender) once, snap each to integer pixel rows for
// the requested size, and at raster time map every outline Y
// linearly between the snapped zones. Points landing exactly on a
// blue zone get pixel-perfect placement; intermediate features
// drift proportionally between the snapped boundaries.
//
// Limitations baked in:
//   - Latin-only. CJK and Indic have very different stem
//     structures; running this heuristic on them would distort
//     glyphs more than help.
//   - Y-only. We don't snap stem widths or vertical strokes; the
//     symptom we're fixing is bottom-of-S fluffiness specifically.
//   - No overshoot preservation — round letters lose their visual
//     overshoot at small sizes, which is exactly what most
//     hinting policies do anyway at body text sizes.

import "core:math"

// Hint_Metrics carries blue-zone Y positions in *font units*. Sample
// once at font load time; pass into `hint_snap_for_size` to materialise
// the per-size snapped positions used at raster.
Hint_Metrics :: struct {
	descender:        f32, // bottom of descender bowls — y_min of 'p'
	round_bottom:     f32, // overshoot of round letters below baseline — y_min of 'o' (small negative)
	baseline:         f32, // 0 by convention; carried for symmetry
	x_height:         f32, // flat top of 'x'
	round_x_height:   f32, // overshoot top of lowercase round letters — y_max of 'o' (just above x_height)
	cap_height:       f32, // flat top of 'H'
	round_cap_height: f32, // overshoot top of uppercase round letters — y_max of 'O' (just above cap_height)
	ascender:         f32, // flat top of 'l'
	valid:            bool,
}

// Hint_Snap is the precomputed per-size grid-fit table. Both the
// pre-scaled (`*_pre`) and snapped (`*_snap`) positions are in
// pixel space; pre values are the raw `metrics.y * scale`, snap
// values are those rounded to the nearest integer pixel row.
Hint_Snap :: struct {
	descender_pre,        descender_snap:        f32,
	round_bottom_pre,     round_bottom_snap:     f32,
	baseline_pre,         baseline_snap:         f32,
	x_height_pre,         x_height_snap:         f32,
	round_x_height_pre,   round_x_height_snap:   f32,
	cap_height_pre,       cap_height_snap:       f32,
	round_cap_height_pre, round_cap_height_snap: f32,
	ascender_pre,         ascender_snap:         f32,
	valid: bool,
}

// hint_snap_for_size materialises a Hint_Snap for the given font
// size. Cheap (just a handful of scales + rounds), so callers can
// build one per glyph rasterization without caching.
hint_snap_for_size :: proc(m: Hint_Metrics, units_per_em: u16, size: f32) -> Hint_Snap {
	out: Hint_Snap
	if !m.valid || units_per_em == 0 || size <= 0 { return out }
	s := size / f32(units_per_em)
	out.descender_pre        = m.descender        * s
	out.round_bottom_pre     = m.round_bottom     * s
	out.baseline_pre         = m.baseline         * s
	out.x_height_pre         = m.x_height         * s
	out.round_x_height_pre   = m.round_x_height   * s
	out.cap_height_pre       = m.cap_height       * s
	out.round_cap_height_pre = m.round_cap_height * s
	out.ascender_pre         = m.ascender         * s
	// Flat zones get straightforward independent rounding — each is a
	// "primary" anchor that other zones snap relative to.
	out.descender_snap  = math.round(out.descender_pre)
	out.baseline_snap   = math.round(out.baseline_pre)
	out.x_height_snap   = math.round(out.x_height_pre)
	out.cap_height_snap = math.round(out.cap_height_pre)
	out.ascender_snap   = math.round(out.ascender_pre)
	// Round zones get RELATIVE snap against their flat anchor. The
	// reason: independent rounding of two close pre-values can put
	// them on different sides of a half-pixel boundary even when the
	// real overshoot is far less than half a pixel. Example with
	// Inter cap_height=1490, round_cap=1510, UPM 2048, size 24:
	//
	//   cap_pre       = 17.46  →  round  →  17
	//   round_cap_pre = 17.70  →  round  →  18
	//
	// Real overshoot: 0.24 px. Independent rounding: 1 px gap. The
	// lerp band then maps the round top to a row 1 above cap, and the
	// outline emits a stray "lump" pixel at the top of round letters
	// at body sizes. Relative snap takes the gap directly and only
	// preserves overshoot when it crosses half a pixel.
	out.round_bottom_snap     = relative_snap_below(out.baseline_pre,   out.round_bottom_pre,     out.baseline_snap)
	out.round_x_height_snap   = relative_snap_above(out.x_height_pre,   out.round_x_height_pre,   out.x_height_snap)
	out.round_cap_height_snap = relative_snap_above(out.cap_height_pre, out.round_cap_height_pre, out.cap_height_snap)
	out.valid = true
	return out
}

// relative_snap_above snaps an overshoot zone that sits above a flat
// anchor (e.g. round-top of 'o' above x_height). Suppresses when the
// pre-scale overshoot is sub-half-pixel; preserves as +N rows above
// the flat snap when it's larger.
@(private)
relative_snap_above :: proc(flat_pre, round_pre, flat_snap: f32) -> f32 {
	overshoot := round_pre - flat_pre
	if overshoot < 0.5 { return flat_snap }
	return flat_snap + math.round(overshoot)
}

// relative_snap_below is the mirror for overshoot below a flat anchor
// (e.g. round-bottom of 'o' below baseline).
@(private)
relative_snap_below :: proc(flat_pre, round_pre, flat_snap: f32) -> f32 {
	overshoot := flat_pre - round_pre
	if overshoot < 0.5 { return flat_snap }
	return flat_snap - math.round(overshoot)
}

// apply_hint_y maps a pre-scaled outline Y to its hinted Y. Outside
// the descender..ascender band we just preserve the delta of the
// nearest reference zone (so features above the ascender or below
// the descender keep their relative position from that boundary).
apply_hint_y :: #force_inline proc(y_pre: f32, h: Hint_Snap) -> f32 {
	if !h.valid { return y_pre }
	if y_pre <= h.descender_pre {
		return h.descender_snap + (y_pre - h.descender_pre)
	}
	if y_pre <= h.round_bottom_pre {
		return hint_lerp(y_pre, h.descender_pre, h.round_bottom_pre, h.descender_snap, h.round_bottom_snap)
	}
	// round_bottom..baseline — the overshoot band of round letters.
	// At body sizes both endpoints snap to 0, so every point here
	// collapses to baseline_snap = 0 (overshoot suppressed). At
	// display sizes the round_bottom_snap separates from baseline_snap
	// and the natural lerp recovers a 1-px overshoot.
	if y_pre <= h.baseline_pre {
		return hint_lerp(y_pre, h.round_bottom_pre, h.baseline_pre, h.round_bottom_snap, h.baseline_snap)
	}
	if y_pre <= h.x_height_pre {
		return hint_lerp(y_pre, h.baseline_pre, h.x_height_pre, h.baseline_snap, h.x_height_snap)
	}
	// x_height..round_x_height — overshoot band for lowercase round
	// tops (o, c, e, s, a). At body sizes both snap to the same
	// integer row and the lerp collapses, suppressing the fluff at
	// the top of round lowercase letters.
	if y_pre <= h.round_x_height_pre {
		return hint_lerp(y_pre, h.x_height_pre, h.round_x_height_pre, h.x_height_snap, h.round_x_height_snap)
	}
	if y_pre <= h.cap_height_pre {
		return hint_lerp(y_pre, h.round_x_height_pre, h.cap_height_pre, h.round_x_height_snap, h.cap_height_snap)
	}
	// cap_height..round_cap_height — same idea for uppercase rounds
	// (O, C, G, S, Q).
	if y_pre <= h.round_cap_height_pre {
		return hint_lerp(y_pre, h.cap_height_pre, h.round_cap_height_pre, h.cap_height_snap, h.round_cap_height_snap)
	}
	if y_pre <= h.ascender_pre {
		return hint_lerp(y_pre, h.round_cap_height_pre, h.ascender_pre, h.round_cap_height_snap, h.ascender_snap)
	}
	return h.ascender_snap + (y_pre - h.ascender_pre)
}

@(private)
hint_lerp :: #force_inline proc(y, y0, y1, s0, s1: f32) -> f32 {
	if y1 == y0 { return s0 }
	return s0 + (y - y0) * (s1 - s0) / (y1 - y0)
}
