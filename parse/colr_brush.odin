package parse

// COLRv1 brush descriptors — a richer layer payload than the v0
// `Colr_Layer { glyph_id, palette_index }` shape. Each layer carries
// a `Colr_Brush` describing how to fill the glyph mask: solid colour,
// linear gradient, radial gradient, or sweep gradient. v0.5 supports
// solid + linear-gradient fills via the rasterizer; radial / sweep
// presently fall back to a solid first-stop colour (their geometry
// land alongside a follow-up raster pass).
//
// The parser's responsibilities are kept narrow: walk the COLRv1
// paint tree, project gradient endpoints + colour stops out into
// `Colr_Brush` values, and emit `(mask_glyph, brush)` pairs. The
// rasterizer translates those into pixels.
//
// Reference: OpenType COLR — Color Table §9 (formats 4 / 6 / 8 and
// ColorLine encoding).

import "core:mem"

// Color_Stop is one (offset, palette_index, alpha) record from a
// ColorLine. `offset` is in [0, 1]; `alpha` is the per-stop alpha
// multiplier on the palette colour (1.0 = use palette colour as-is).
Color_Stop :: struct {
	offset:        f32,
	palette_index: u16,
	alpha:         f32,
}

// Brush kind tag.
Brush_Kind :: enum u8 {
	Solid,                                              // single palette colour
	Linear,                                             // p0..p1 linear ramp + stops
	Radial,                                             // (c0,r0)..(c1,r1) — v0.5 falls back to first stop
	Sweep,                                              // center + start/end angle — v0.5 falls back to first stop
}

// Colr_Brush is the discriminated fill descriptor for one
// `Colr_Brush_Layer`. Endpoints are in font-design-unit coordinates;
// the rasterizer scales them into pixel space alongside the glyph
// outline.
Colr_Brush :: struct {
	kind:           Brush_Kind,
	// Solid: just `palette_index` (plus `alpha`). `stops` is empty.
	palette_index:  u16,                                // also stop[0].palette for gradients
	alpha:          f32,                                // pre-stop alpha multiplier (gradients: 1.0)

	// Linear / radial: two control points (font units, baseline-
	// relative).
	p0:             [2]f32,
	p1:             [2]f32,
	// Radial only: radii at p0 / p1.
	r0:             f32,
	r1:             f32,
	// Sweep only: angles in radians.
	angle_start:    f32,
	angle_end:      f32,

	// Color stops for gradients (sorted by `offset`). Empty for solid.
	// Memory owned by the caller of `colr_v1_brush_layers` via the
	// supplied allocator.
	stops:          []Color_Stop,
}

// Colr_Brush_Layer pairs a glyph mask with the brush that fills it
// plus the composite mode that controls how this layer combines with
// the canvas underneath. Defaults to SrcOver — every layer not inside
// a PaintComposite paint tree node composites that way, identical to
// the COLRv0 behaviour. PaintComposite sets the mode on its source
// side; the backdrop side stays at SrcOver.
//
// The list is back-to-front composite order, same as the v0
// `Colr_Layer` slice.
Colr_Brush_Layer :: struct {
	glyph_id:       Glyph_ID,
	brush:          Colr_Brush,
	composite_mode: u8,                                 // COMPOSITE_* constant; default SrcOver
}

// COLRv1 composite-mode constants per OpenType COLR spec.
COMPOSITE_CLEAR        :: u8(0)
COMPOSITE_SRC          :: u8(1)
COMPOSITE_DEST         :: u8(2)
COMPOSITE_SRC_OVER     :: u8(3)
COMPOSITE_DEST_OVER    :: u8(4)
COMPOSITE_SRC_IN       :: u8(5)
COMPOSITE_DEST_IN      :: u8(6)
COMPOSITE_SRC_OUT      :: u8(7)
COMPOSITE_DEST_OUT     :: u8(8)
COMPOSITE_SRC_ATOP     :: u8(9)
COMPOSITE_DEST_ATOP    :: u8(10)
COMPOSITE_XOR          :: u8(11)
COMPOSITE_PLUS         :: u8(12)
COMPOSITE_SCREEN       :: u8(13)
COMPOSITE_OVERLAY      :: u8(14)
COMPOSITE_DARKEN       :: u8(15)
COMPOSITE_LIGHTEN      :: u8(16)
COMPOSITE_COLOR_DODGE  :: u8(17)
COMPOSITE_COLOR_BURN   :: u8(18)
COMPOSITE_HARD_LIGHT   :: u8(19)
COMPOSITE_SOFT_LIGHT   :: u8(20)
COMPOSITE_DIFFERENCE   :: u8(21)
COMPOSITE_EXCLUSION    :: u8(22)
COMPOSITE_MULTIPLY     :: u8(23)
COMPOSITE_HSL_HUE      :: u8(24)
COMPOSITE_HSL_SAT      :: u8(25)
COMPOSITE_HSL_COLOR    :: u8(26)
COMPOSITE_HSL_LUM      :: u8(27)

// colr_v1_brush_layers walks the COLRv1 paint tree for `gid` and
// fills `out` with one `Colr_Brush_Layer` per leaf paint, preserving
// gradient geometry and stops. Returns false if `gid` isn't a v1
// base glyph; caller may then fall back to the simple
// `colr_v1_layers` flat-colour path.
//
// Each emitted layer's `stops` slice is allocated from `allocator`;
// caller frees with `colr_brush_layers_destroy`.
colr_v1_brush_layers :: proc(c: ^Colr, gid: Glyph_ID, out: ^[dynamic]Colr_Brush_Layer, allocator := context.allocator) -> bool {
	if c.version < 1 || c.base_glyph_list_off == 0 || c.v1_paint_count == 0 {
		return false
	}
	d := c.data
	bgl_off := c.base_glyph_list_off

	records_base := bgl_off + 4
	if u64(records_base) + u64(c.v1_paint_count) * 6 > u64(len(d)) { return false }

	lo, hi := 0, int(c.v1_paint_count)
	for lo < hi {
		mid := (lo + hi) / 2
		p := records_base + u32(mid) * 6
		g := u16(d[p])<<8 | u16(d[p + 1])
		switch {
		case u16(gid) == g:
			paint_rel := u32(d[p + 2])<<24 | u32(d[p + 3])<<16 |
			             u32(d[p + 4])<<8 | u32(d[p + 5])
			paint_abs := bgl_off + paint_rel
			ctx := Brush_Walk_Ctx{c = c, out = out, allocator = allocator, pending_composite = COMPOSITE_SRC_OVER}
			walk_brush(&ctx, paint_abs, 0xFFFF, 0)
			return true
		case u16(gid) < g:
			hi = mid
		case:
			lo = mid + 1
		}
	}
	return false
}

// colr_brush_layers_destroy frees per-layer stop slices and the
// outer dynamic array.
colr_brush_layers_destroy :: proc(layers: ^[dynamic]Colr_Brush_Layer, allocator := context.allocator) {
	for &lyr in layers {
		if lyr.brush.stops != nil { delete(lyr.brush.stops, allocator) }
	}
	delete(layers^)
	layers^ = nil
}

@(private)
Brush_Walk_Ctx :: struct {
	c:                ^Colr,
	out:              ^[dynamic]Colr_Brush_Layer,
	allocator:        mem.Allocator,
	pending_composite: u8,                              // composite mode to apply to next emitted layer
}

@(private)
walk_brush :: proc(ctx: ^Brush_Walk_Ctx, off: u32, pending_glyph: u16, depth: int) {
	if depth > COLRV1_MAX_DEPTH { return }
	d := ctx.c.data
	if u64(off) + 1 > u64(len(d)) { return }
	format := d[off]

	switch format {
	case PAINT_COLR_LAYERS:
		if u64(off) + 6 > u64(len(d)) { return }
		num_layers := d[off + 1]
		first_idx  := u32(d[off + 2])<<24 | u32(d[off + 3])<<16 |
		              u32(d[off + 4])<<8 | u32(d[off + 5])
		if ctx.c.layer_list_off == 0 { return }
		layer_base := ctx.c.layer_list_off + 4
		for i in 0..<int(num_layers) {
			lp := layer_base + (first_idx + u32(i)) * 4
			if u64(lp) + 4 > u64(len(d)) { return }
			rel := u32(d[lp])<<24 | u32(d[lp + 1])<<16 |
			       u32(d[lp + 2])<<8 | u32(d[lp + 3])
			child := ctx.c.layer_list_off + rel
			walk_brush(ctx, child, pending_glyph, depth + 1)
		}

	case PAINT_SOLID, PAINT_VAR_SOLID:
		if u64(off) + 5 > u64(len(d)) { return }
		palette := u16(d[off + 1])<<8 | u16(d[off + 2])
		alpha_raw := i16(u16(d[off + 3])<<8 | u16(d[off + 4]))
		emit_brush(ctx, pending_glyph, Colr_Brush{
			kind = .Solid,
			palette_index = palette,
			alpha = f32(alpha_raw) / 16384.0,
		})

	case PAINT_LINEAR_GRADIENT, PAINT_VAR_LINEAR_GRADIENT:
		// PaintLinearGradient: format u8, colorLine Offset24, x0/y0/x1/y1
		// FWord (i16, font units), x2/y2 FWord (rotation reference;
		// ignored — we treat the gradient as the (p0, p1) axis).
		if u64(off) + 14 > u64(len(d)) { return }
		colorline_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		x0 := f32(i16(u16(d[off + 4])<<8 | u16(d[off + 5])))
		y0 := f32(i16(u16(d[off + 6])<<8 | u16(d[off + 7])))
		x1 := f32(i16(u16(d[off + 8])<<8 | u16(d[off + 9])))
		y1 := f32(i16(u16(d[off + 10])<<8 | u16(d[off + 11])))
		stops := read_color_line(ctx, off + colorline_rel)
		if len(stops) > 0 {
			emit_brush(ctx, pending_glyph, Colr_Brush{
				kind  = .Linear,
				palette_index = stops[0].palette_index,
				alpha = 1.0,
				p0    = {x0, y0},
				p1    = {x1, y1},
				stops = stops,
			})
		}

	case PAINT_RADIAL_GRADIENT, PAINT_VAR_RADIAL_GRADIENT:
		// PaintRadialGradient: format u8, colorLine Offset24,
		// x0 FWord (i16), y0 FWord, radius0 UFWord (u16),
		// x1 FWord, y1 FWord, radius1 UFWord.
		if u64(off) + 16 > u64(len(d)) { return }
		colorline_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		x0 := f32(i16(u16(d[off + 4])<<8  | u16(d[off + 5])))
		y0 := f32(i16(u16(d[off + 6])<<8  | u16(d[off + 7])))
		r0 := f32(   u16(d[off + 8])<<8  | u16(d[off + 9]))
		x1 := f32(i16(u16(d[off + 10])<<8 | u16(d[off + 11])))
		y1 := f32(i16(u16(d[off + 12])<<8 | u16(d[off + 13])))
		r1 := f32(   u16(d[off + 14])<<8 | u16(d[off + 15]))
		stops := read_color_line(ctx, off + colorline_rel)
		if len(stops) > 0 {
			emit_brush(ctx, pending_glyph, Colr_Brush{
				kind  = .Radial,
				palette_index = stops[0].palette_index,
				alpha = 1.0,
				p0    = {x0, y0},
				p1    = {x1, y1},
				r0    = r0,
				r1    = r1,
				stops = stops,
			})
		}

	case PAINT_SWEEP_GRADIENT, PAINT_VAR_SWEEP_GRADIENT:
		// PaintSweepGradient: format u8, colorLine Offset24,
		// centerX FWord, centerY FWord, startAngle F2DOT14,
		// endAngle F2DOT14. Angles are stored as count-of-180-degrees
		// in F2DOT14, so the conversion is `raw / 16384.0 * pi`.
		if u64(off) + 12 > u64(len(d)) { return }
		colorline_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		cx := f32(i16(u16(d[off + 4])<<8 | u16(d[off + 5])))
		cy := f32(i16(u16(d[off + 6])<<8 | u16(d[off + 7])))
		start_raw := i16(u16(d[off + 8])<<8  | u16(d[off + 9]))
		end_raw   := i16(u16(d[off + 10])<<8 | u16(d[off + 11]))
		PI :: f32(3.14159265358979)
		start_angle := f32(start_raw) / 16384.0 * PI
		end_angle   := f32(end_raw)   / 16384.0 * PI
		stops := read_color_line(ctx, off + colorline_rel)
		if len(stops) > 0 {
			emit_brush(ctx, pending_glyph, Colr_Brush{
				kind  = .Sweep,
				palette_index = stops[0].palette_index,
				alpha = 1.0,
				p0    = {cx, cy},                 // center stored in p0
				angle_start = start_angle,
				angle_end   = end_angle,
				stops       = stops,
			})
		}

	case PAINT_GLYPH:
		if u64(off) + 6 > u64(len(d)) { return }
		paint_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		mask_glyph := u16(d[off + 4])<<8 | u16(d[off + 5])
		walk_brush(ctx, off + paint_rel, mask_glyph, depth + 1)

	case PAINT_COLR_GLYPH:
		if u64(off) + 3 > u64(len(d)) { return }
		ref_gid := u16(d[off + 1])<<8 | u16(d[off + 2])
		bgl_off := ctx.c.base_glyph_list_off
		records_base := bgl_off + 4
		lo, hi := 0, int(ctx.c.v1_paint_count)
		for lo < hi {
			mid := (lo + hi) / 2
			p := records_base + u32(mid) * 6
			g := u16(d[p])<<8 | u16(d[p + 1])
			switch {
			case ref_gid == g:
				paint_rel := u32(d[p + 2])<<24 | u32(d[p + 3])<<16 |
				             u32(d[p + 4])<<8 | u32(d[p + 5])
				walk_brush(ctx, bgl_off + paint_rel, pending_glyph, depth + 1)
				return
			case ref_gid < g: hi = mid
			case:             lo = mid + 1
			}
		}

	case PAINT_TRANSFORM, PAINT_VAR_TRANSFORM,
	     PAINT_TRANSLATE, PAINT_VAR_TRANSLATE,
	     PAINT_SCALE, PAINT_SCALE_VAR,
	     PAINT_SCALE_AROUND_CENTER, PAINT_VAR_SCALE_AROUND_CENTER,
	     PAINT_ROTATE, PAINT_VAR_ROTATE,
	     PAINT_ROTATE_AROUND_CENTER, PAINT_VAR_ROTATE_AROUND_CENTER,
	     PAINT_SKEW, PAINT_VAR_SKEW,
	     PAINT_SKEW_AROUND_CENTER, PAINT_VAR_SKEW_AROUND_CENTER:
		if u64(off) + 4 > u64(len(d)) { return }
		child_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		walk_brush(ctx, off + child_rel, pending_glyph, depth + 1)

	case PAINT_COMPOSITE:
		// PaintComposite: format u8, sourcePaint Offset24, mode u8,
		// backdropPaint Offset24. Composite the source onto the
		// backdrop using `mode`. We emit the backdrop with default
		// SrcOver, then prime `pending_composite` for the source's
		// next leaf-emission.
		if u64(off) + 8 > u64(len(d)) { return }
		src_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		mode    := d[off + 4]
		bd_rel  := u32(d[off + 5])<<16 | u32(d[off + 6])<<8 | u32(d[off + 7])
		walk_brush(ctx, off + bd_rel,  pending_glyph, depth + 1)
		prev_mode := ctx.pending_composite
		ctx.pending_composite = mode
		walk_brush(ctx, off + src_rel, pending_glyph, depth + 1)
		ctx.pending_composite = prev_mode
	}
}

@(private)
emit_brush :: proc(ctx: ^Brush_Walk_Ctx, mask_glyph: u16, b: Colr_Brush) {
	if mask_glyph == 0xFFFF {
		if b.stops != nil { delete(b.stops, ctx.allocator) }
		return
	}
	append(ctx.out, Colr_Brush_Layer{
		glyph_id       = Glyph_ID(mask_glyph),
		brush          = b,
		composite_mode = ctx.pending_composite,
	})
	// One emit consumes the pending composite mode — subsequent layers
	// at the same level default back to SrcOver.
	ctx.pending_composite = COMPOSITE_SRC_OVER
}

// read_color_line parses a ColorLine record at `abs_off`:
//   extend u8
//   numStops u16
//   colorStops[numStops] { stopOffset F2DOT14, paletteIndex u16, alpha F2DOT14 }
// Returns a freshly-allocated slice of `Color_Stop`s in ctx.allocator.
@(private)
read_color_line :: proc(ctx: ^Brush_Walk_Ctx, abs_off: u32) -> []Color_Stop {
	d := ctx.c.data
	if u64(abs_off) + 3 > u64(len(d)) { return nil }
	num_stops := int(u16(d[abs_off + 1])<<8 | u16(d[abs_off + 2]))
	if num_stops == 0 { return nil }
	stops_off := abs_off + 3
	stop_record_size := u32(6)
	if u64(stops_off) + u64(num_stops) * u64(stop_record_size) > u64(len(d)) { return nil }

	stops := make([]Color_Stop, num_stops, ctx.allocator)
	for i in 0..<num_stops {
		p := stops_off + u32(i) * stop_record_size
		offset_raw    := i16(u16(d[p])<<8     | u16(d[p + 1]))
		palette_index :=     u16(d[p + 2])<<8 | u16(d[p + 3])
		alpha_raw     := i16(u16(d[p + 4])<<8 | u16(d[p + 5]))
		stops[i] = Color_Stop{
			offset        = f32(offset_raw) / 16384.0,
			palette_index = palette_index,
			alpha         = f32(alpha_raw) / 16384.0,
		}
	}
	return stops
}
