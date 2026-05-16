/*
runa + raylib — proper text in ~50 lines of glue.

Demonstrates that runa is a renderer-agnostic text engine: any
graphics library that can sample a texture and draw a textured quad
can use it. Here that renderer is raylib (`vendor:raylib`), but the
same pattern works for sokol_gfx, a custom Vulkan / Metal backend,
or even a pure CPU pixel buffer.

What raylib's stock `DrawText` / `DrawTextEx` can NOT do, and what
runa hands you for free:

  - OpenType shaping (GSUB/GPOS) — ligatures, kerning, contextual
    alternates, marks, Arabic / Hebrew bidi, Indic / SEA shaping
  - COLRv0 and COLRv1 colour emoji with gradient fills
  - Sub-pixel-x positioning via 4-bucket pre-rasterized variants

The glue boils down to four ideas:

  1. `runa.shape_text` produces a `Shaped_Glyph` per output glyph
     (post-shaping — so ligatures are a single glyph, kerned pairs
     have correct advances, etc.).
  2. `runa.raster_glyph` rasterizes one glyph into a runa Atlas page
     and returns a slot with UVs + bearings.
  3. A small cache prevents re-packing the same glyph every frame.
  4. raylib's `DrawTexturePro` draws each shaped glyph as a textured
     quad. The atlas texture lives in a raylib `Texture2D` that we
     refresh with `UpdateTexture` after rastering new glyphs.

Run from the runa root:

    odin run examples/raylib

A window opens showing kerning, ligatures, and tinted text running
through the same draw call.
*/
package main

import "core:fmt"
import "core:math"
import "core:os"

import rl     "vendor:raylib"
import runa   "../.."
import raster "../../raster"

ATLAS_SIZE :: 1024

// Per-glyph cache key. Without this, every frame's `raster_glyph` call
// re-packs the same glyph into a new atlas slot — page 0 fills up,
// older slots get orphaned, and live UVs end up pointing at whatever
// got packed over them. Visible symptom: corruption on window resize,
// vertical stripes between glyph pairs.
Glyph_Key :: struct {
	gid:    runa.Glyph_ID,
	size_q: u16,        // size × 4 so 12.0 and 12.0001 share a slot
	subpx:  u8,
}

Glyph_Cache :: map[Glyph_Key]raster.Atlas_Slot

// Mirror of one runa alpha atlas page, expanded to RGBA so raylib can
// sample it as plain UNCOMPRESSED_R8G8B8A8. We keep R=G=B=255 and put
// the glyph alpha in A, so the `rl.DrawTexturePro` tint colour picks
// the ink colour at draw time and the per-pixel alpha modulates
// correctly.
RGBA_Mirror :: struct {
	tex:    rl.Texture2D,
	rgba:   []u8,
	w, h:   int,
}

mirror_make :: proc(w, h: int) -> RGBA_Mirror {
	rgba := make([]u8, w*h*4)
	img  := rl.Image{
		data    = raw_data(rgba),
		width   = i32(w),
		height  = i32(h),
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	tex := rl.LoadTextureFromImage(img)
	// Point (nearest-neighbour) sampling — bilinear would bleed
	// between adjacent atlas slots since runa packs glyphs flush
	// against each other with no padding.
	rl.SetTextureFilter(tex, .POINT)
	return RGBA_Mirror{tex = tex, rgba = rgba, w = w, h = h}
}

// Convert a runa alpha page (R8) into the RGBA mirror's pixel buffer
// and push it to the GPU.
mirror_upload_from_alpha :: proc(m: ^RGBA_Mirror, page: ^raster.Atlas_Page) {
	n := m.w * m.h
	for i in 0..<n {
		a := page.pixels[i]
		m.rgba[i*4 + 0] = 255
		m.rgba[i*4 + 1] = 255
		m.rgba[i*4 + 2] = 255
		m.rgba[i*4 + 3] = a
	}
	rl.UpdateTexture(m.tex, raw_data(m.rgba))
}

// One glyph → one textured quad in raylib coordinate space.
//
// Important: destination position is FLOORED to the integer pixel grid.
// Runa's subpixel-x positioning bakes the sub-pixel offset into the
// rasterized bitmap variant (selected via `subpx_x`), so the bitmap
// already contains the correct rendering for the fractional pen
// position — it just needs to be placed at the right integer pixel.
// Drawing at a fractional dst.x with raylib's DrawTexturePro otherwise
// causes the right-edge screen pixel to sample slightly beyond the
// source rect, picking up whatever atlas glyph was packed next to this
// one (visible as a single-pixel vertical stripe between glyph pairs).
draw_glyph :: proc(mirror: ^RGBA_Mirror, slot: raster.Atlas_Slot, pen_x, baseline_y: f32, tint: rl.Color) {
	if slot.px_size.x == 0 || slot.px_size.y == 0 { return }
	src := rl.Rectangle{
		slot.uv_rect[0] * f32(mirror.w),
		slot.uv_rect[1] * f32(mirror.h),
		f32(slot.px_size.x),
		f32(slot.px_size.y),
	}
	dst := rl.Rectangle{
		math.floor(pen_x      + slot.bearing.x),
		math.floor(baseline_y + slot.bearing.y),
		f32(slot.px_size.x),
		f32(slot.px_size.y),
	}
	rl.DrawTexturePro(mirror.tex, src, dst, {0, 0}, 0, tint)
}

// prefetch_text shapes the string and rasterizes every glyph into the
// atlas + glyph cache WITHOUT drawing. Call this at program start for
// every string you'll render so the main loop never hits a cache miss
// (which would force a 4 MB UpdateTexture inside the draw path).
prefetch_text :: proc(font: ^runa.Font, atlas: ^raster.Atlas, cache: ^Glyph_Cache,
                      text: string, size: f32) {
	shaped := make([dynamic]runa.Shaped_Glyph, 0, 64, context.temp_allocator)
	runa.shape_text(font, text, size, &shaped)
	pen_x: f32 = 0
	for g in shaped {
		frac    := pen_x - f32(int(pen_x))
		subpx_x := u8(int(frac * 4)) & 3
		key := Glyph_Key{
			gid    = g.glyph_id,
			size_q = u16(size * 4),
			subpx  = subpx_x,
		}
		if _, hit := cache[key]; !hit {
			s, err := runa.raster_glyph(font, g.glyph_id, size, subpx_x, atlas)
			if err == .None { cache[key] = s }
		}
		pen_x += g.x_advance
	}
}

// upload_dirty_pages flushes any pending atlas writes to the GPU mirror.
// Call once per frame (or after prefetch_text); after the warmup pass
// this is a no-op every frame.
upload_dirty_pages :: proc(atlas: ^raster.Atlas, mirror: ^RGBA_Mirror) {
	if len(atlas.pages_alpha) > 0 {
		page := &atlas.pages_alpha[0]
		if page.is_dirty {
			mirror_upload_from_alpha(mirror, page)
			page.is_dirty = false
			page.dirty_min = {}
			page.dirty_max = {}
		}
	}
}

// Shape + draw a single line. Glyphs are expected to already be in the
// cache (call `prefetch_text` for each string at startup). Returns the
// final pen_x so the caller can right-align / wrap if it wants.
draw_text_runa :: proc(font: ^runa.Font, atlas: ^raster.Atlas, cache: ^Glyph_Cache,
                       mirror: ^RGBA_Mirror,
                       text: string, size: f32, x, baseline_y: f32, tint: rl.Color) -> f32 {
	shaped := make([dynamic]runa.Shaped_Glyph, 0, 64, context.temp_allocator)
	runa.shape_text(font, text, size, &shaped)

	pen_x := x
	for g in shaped {
		frac    := pen_x - f32(int(pen_x))
		subpx_x := u8(int(frac * 4)) & 3
		key := Glyph_Key{
			gid    = g.glyph_id,
			size_q = u16(size * 4),
			subpx  = subpx_x,
		}
		// Lazy raster as a safety net for strings not prefetched. After
		// warmup this branch is dead code in the main loop.
		slot, hit := cache[key]
		if !hit {
			s, err := runa.raster_glyph(font, g.glyph_id, size, subpx_x, atlas)
			if err != .None { continue }
			cache[key] = s
			slot = s
		}
		draw_glyph(mirror, slot, pen_x + g.x_offset, baseline_y + g.y_offset, tint)
		pen_x += g.x_advance
	}
	return pen_x
}

main :: proc() {
	// Font path — defaults to runa's bundled Inter, overridable via argv.
	font_path := "tests/fonts/InterVariable.ttf"
	if len(os.args) >= 2 { font_path = os.args[1] }

	font_bytes, read_err := os.read_entire_file_from_path(font_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("failed to read %s — run from the runa root, or pass a font path as argv. (%v)", font_path, read_err)
		os.exit(1)
	}
	defer delete(font_bytes)

	font, font_err := runa.font_load(font_bytes)
	if font_err != .None {
		fmt.eprintfln("font_load: %v", font_err); os.exit(1)
	}
	defer runa.font_destroy(&font)

	rl.SetConfigFlags({.MSAA_4X_HINT})
	rl.InitWindow(960, 480, "runa + raylib — proper text in 50 lines of glue")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	atlas := runa.atlas_make(ATLAS_SIZE, ATLAS_SIZE)
	defer runa.atlas_destroy(&atlas)

	mirror := mirror_make(ATLAS_SIZE, ATLAS_SIZE)
	defer rl.UnloadTexture(mirror.tex)
	defer delete(mirror.rgba)

	cache: Glyph_Cache
	defer delete(cache)

	white  := rl.Color{255, 255, 255, 255}
	ink    := rl.Color{233, 233, 233, 255}
	muted  := rl.Color{160, 160, 168, 255}
	accent := rl.Color{ 76, 198, 245, 255}

	// ── warmup: prefetch every string at every size we'll render ──
	// Atlas + cache get populated up front, then ONE texture upload
	// pushes the whole page to the GPU. Without this the main loop
	// would do an UpdateTexture per glyph cache-miss on frame 1
	// (4 MB × ~150 glyphs = multi-second freeze).
	prefetch_text(&font, &atlas, &cache, "runa + raylib", 36)
	prefetch_text(&font, &atlas, &cache,
		"OpenType shaping, kerning, ligatures — running in raylib", 14)
	prefetch_text(&font, &atlas, &cache, "GPOS kerning (heavy pairs):", 14)
	prefetch_text(&font, &atlas, &cache,
		"AVATAR  WAVE  TYPE  YACHT  Toyota  Welcome", 28)
	prefetch_text(&font, &atlas, &cache,
		"ccmp / liga ligatures (fi, fl, ff, ffi, ffl):", 14)
	prefetch_text(&font, &atlas, &cache,
		"office  afflict  affirm  fine  fluffy  shuffle", 28)
	prefetch_text(&font, &atlas, &cache,
		"Tint is just the draw call's colour — no extra setup:", 14)
	prefetch_text(&font, &atlas, &cache, "Red.",   24)
	prefetch_text(&font, &atlas, &cache, "Green.", 24)
	prefetch_text(&font, &atlas, &cache, "Blue.",  24)
	prefetch_text(&font, &atlas, &cache, "… and so on.", 24)
	prefetch_text(&font, &atlas, &cache,
		"~50 lines of glue. Atlas mirrors a raylib RGBA texture; runa shapes + rasterizes.",
		12)
	upload_dirty_pages(&atlas, &mirror)
	free_all(context.temp_allocator)

	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{18, 19, 23, 255})

		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"runa + raylib", 36, 32, 60, white)
		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"OpenType shaping, kerning, ligatures — running in raylib",
			14, 32, 90, muted)

		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"GPOS kerning (heavy pairs):", 14, 32, 145, accent)
		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"AVATAR  WAVE  TYPE  YACHT  Toyota  Welcome",
			28, 32, 185, ink)

		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"ccmp / liga ligatures (fi, fl, ff, ffi, ffl):", 14, 32, 240, accent)
		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"office  afflict  affirm  fine  fluffy  shuffle",
			28, 32, 280, ink)

		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"Tint is just the draw call's colour — no extra setup:", 14, 32, 335, accent)
		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"Red.",   24, 32,  370, rl.Color{233,  84,  84, 255})
		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"Green.", 24, 96,  370, rl.Color{ 92, 196, 116, 255})
		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"Blue.",  24, 192, 370, rl.Color{ 76, 156, 245, 255})
		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"… and so on.", 24, 260, 370, ink)

		_ = draw_text_runa(&font, &atlas, &cache, &mirror,
			"~50 lines of glue. Atlas mirrors a raylib RGBA texture; runa shapes + rasterizes.",
			12, 32, 440, muted)

		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}
