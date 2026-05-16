package raster

// outline.odin — convert a parsed glyph outline into a list of oriented
// line segments suitable for the scanline rasterizer.
//
// TrueType outlines use *quadratic* Béziers. Each curve has one control
// point (off-curve) between two endpoints (on-curve). Two consecutive
// off-curve points imply an on-curve point at their midpoint — the
// flattener materialises these implicit points.
//
// Output coordinates are in pixel space, y-flipped so the rasterizer
// can walk rows top-to-bottom matching the bitmap layout.

import "../parse"

// Edge is one oriented line segment after flattening. Coordinates are
// f32 to give the rasterizer fractional-pixel precision for AA.
Edge :: struct {
	x0, y0: f32,
	x1, y1: f32,
}

// flatten_outline replaces curves with line segments, applies a pixel
// scale, and y-flips so screen coordinates match the bitmap. Empty
// outlines (no contours) emit no edges.
//
// `tolerance` is the maximum allowed deviation of a flattened curve
// from the true curve, in output (pixel) units. 0.25 pixels is the
// canonical choice — visually indistinguishable, computationally cheap.
flatten_outline :: proc(o: ^parse.Outline, scale_x, scale_y, baseline: f32, edges: ^[dynamic]Edge, tolerance: f32 = 0.25) {
	clear(edges)
	if len(o.contour_ends) == 0 { return }

	contour_start := 0
	for end_idx_u16 in o.contour_ends {
		end_idx := int(end_idx_u16)
		if end_idx < contour_start || end_idx >= len(o.points) {
			contour_start = end_idx + 1
			continue
		}
		flatten_contour(o.points[contour_start:end_idx + 1], scale_x, scale_y, baseline, edges, tolerance)
		contour_start = end_idx + 1
	}
}

@(private)
flatten_contour :: proc(pts: []parse.Outline_Point, sx, sy, baseline: f32, edges: ^[dynamic]Edge, tol: f32) {
	n := len(pts)
	if n < 2 { return }

	// Project a font-unit point into pixel space, y-flipped so the
	// bitmap can walk top-down. `baseline` is the y offset (in pixel
	// units) where the baseline of the glyph lands.
	to_px :: proc(p: parse.Outline_Point, sx, sy, baseline: f32) -> (x, y: f32) {
		return f32(p.x) * sx, baseline - f32(p.y) * sy
	}

	// Find the first on-curve point. If none — the whole contour is
	// off-curve, an exotic but legal form — synthesise implicit
	// on-curve points at every consecutive-off midpoint by retrying
	// against an augmented sequence.
	first_on := -1
	for p, i in pts {
		if p.on_curve {
			first_on = i
			break
		}
	}
	if first_on < 0 {
		expanded := make([dynamic]parse.Outline_Point, 0, 2 * n, context.temp_allocator)
		for i in 0..<n {
			next := pts[(i + 1) % n]
			cur  := pts[i]
			append(&expanded, cur)
			mid := parse.Outline_Point{
				x        = (cur.x + next.x) / 2,
				y        = (cur.y + next.y) / 2,
				on_curve = true,
			}
			append(&expanded, mid)
		}
		flatten_contour(expanded[:], sx, sy, baseline, edges, tol)
		return
	}

	// Walk the contour starting from `first_on`, wrapping back to it on
	// the last iteration to close the loop.
	start_pt := pts[first_on]
	cur_x, cur_y := to_px(start_pt, sx, sy, baseline)

	pending_off    := false
	pending_off_pt: parse.Outline_Point

	for offset in 1..=n {
		idx := (first_on + offset) % n
		p := pts[idx]
		if offset == n {
			// Last step: close back to the starting point. Force on-curve
			// so the loop terminates without a dangling control.
			p = start_pt
			p.on_curve = true
		}
		if p.on_curve {
			ex, ey := to_px(p, sx, sy, baseline)
			if pending_off {
				cx, cy := to_px(pending_off_pt, sx, sy, baseline)
				emit_quadratic(cur_x, cur_y, cx, cy, ex, ey, edges, tol)
				pending_off = false
			} else {
				append(edges, Edge{x0 = cur_x, y0 = cur_y, x1 = ex, y1 = ey})
			}
			cur_x, cur_y = ex, ey
		} else {
			if pending_off {
				// Two off-curve in a row: implicit on-curve at midpoint.
				mid := parse.Outline_Point{
					x        = (pending_off_pt.x + p.x) / 2,
					y        = (pending_off_pt.y + p.y) / 2,
					on_curve = true,
				}
				mx, my := to_px(mid, sx, sy, baseline)
				cx, cy := to_px(pending_off_pt, sx, sy, baseline)
				emit_quadratic(cur_x, cur_y, cx, cy, mx, my, edges, tol)
				cur_x, cur_y = mx, my
			}
			pending_off_pt = p
			pending_off    = true
		}
	}
}

// emit_quadratic flattens a single quadratic Bézier into line segments
// via adaptive midpoint subdivision. The recursion bottoms out when the
// curve's deviation from the chord is below `tol`.
@(private)
emit_quadratic :: proc(p0x, p0y, p1x, p1y, p2x, p2y: f32, edges: ^[dynamic]Edge, tol: f32) {
	// Flatness test: the midpoint of the curve is at
	//   m = (p0 + 2*p1 + p2) / 4
	// Distance from m to the chord (p0 -> p2) is what we want to bound.
	// A cheap approximation: distance from p1 to the chord midpoint,
	// divided by 2. For a quadratic, the curve's deviation from the
	// chord equals exactly half the distance from p1 to that chord
	// midpoint.
	mx := (p0x + p2x) * 0.5
	my := (p0y + p2y) * 0.5
	dx := p1x - mx
	dy := p1y - my
	// Deviation = sqrt(dx*dx+dy*dy) / 2; compare squared to avoid sqrt.
	if dx*dx + dy*dy <= 4.0 * tol * tol {
		append(edges, Edge{x0 = p0x, y0 = p0y, x1 = p2x, y1 = p2y})
		return
	}
	// Midpoint subdivision (de Casteljau).
	q0x := (p0x + p1x) * 0.5
	q0y := (p0y + p1y) * 0.5
	q1x := (p1x + p2x) * 0.5
	q1y := (p1y + p2y) * 0.5
	mmx := (q0x + q1x) * 0.5
	mmy := (q0y + q1y) * 0.5
	emit_quadratic(p0x, p0y, q0x, q0y, mmx, mmy, edges, tol)
	emit_quadratic(mmx, mmy, q1x, q1y, p2x, p2y, edges, tol)
}
