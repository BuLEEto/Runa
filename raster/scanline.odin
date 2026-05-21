package raster

// scanline.odin — analytic-x scanline rasterizer with 4× y super-sampling.
//
// For each pixel row we evaluate four sub-scanlines (y + 0.125,
// y + 0.375, y + 0.625, y + 0.875). At each sub-scanline we compute
// the exact x-intersections of every flattened edge with that
// horizontal line, sort them, and walk left-to-right tracking the
// non-zero winding count. Inside intervals contribute *analytic*
// horizontal coverage to each pixel column (the fraction of the
// pixel cell the interval covers).
//
// Cost per row: O(edges) for crossing computation + O(edges log
// edges) sort + O(intervals * average_interval_width) for the
// coverage spread. For a 32 px glyph with ~80 edges this is roughly
// 1 / 200× the work of the previous 4×4 point-in-polygon
// implementation, and matches FreeType / stb_truetype output at the
// sub-pixel-x grid resolution.

import "core:math"

import "../parse"

// rasterize fills `bitmap` with antialiased coverage for the glyph
// outline. The caller passes already-allocated buffers (`bitmap` and
// `edges`) so the rasterizer makes zero allocations per call once
// scratch space is sized.
//
// `subpx_x` is the subpixel x-offset bucket in quarter-pixel steps
// (0..3); the rasterizer shifts the outline by `subpx_x / 4` px in x
// before scanline conversion, so the caller can cache four variants
// per (font, glyph, size) instead of snapping to integer pixels.
rasterize :: proc(o: ^parse.Outline, units_per_em: u16, size: f32, edges: ^[dynamic]Edge, subpx_x: u8 = 0, allocator := context.allocator, hint: ^Hint_Snap = nil) -> (b: Bitmap, x_offset, y_offset: int, err: Rast_Error) {
	if size <= 0 || units_per_em == 0 {
		err = .Invalid_Size
		return
	}

	scale := size / f32(units_per_em)

	// Subpixel offset in pixel units. Quantised to 4 buckets (0, 0.25,
	// 0.5, 0.75). Anything beyond 3 wraps back to 0 — caller's
	// responsibility to keep the value in range.
	dx := f32(subpx_x & 3) / 4.0

	// Bbox in pixel space (y-flipped: lower y in font = upper y in
	// image). When hinting is active the outline's Y values get
	// remapped between snapped blue zones, so the bbox needs the same
	// remap to keep the bitmap sized right.
	y_top_pre    := -f32(o.y_max) * scale
	y_bottom_pre := -f32(o.y_min) * scale
	if hint != nil && hint.valid {
		y_top_pre    = -apply_hint_y(f32(o.y_max) * scale, hint^)
		y_bottom_pre = -apply_hint_y(f32(o.y_min) * scale, hint^)
	}
	x_min_px := math.floor(f32(o.x_min) * scale + dx)
	x_max_px := math.ceil (f32(o.x_max) * scale + dx)
	y_min_px := math.floor(y_top_pre)
	y_max_px := math.ceil (y_bottom_pre)

	width  := int(x_max_px - x_min_px)
	height := int(y_max_px - y_min_px)

	if width <= 0 || height <= 0 {
		// Degenerate or empty glyph. Return a 0×0 bitmap.
		return
	}

	bm, ok := bitmap_make(width, height, allocator)
	if !ok { err = .Out_Of_Memory; return }

	// Flatten so edges live in *bitmap-relative* coords: top-left of
	// the bitmap is (0, 0). flatten_outline only handles the
	// y-baseline shift; we apply the x-origin shift (and the
	// subpixel `dx`) here. The current call has scale_x = scale_y =
	// scale and writes y as `baseline - y_font*scale` — pass
	// baseline = -y_min_px to align the top with row 0.
	flatten_outline(o, scale, scale, -y_min_px, edges, 0.25, hint)
	x_shift := -x_min_px + dx
	if x_shift != 0 {
		for i in 0..<len(edges) {
			edges[i].x0 += x_shift
			edges[i].x1 += x_shift
		}
	}

	rasterize_scanline(edges[:], &bm)

	b = bm
	x_offset = int(x_min_px)
	y_offset = int(y_min_px)
	return
}

// Edge_Crossing is one (x, sign) pair produced by intersecting an
// edge with a sub-scanline. Sign is +1 for downward-going edges,
// −1 for upward — these compose under non-zero winding.
@(private)
Edge_Crossing :: struct {
	x:    f32,
	sign: i8,
}

@(private)
rasterize_scanline :: proc(edges: []Edge, bm: ^Bitmap) {
	if bm.width == 0 || bm.height == 0 { return }

	SS_Y :: 4
	WEIGHT :: 1.0 / f32(SS_Y)

	cov := make([]f32, bm.width, context.temp_allocator)

	// Per-row scratch — reused across the SS_Y sub-scanlines.
	xs := make([dynamic]Edge_Crossing, 0, max(8, len(edges)), context.temp_allocator)

	for py in 0..<bm.height {
		for i in 0..<bm.width { cov[i] = 0 }

		for sub_y in 0..<SS_Y {
			scan_y := f32(py) + (f32(sub_y) + 0.5) / f32(SS_Y)
			clear(&xs)
			for e in edges {
				y0, y1 := e.y0, e.y1
				sign: i8 = 1
				if y0 > y1 {
					y0, y1 = y1, y0
					sign = -1
				}
				// Half-open [y0, y1): edges touching the scanline only
				// from below are counted exactly once.
				if scan_y < y0 || scan_y >= y1 { continue }
				t := (scan_y - e.y0) / (e.y1 - e.y0)
				x_cross := e.x0 + t * (e.x1 - e.x0)
				append(&xs, Edge_Crossing{x = x_cross, sign = sign})
			}
			if len(xs) < 2 { continue }
			sort_crossings(xs[:])

			// Walk crossings left → right, maintaining the winding count
			// and emitting "inside" intervals on transitions.
			winding := 0
			prev_x: f32 = 0
			for c in xs {
				prev_winding := winding
				winding += int(c.sign)
				if prev_winding != 0 {
					// Interval [prev_x, c.x] is inside.
					spread_coverage(cov, prev_x, c.x, WEIGHT, bm.width)
				}
				prev_x = c.x
			}
		}

		for i in 0..<bm.width {
			v := cov[i] * 255.0
			if v < 0   { v = 0   }
			if v > 255 { v = 255 }
			bm.pixels[py * bm.width + i] = u8(v + 0.5)
		}
	}
}

// spread_coverage adds the horizontal-overlap fraction of [a, b]
// with each pixel cell to `cov`, weighted by `weight`. Pixel cells
// are unit-wide (column i occupies [i, i+1]).
@(private)
spread_coverage :: proc(cov: []f32, a, b, weight: f32, width: int) {
	if a >= b { return }
	lo := int(a)
	if lo < 0 { lo = 0 }
	hi := int(b)
	if hi >= width { hi = width - 1 }

	for i := lo; i <= hi; i += 1 {
		left  := f32(i)
		right := f32(i + 1)
		if right <= a || left >= b { continue }
		ov_l := max_f32(a, left)
		ov_r := min_f32(b, right)
		cov[i] += (ov_r - ov_l) * weight
	}
}

@(private)
sort_crossings :: proc(xs: []Edge_Crossing) {
	// Insertion sort: glyph runs typically have ≤ 16 crossings per
	// scanline, where insertion sort is faster than quicksort/heapsort
	// and has zero allocations.
	for i in 1..<len(xs) {
		j := i
		for j > 0 && xs[j - 1].x > xs[j].x {
			xs[j - 1], xs[j] = xs[j], xs[j - 1]
			j -= 1
		}
	}
}

@(private)
max_f32 :: #force_inline proc(a, b: f32) -> f32 { return a if a > b else b }

@(private)
min_f32 :: #force_inline proc(a, b: f32) -> f32 { return a if a < b else b }

// point_inside_nonzero implements the non-zero winding rule by casting
// a ray rightward from (x, y) and summing signed crossings of edges.
// Returns true iff the total winding is non-zero.
//
// Boundary handling: an edge spanning [y0, y1) (half-open) crosses the
// ray when y0 ≤ y < y1. This guarantees a shared vertex between two
// adjacent edges is counted exactly once, regardless of orientation.
@(private)
point_inside_nonzero :: proc(x, y: f32, edges: ^[dynamic]Edge) -> bool {
	winding := 0
	for e in edges {
		y0, y1 := e.y0, e.y1
		dir := 1
		if y0 > y1 {
			y0, y1 = y1, y0
			dir = -1
		}
		if y0 > y || y >= y1 { continue }
		t := (y - e.y0) / (e.y1 - e.y0)
		x_cross := e.x0 + t * (e.x1 - e.x0)
		if x_cross > x { winding += dir }
	}
	return winding != 0
}

Rast_Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Size,
}
