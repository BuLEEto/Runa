package parse

// COLRv1 paint-tree walker.
//
// v0.5 supports the paint formats most modern colour fonts ship —
// solid fills, layer stacks, glyph masks, and a flat-colour
// approximation of linear / radial / sweep gradients. Transforms
// and composition modes are walked but treated as pass-through:
// the child paint produces the layer; the transform / mode is
// dropped. This is a known-lossy v0.5 first pass — true gradient
// rasterization arrives in a follow-up.
//
// The walker emits a slice of `Colr_Layer { glyph_id, palette_index }`
// that the existing v0 rasterizer consumes, so callers get a
// uniform output shape regardless of which COLR generation a font
// targets.
//
// References: OpenType spec, "COLR — Color Table" §9.

// COLRv1 paint formats (subset).
PAINT_COLR_LAYERS     :: u8(1)
PAINT_SOLID           :: u8(2)
PAINT_VAR_SOLID       :: u8(3)
PAINT_LINEAR_GRADIENT :: u8(4)
PAINT_VAR_LINEAR_GRADIENT :: u8(5)
PAINT_RADIAL_GRADIENT :: u8(6)
PAINT_VAR_RADIAL_GRADIENT :: u8(7)
PAINT_SWEEP_GRADIENT  :: u8(8)
PAINT_VAR_SWEEP_GRADIENT :: u8(9)
PAINT_GLYPH           :: u8(10)
PAINT_COLR_GLYPH      :: u8(11)
PAINT_TRANSFORM       :: u8(12)
PAINT_VAR_TRANSFORM   :: u8(13)
PAINT_TRANSLATE       :: u8(14)
PAINT_VAR_TRANSLATE   :: u8(15)
PAINT_SCALE           :: u8(16)
PAINT_SCALE_VAR       :: u8(17)
PAINT_SCALE_AROUND_CENTER :: u8(18)
PAINT_VAR_SCALE_AROUND_CENTER :: u8(19)
PAINT_ROTATE          :: u8(20)
PAINT_VAR_ROTATE      :: u8(21)
PAINT_ROTATE_AROUND_CENTER :: u8(22)
PAINT_VAR_ROTATE_AROUND_CENTER :: u8(23)
PAINT_SKEW            :: u8(24)
PAINT_VAR_SKEW        :: u8(25)
PAINT_SKEW_AROUND_CENTER :: u8(26)
PAINT_VAR_SKEW_AROUND_CENTER :: u8(27)
PAINT_COMPOSITE       :: u8(32)

// Max recursion depth in the paint tree — spec caps at 64 for
// PaintColrGlyph cycles; pick something comfortable above that.
@(private)
COLRV1_MAX_DEPTH :: 64

// colr_v1_layers walks the BaseGlyphList for `gid`, flattens the
// paint tree, and appends one `Colr_Layer` per leaf into `out`.
// Caller clears / reuses the dynamic array. Returns false if `gid`
// isn't a v1 base glyph (caller should try v0 baseGlyphRecords
// instead).
colr_v1_layers :: proc(c: ^Colr, gid: Glyph_ID, out: ^[dynamic]Colr_Layer) -> bool {
	if c.version < 1 || c.base_glyph_list_off == 0 || c.v1_paint_count == 0 {
		return false
	}
	d := c.data
	bgl_off := c.base_glyph_list_off

	// Binary search the BaseGlyphList for `gid`. Records are sorted
	// by glyph ID per spec; each is 6 bytes (gid u16, paintOffset
	// Offset32 from BaseGlyphList start).
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
			ctx := V1_Walk_Ctx{c = c, out = out}
			walk_paint(&ctx, paint_abs, 0xFFFF, 0)
			return true
		case u16(gid) < g:
			hi = mid
		case:
			lo = mid + 1
		}
	}
	return false
}

@(private)
V1_Walk_Ctx :: struct {
	c:           ^Colr,
	out:         ^[dynamic]Colr_Layer,
	// `pending_glyph` is the glyph id the next leaf paint should
	// stencil into. PaintGlyph sets it before recursing into its
	// child paint; PaintSolid / gradient leaves consume it when they
	// emit a Colr_Layer. 0xFFFF means "no mask glyph" — the leaf is
	// inside a transform / composite chain with no surrounding
	// PaintGlyph, so we have no shape to attach colour to and skip.
	pending_glyph: u16,
}

@(private)
walk_paint :: proc(ctx: ^V1_Walk_Ctx, off: u32, pending_glyph: u16, depth: int) {
	if depth > COLRV1_MAX_DEPTH { return }
	d := ctx.c.data
	if u64(off) + 1 > u64(len(d)) { return }
	format := d[off]

	switch format {
	case PAINT_COLR_LAYERS:
		// numLayers u8, firstLayerIndex u32
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
			walk_paint(ctx, child, pending_glyph, depth + 1)
		}

	case PAINT_SOLID, PAINT_VAR_SOLID:
		// paletteIndex u16, alpha F2DOT14 (we keep alpha for the
		// raster's compositing pipeline; the index is what selects
		// the colour from CPAL).
		if u64(off) + 3 > u64(len(d)) { return }
		palette := u16(d[off + 1])<<8 | u16(d[off + 2])
		emit_layer(ctx, pending_glyph, palette)

	case PAINT_LINEAR_GRADIENT, PAINT_VAR_LINEAR_GRADIENT,
	     PAINT_RADIAL_GRADIENT, PAINT_VAR_RADIAL_GRADIENT,
	     PAINT_SWEEP_GRADIENT, PAINT_VAR_SWEEP_GRADIENT:
		// Approximate gradient as a solid using the FIRST color stop's
		// palette index. The actual gradient rasterization is a v0.6
		// feature; this fallback at least gives recognizable colour.
		// Each gradient's payload starts with a ColorLine offset
		// (Offset24 from the paint start). Inside ColorLine: extend
		// u8, numStops u16, then stops { stopOffset F2DOT14, palette
		// u16, alpha F2DOT14 }.
		if u64(off) + 4 > u64(len(d)) { return }
		colorline_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		cl_off := off + colorline_rel
		if u64(cl_off) + 3 > u64(len(d)) { return }
		// extend at +0, numStops at +1.
		num_stops := u16(d[cl_off + 1])<<8 | u16(d[cl_off + 2])
		if num_stops == 0 { return }
		// First stop record: stopOffset F2DOT14 (2 bytes), palette u16, alpha F2DOT14.
		stop_off := cl_off + 3
		if u64(stop_off) + 6 > u64(len(d)) { return }
		palette := u16(d[stop_off + 2])<<8 | u16(d[stop_off + 3])
		emit_layer(ctx, pending_glyph, palette)

	case PAINT_GLYPH:
		// paintOffset Offset24, glyphID u16
		if u64(off) + 6 > u64(len(d)) { return }
		paint_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		mask_glyph := u16(d[off + 4])<<8 | u16(d[off + 5])
		child := off + paint_rel
		walk_paint(ctx, child, mask_glyph, depth + 1)

	case PAINT_COLR_GLYPH:
		// glyphID u16 — recurse into another base glyph's paint tree.
		if u64(off) + 3 > u64(len(d)) { return }
		ref_gid := u16(d[off + 1])<<8 | u16(d[off + 2])
		// We can't easily call colr_v1_layers from here without
		// inviting infinite recursion via cycles. Instead we look up
		// the referenced glyph's paint offset and walk it inline,
		// using the depth counter as our cycle guard.
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
				walk_paint(ctx, bgl_off + paint_rel, pending_glyph, depth + 1)
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
		// Transforms have a child Paint at +1..+3 (Offset24). Drop the
		// transform itself and recurse — the layer is still emitted
		// with its glyph mask, just without the transform applied.
		if u64(off) + 4 > u64(len(d)) { return }
		child_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		walk_paint(ctx, off + child_rel, pending_glyph, depth + 1)

	case PAINT_COMPOSITE:
		// source paint at +1..+3, mode u8 at +4, backdrop paint at
		// +5..+7. We treat composites by drawing backdrop then
		// source — the v0.5 atlas pipeline doesn't expose blend
		// modes, so the source-over default approximates most cases.
		if u64(off) + 8 > u64(len(d)) { return }
		src_rel := u32(d[off + 1])<<16 | u32(d[off + 2])<<8 | u32(d[off + 3])
		bd_rel  := u32(d[off + 5])<<16 | u32(d[off + 6])<<8 | u32(d[off + 7])
		walk_paint(ctx, off + bd_rel,  pending_glyph, depth + 1)
		walk_paint(ctx, off + src_rel, pending_glyph, depth + 1)

	case:
		// Unknown / unhandled paint format. Skip without emitting.
	}
}

@(private)
emit_layer :: proc(ctx: ^V1_Walk_Ctx, mask_glyph, palette: u16) {
	if mask_glyph == 0xFFFF { return }
	append(ctx.out, Colr_Layer{glyph_id = Glyph_ID(mask_glyph), palette_index = palette})
}
