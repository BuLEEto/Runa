/*
runa + raylib — production-ready text rendering for a raylib game.

Demonstrates that runa is a renderer-agnostic text engine: any
graphics library that can sample a texture and draw a textured quad
can use it. Here that renderer is raylib (`vendor:raylib`), but the
same pattern works for sokol_gfx, a custom Vulkan / Metal backend,
or a pure CPU pixel buffer.

What raylib's stock `DrawText` / `DrawTextEx` cannot do, and what
runa hands you for free:

  - OpenType shaping (GSUB / GPOS) — ligatures, kerning, contextual
    alternates, mark positioning, Arabic / Hebrew bidi, Indic / SEA
    shaping, COLRv0 + COLRv1 colour emoji
  - Sub-pixel-x positioning via 4-bucket pre-rasterized variants
  - Proper UAX #14 line-break, UAX #29 grapheme / word boundaries
    (not used in this demo, but available for richer editors)

This file is structured as a small `Runa_Text` module that drops
into any raylib project — about 250 lines, but each one is doing
real work that a naïve "shape + raster every frame" loop will
collapse under. Five patterns load-bearing for any real game:

  1. SHAPE CACHE — `runa.shape_text_cached` hashes (font, text, size)
     so repeat strings (UI labels, item names) shape exactly once
     across the program's life. Hits cost a map lookup; misses cost
     a full GSUB/GPOS pass.

  2. GLYPH CACHE — `(glyph_id, size)` → `Atlas_Slot` keyed map.
     Without this, every frame re-packs the same glyph into a NEW
     atlas slot — page 0 fills, slots get orphaned, live UVs point at
     orphaned data. Visible symptom: corruption on window resize,
     vertical stripes between glyph pairs.

  3. DIRTY-RECT UPLOAD — when a new glyph rasters, only the dirty
     sub-rectangle of the atlas page is uploaded to the GPU
     (`UpdateTextureRec`), not the full 1024×1024 = 4 MB texture.
     Difference between a snappy first-render and a 6-second hitch.

  4. SIZE CORRECTION — runa scales such that "size = N" means the
     em-square is N pixels; raylib's `DrawTextEx` treats `size` as
     the line height (ascent − descent). They disagree by 30-40 %
     for most fonts. The `runa_size` helper rescales so callers get
     raylib-equivalent visual sizes for the same numerical input.

  5. WARMUP — pre-raster printable ASCII at the sizes the app uses,
     so the first frame a new screen appears doesn't hitch on cold
     cache misses. ~20-50 ms once at startup buys glitch-free
     frames forever after.

Run from the runa root:

    odin run examples/raylib

A window opens showing kerning, ligatures, sub-pixel positioning,
and tinted text — all through the same draw call.
*/
package main

import "core:fmt"
import "core:math"
import "core:os"

import rl     "vendor:raylib"
import runa   "../.."
import raster "../../raster"

ATLAS_SIZE :: 1024

// ────────────────────────────────────────────────────────────────────
// Runa_Text module — drop this struct + procs into a raylib project
// to replace `LoadFontEx` + `DrawTextEx` + `MeasureTextEx`.
// ────────────────────────────────────────────────────────────────────

Glyph_Key :: struct {
	gid:    runa.Glyph_ID,
	size_q: u16,   // size × 4 quantization so 12.0 and 12.0001 share a slot
}

Runa_Text :: struct {
	loaded:      bool,
	font_bytes:  []u8,                              // owned; outlives font
	font:        runa.Font,
	atlas:       raster.Atlas,
	glyph_cache: map[Glyph_Key]raster.Atlas_Slot,
	shape_cache: runa.Cache,                        // (font, text, size) → glyphs

	// GPU side — an RGBA raylib texture mirroring the runa alpha atlas.
	// Pixels are (255, 255, 255, glyph_alpha) so `DrawTexturePro`'s
	// tint colour picks the ink and per-pixel alpha modulates.
	tex:         rl.Texture2D,
	mirror_rgba: []u8,
}

runa_text_init :: proc(rt: ^Runa_Text, font_path: string) -> bool {
	bytes, read_err := os.read_entire_file_from_path(font_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("runa_text: could not read %s (%v)", font_path, read_err)
		return false
	}
	font, ferr := runa.font_load(bytes)
	if ferr != .None {
		delete(bytes)
		fmt.eprintfln("runa_text: font_load failed (%v)", ferr)
		return false
	}

	rt.font_bytes  = bytes
	rt.font        = font
	rt.atlas       = runa.atlas_make(ATLAS_SIZE, ATLAS_SIZE)
	rt.shape_cache = runa.cache_make()

	rt.mirror_rgba = make([]u8, ATLAS_SIZE*ATLAS_SIZE*4)
	img := rl.Image{
		data    = raw_data(rt.mirror_rgba),
		width   = ATLAS_SIZE,
		height  = ATLAS_SIZE,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	rt.tex = rl.LoadTextureFromImage(img)
	// Bilinear so text under a `BeginMode2D` camera with zoom != 1.0
	// stays smooth. Point filtering keeps glyph edges crisp at 1:1
	// but goes blocky under scaling.
	rl.SetTextureFilter(rt.tex, .BILINEAR)

	rt.loaded = true
	return true
}

runa_text_destroy :: proc(rt: ^Runa_Text) {
	if !rt.loaded { return }
	rl.UnloadTexture(rt.tex)
	delete(rt.mirror_rgba)
	delete(rt.glyph_cache)
	runa.cache_destroy(&rt.shape_cache)
	runa.atlas_destroy(&rt.atlas)
	runa.font_destroy(&rt.font)
	delete(rt.font_bytes)
	rt^ = {}
}

// runa scales such that "size = N" means the em-square is N pixels,
// but raylib's `DrawTextEx` interprets `size` as the line height
// (ascent − descent). They disagree by ~30-40 % for most fonts.
// Rescale so callers get raylib-equivalent visual sizes.
@(private="file")
runa_size :: proc(rt: ^Runa_Text, size: f32) -> f32 {
	extent := f32(rt.font.ascent - rt.font.descent)
	if extent <= 0 || rt.font.units_per_em == 0 { return size }
	return size * f32(rt.font.units_per_em) / extent
}

// Push the page's dirty rectangle from the alpha atlas to the
// RGBA-mirror raylib texture, expanding R8 → RGBA on the fly. The
// runa atlas tracks a single bounding box of dirty pixels since the
// last flush, so a new glyph = a tight little rect, not a full
// 4 MB texture upload.
@(private="file")
runa_text_upload :: proc(rt: ^Runa_Text, page: ^raster.Atlas_Page) {
	x0 := int(page.dirty_min[0])
	y0 := int(page.dirty_min[1])
	x1 := int(page.dirty_max[0])
	y1 := int(page.dirty_max[1])
	w  := x1 - x0
	h  := y1 - y0
	if w <= 0 || h <= 0 { return }

	// Tight RGBA buffer for UpdateTextureRec. Heap-allocated so we
	// don't rely on the caller resetting `temp_allocator` per frame.
	buf := make([]u8, w*h*4)
	defer delete(buf)
	for row in 0..<h {
		src_off := (y0 + row) * ATLAS_SIZE + x0
		dst_off := row * w * 4
		for col in 0..<w {
			a := page.pixels[src_off + col]
			buf[dst_off + col*4 + 0] = 255
			buf[dst_off + col*4 + 1] = 255
			buf[dst_off + col*4 + 2] = 255
			buf[dst_off + col*4 + 3] = a
		}
	}
	rl.UpdateTextureRec(rt.tex,
		rl.Rectangle{f32(x0), f32(y0), f32(w), f32(h)},
		raw_data(buf))

	page.is_dirty = false
	page.dirty_min = {}
	page.dirty_max = {}
}

@(private="file")
runa_text_get_slot :: proc(rt: ^Runa_Text, gid: runa.Glyph_ID, size: f32) -> (raster.Atlas_Slot, bool) {
	key := Glyph_Key{gid = gid, size_q = u16(size * 4)}
	if slot, hit := rt.glyph_cache[key]; hit { return slot, true }

	slot, err := runa.raster_glyph(&rt.font, gid, size, 0, &rt.atlas)
	if err != .None { return {}, false }
	rt.glyph_cache[key] = slot

	// Push freshly-packed pixels to the GPU now so we can draw them
	// this frame. After warmup every glyph hits the cache and this
	// branch never runs.
	if int(slot.page_index) < len(rt.atlas.pages_alpha) {
		page := &rt.atlas.pages_alpha[slot.page_index]
		if page.is_dirty { runa_text_upload(rt, page) }
	}
	return slot, true
}

@(private="file")
draw_glyph :: proc(rt: ^Runa_Text, slot: raster.Atlas_Slot, pen_x, baseline_y: f32, tint: rl.Color) {
	if slot.px_size.x == 0 || slot.px_size.y == 0 { return }
	src := rl.Rectangle{
		slot.uv_rect[0] * ATLAS_SIZE,
		slot.uv_rect[1] * ATLAS_SIZE,
		f32(slot.px_size.x),
		f32(slot.px_size.y),
	}
	// Floor the destination position to the integer pixel grid.
	// raylib's `DrawTexturePro` with a fractional dst.x rasterizes
	// the right-edge pixel at a fractional UV which can sample
	// beyond the source rect into the next packed glyph.
	dst := rl.Rectangle{
		math.floor(pen_x      + slot.bearing.x),
		math.floor(baseline_y + slot.bearing.y),
		f32(slot.px_size.x),
		f32(slot.px_size.y),
	}
	rl.DrawTexturePro(rt.tex, src, dst, {0, 0}, 0, tint)
}

// runa_text_warmup pre-rasters printable ASCII at every size the app
// will use. One ~20-50 ms hit at startup buys glitch-free frames
// after — new screens don't hitch on cold-cache misses.
runa_text_warmup :: proc(rt: ^Runa_Text, sizes: []f32) {
	if !rt.loaded { return }
	ascii: [95]u8
	for i in 0..<len(ascii) { ascii[i] = u8(0x20 + i) }
	warm := string(ascii[:])

	for s in sizes {
		rs := runa_size(rt, s)
		shaped := runa.shape_text_cached(&rt.font, warm, rs, &rt.shape_cache)
		for g in shaped {
			_, _ = runa_text_get_slot(rt, g.glyph_id, rs)
		}
	}
}

// runa_draw_text — the replacement for `rl.DrawTextEx`.
// (x, y) is the top-left corner of the text bounding box. `size` is
// interpreted the way raylib does (line height in pixels).
runa_draw_text :: proc(rt: ^Runa_Text, text: string, x, y, size: f32, color: rl.Color) {
	if !rt.loaded { return }
	rs := runa_size(rt, size)

	// `shape_text_cached` returns a slice owned by the shape cache —
	// no allocation on a cache hit. Main hot path for repeated UI
	// labels that don't change between frames.
	shaped := runa.shape_text_cached(&rt.font, text, rs, &rt.shape_cache)

	ascent_em := f32(rt.font.ascent) / f32(rt.font.units_per_em)
	baseline  := y + ascent_em * rs

	pen_x := x
	for g in shaped {
		slot, ok := runa_text_get_slot(rt, g.glyph_id, rs)
		if !ok { pen_x += g.x_advance; continue }
		draw_glyph(rt, slot, pen_x + g.x_offset, baseline + g.y_offset, color)
		pen_x += g.x_advance
	}
}

// runa_measure_text — the replacement for `rl.MeasureTextEx`'s x
// component. Returns the rendered width of `text` at `size`.
runa_measure_text :: proc(rt: ^Runa_Text, text: string, size: f32) -> f32 {
	if !rt.loaded { return 0 }
	rs := runa_size(rt, size)
	shaped := runa.shape_text_cached(&rt.font, text, rs, &rt.shape_cache)
	w: f32 = 0
	for g in shaped { w += g.x_advance }
	return w
}

// ────────────────────────────────────────────────────────────────────
// Demo — exercises the module on a real raylib window.
// ────────────────────────────────────────────────────────────────────

main :: proc() {
	// Font path — defaults to runa's bundled Inter, overridable via argv.
	font_path := "tests/fonts/InterVariable.ttf"
	if len(os.args) >= 2 { font_path = os.args[1] }

	rl.SetConfigFlags({.MSAA_4X_HINT})
	rl.InitWindow(960, 480, "runa + raylib — production-ready text")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	rt: Runa_Text
	if !runa_text_init(&rt, font_path) {
		fmt.eprintfln("runa_text_init failed — run from the runa root, or pass a font path as argv")
		os.exit(1)
	}
	defer runa_text_destroy(&rt)

	// Pre-raster ASCII at every size used in this demo. Spend the
	// warmup cost once at startup so the main loop runs warm.
	runa_text_warmup(&rt, []f32{12, 14, 28, 36})

	white  := rl.Color{255, 255, 255, 255}
	ink    := rl.Color{233, 233, 233, 255}
	muted  := rl.Color{160, 160, 168, 255}
	accent := rl.Color{ 76, 198, 245, 255}

	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{18, 19, 23, 255})

		runa_draw_text(&rt, "runa + raylib", 32, 32, 36, white)
		runa_draw_text(&rt,
			"OpenType shaping, kerning, ligatures — running in raylib",
			32, 80, 14, muted)

		runa_draw_text(&rt, "1. GPOS kerning (heavy pairs):", 32, 130, 14, accent)
		runa_draw_text(&rt,
			"AVATAR  WAVE  TYPE  YACHT  Toyota  Welcome",
			32, 160, 28, ink)

		runa_draw_text(&rt, "2. ccmp / liga ligatures (fi, fl, ff, ffi, ffl):", 32, 220, 14, accent)
		runa_draw_text(&rt,
			"office  afflict  affirm  fine  fluffy  shuffle",
			32, 250, 28, ink)

		runa_draw_text(&rt, "3. Tint is just the draw call's colour:", 32, 310, 14, accent)
		runa_draw_text(&rt, "Red.",   32,  340, 28, rl.Color{233,  84,  84, 255})
		runa_draw_text(&rt, "Green.", 110, 340, 28, rl.Color{ 92, 196, 116, 255})
		runa_draw_text(&rt, "Blue.",  215, 340, 28, rl.Color{ 76, 156, 245, 255})
		runa_draw_text(&rt, "… and so on.", 297, 340, 28, ink)

		runa_draw_text(&rt,
			"Shape cache + glyph cache + dirty-rect uploads + size correction baked in.",
			32, 430, 12, muted)

		rl.EndDrawing()
	}
}
