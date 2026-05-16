package raster

// color.odin — COLRv0 composite rasterizer.
//
// Takes a list of COLR layers + a CPAL palette + an outline source
// (`glyf` / `loca`) and produces a single RGBA bitmap. Each layer is
// one monochrome glyph filled with one palette colour, composited
// back-to-front using straight-alpha OVER.
//
// The output is in the same coordinate system as the monochrome
// `rasterize` procedure: y-down, baseline-relative via the returned
// (x_offset, y_offset).
//
// COLRv1 gradient brushes are deferred to v0.5; this pass is the
// "flat layered" pipeline every modern emoji font ships as fallback.

import "../parse"

// Color_Bitmap is a CPU-side RGBA8 image — four bytes per pixel,
// straight-alpha (NOT premultiplied) so the consumer can hand it to
// any GPU pipeline.
Color_Bitmap :: struct {
	width:  int,
	height: int,
	pixels: []u8,                                // RGBA, row-major
}

color_bitmap_destroy :: proc(b: ^Color_Bitmap, allocator := context.allocator) {
	delete(b.pixels, allocator)
	b^ = {}
}

// rasterize_colr_layers composites every COLR layer of one base glyph
// into an RGBA bitmap. `layers` are the parsed layer records for the
// base glyph; `palette_idx` selects which CPAL palette to read tints
// from; `foreground` is the colour substituted for layers whose
// `palette_index` equals `parse.COLR_FOREGROUND_PALETTE_INDEX` (text
// colour, in caller terms).
//
// Reuses `edges` across layer rasterizations to amortise allocations.
rasterize_colr_layers :: proc(
	layers:       []parse.Colr_Layer,
	palette:      ^parse.Cpal,
	palette_idx:  u16,
	foreground:   [4]u8,
	glyf:         ^parse.Glyf,
	loca:         ^parse.Loca,
	units_per_em: u16,
	size:         f32,
	edges:        ^[dynamic]Edge,
	allocator := context.allocator,
) -> (bm: Color_Bitmap, x_offset, y_offset: int, err: Rast_Error) {

	if size <= 0 || units_per_em == 0 { err = .Invalid_Size; return }
	if len(layers) == 0 { return }

	// Stage 1: rasterize each layer to an alpha bitmap. Keep them all
	// in memory so stage 2 can composite onto a union-bbox canvas.
	Layer_Render :: struct {
		bitmap:        Bitmap,
		x_off, y_off:  int,
		color:         [4]u8,
	}
	renders := make([dynamic]Layer_Render, 0, len(layers), context.temp_allocator)

	defer {
		for &r in renders {
			bitmap_destroy(&r.bitmap, allocator)
		}
	}

	outline := parse.Outline{}
	defer parse.outline_destroy(&outline)

	for lyr in layers {
		oerr := parse.glyf_outline(glyf, loca, lyr.glyph_id, &outline)
		if oerr != .None { continue }
		if len(outline.contour_ends) == 0 { continue }

		layer_bm, xo, yo, rerr := rasterize(&outline, units_per_em, size, edges, allocator = allocator)
		if rerr != .None { continue }
		if layer_bm.width == 0 || layer_bm.height == 0 {
			bitmap_destroy(&layer_bm, allocator)
			continue
		}

		col := foreground
		if lyr.palette_index != parse.COLR_FOREGROUND_PALETTE_INDEX {
			c := parse.cpal_lookup(palette, palette_idx, lyr.palette_index)
			col = [4]u8{c.r, c.g, c.b, c.a}
		}

		append(&renders, Layer_Render{bitmap = layer_bm, x_off = xo, y_off = yo, color = col})
	}

	if len(renders) == 0 { return }

	// Stage 2: union-bbox the layer placements.
	x_min, y_min := renders[0].x_off, renders[0].y_off
	x_max := renders[0].x_off + renders[0].bitmap.width
	y_max := renders[0].y_off + renders[0].bitmap.height
	for r in renders {
		if r.x_off                  < x_min { x_min = r.x_off }
		if r.y_off                  < y_min { y_min = r.y_off }
		if r.x_off + r.bitmap.width > x_max { x_max = r.x_off + r.bitmap.width }
		if r.y_off + r.bitmap.height > y_max { y_max = r.y_off + r.bitmap.height }
	}

	width  := x_max - x_min
	height := y_max - y_min
	if width <= 0 || height <= 0 { return }

	canvas := make([]u8, width * height * 4, allocator)
	if canvas == nil { err = .Out_Of_Memory; return }
	bm = Color_Bitmap{width = width, height = height, pixels = canvas}
	x_offset, y_offset = x_min, y_min

	// Stage 3: composite back-to-front, straight-alpha OVER.
	for r in renders {
		dx := r.x_off - x_min
		dy := r.y_off - y_min
		for sy in 0..<r.bitmap.height {
			ty := dy + sy
			if ty < 0 || ty >= height { continue }
			for sx in 0..<r.bitmap.width {
				tx := dx + sx
				if tx < 0 || tx >= width { continue }
				mask := r.bitmap.pixels[sy * r.bitmap.width + sx]
				if mask == 0 { continue }

				// Source alpha = layer-colour alpha × mask coverage.
				src_a := f32(r.color[3]) * f32(mask) / (255.0 * 255.0)
				idx := (ty * width + tx) * 4
				dst_a := f32(canvas[idx + 3]) / 255.0
				out_a := src_a + dst_a * (1.0 - src_a)
				if out_a > 0 {
					sr := f32(r.color[0]) / 255.0
					sg := f32(r.color[1]) / 255.0
					sb := f32(r.color[2]) / 255.0
					dr := f32(canvas[idx + 0]) / 255.0
					dg := f32(canvas[idx + 1]) / 255.0
					db := f32(canvas[idx + 2]) / 255.0
					or := (sr * src_a + dr * dst_a * (1.0 - src_a)) / out_a
					og := (sg * src_a + dg * dst_a * (1.0 - src_a)) / out_a
					ob := (sb * src_a + db * dst_a * (1.0 - src_a)) / out_a
					canvas[idx + 0] = u8(or * 255.0 + 0.5)
					canvas[idx + 1] = u8(og * 255.0 + 0.5)
					canvas[idx + 2] = u8(ob * 255.0 + 0.5)
					canvas[idx + 3] = u8(out_a * 255.0 + 0.5)
				}
			}
		}
	}
	return
}
