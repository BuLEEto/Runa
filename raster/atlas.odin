/*
Atlas allocator — bin-packs rasterized glyph bitmaps into shared
texture pages so the consumer (Skald, a custom Vulkan backend, …)
uploads each page once and samples many glyphs from it.

Packing strategy: simple shelf packing. Each page tracks a list of
horizontal shelves; a new slot lands on the first shelf with enough
remaining width and ≥ slot height. If no shelf fits, a new shelf is
opened at the current y. If the page itself can't host another
shelf, a new page is created.

Shelf packing is what stb_truetype, fontstash, and HarfBuzz use for
this exact workload — fast, no fragmentation worth worrying about
for glyph atlases, dead simple.

v0.1 supports both 8-bit alpha (mono glyphs) and RGBA (COLR layered
emoji) pages. They live in separate page lists because GPU sampler
binding differs and the consumer typically wants two textures.
*/
package raster

import "core:mem"

// Atlas_Format selects the per-pixel layout for a page.
Atlas_Format :: enum u8 {
	Alpha8,    // 1 byte/pixel (mono glyphs)
	RGBA8,     // 4 bytes/pixel (COLR / SVG / sbix)
}

// Atlas_Page is one fixed-size bitmap. The pixel buffer is owned by
// the page (and by extension the Atlas). Consumers read `pixels`
// directly and upload to GPU; `dirty_rect` indicates the smallest
// rectangle that's changed since the last `atlas_flush_dirty` call.
Atlas_Page :: struct {
	width:      u16,
	height:     u16,
	format:     Atlas_Format,
	pixels:     []u8,

	// Shelf-packing state.
	shelves:    [dynamic]Shelf,

	// Smallest dirty rect since last flush; (0,0,0,0) means clean.
	dirty_min:  [2]u16,
	dirty_max:  [2]u16,
	is_dirty:   bool,
}

@(private)
Shelf :: struct {
	y:        u16,
	height:   u16,
	x_cursor: u16,        // first free x on this shelf
}

// Atlas_Slot describes where a packed glyph lives.
//
//   page_index   index into Atlas.pages_alpha or .pages_color, per is_color.
//   uv_rect      {u0, v0, u1, v1} in 0..1 space relative to the page.
//   px_size      glyph bitmap dimensions in pixels.
//   bearing      offset from pen position to the slot's top-left
//                (matches `rasterize`'s x_offset / y_offset).
//   is_color     true → look up in pages_color, alpha pages otherwise.
Atlas_Slot :: struct {
	page_index: u16,
	uv_rect:    [4]f32,
	px_size:    [2]u16,
	bearing:    [2]f32,
	is_color:   bool,
}

// Atlas is the top-level container. `pages_alpha` and `pages_color`
// are pre-allocated growable arrays; the allocator at construction
// time owns every page's pixel buffer.
Atlas :: struct {
	allocator:    mem.Allocator,
	page_w:       u16,
	page_h:       u16,
	pages_alpha:  [dynamic]Atlas_Page,
	pages_color:  [dynamic]Atlas_Page,
}

// Atlas_Error covers the failure modes specific to atlas operations.
// `Slot_Too_Large` means the glyph is bigger than a single page can
// hold — caller should grow `page_w` / `page_h` or render the glyph
// without atlas backing.
Atlas_Error :: enum u8 {
	None,
	Out_Of_Memory,
	Slot_Too_Large,
}

// atlas_make allocates a new Atlas with `page_w × page_h` pages. The
// canonical sizing on modern GPUs is 1024 or 2048 — large enough for
// dozens of body-size glyphs per page, small enough to fit in any
// texture binding.
atlas_make :: proc(page_w, page_h: u16, allocator := context.allocator) -> Atlas {
	return Atlas{
		allocator   = allocator,
		page_w      = page_w,
		page_h      = page_h,
		pages_alpha = make([dynamic]Atlas_Page, 0, 1, allocator),
		pages_color = make([dynamic]Atlas_Page, 0, 1, allocator),
	}
}

atlas_destroy :: proc(a: ^Atlas) {
	for &p in a.pages_alpha { atlas_page_destroy(&p, a.allocator) }
	for &p in a.pages_color { atlas_page_destroy(&p, a.allocator) }
	delete(a.pages_alpha)
	delete(a.pages_color)
	a^ = {}
}

@(private)
atlas_page_destroy :: proc(p: ^Atlas_Page, allocator: mem.Allocator) {
	delete(p.pixels, allocator)
	delete(p.shelves)
	p^ = {}
}

// atlas_pack_alpha copies an 8-bit alpha bitmap into the atlas and
// returns the resulting slot. Allocates a new page if no existing
// page has room.
atlas_pack_alpha :: proc(a: ^Atlas, src: []u8, w, h: u16, bearing: [2]f32) -> (slot: Atlas_Slot, err: Atlas_Error) {
	if int(w) > int(a.page_w) || int(h) > int(a.page_h) {
		err = .Slot_Too_Large
		return
	}
	return atlas_pack(a, src, w, h, bearing, .Alpha8)
}

// atlas_pack_rgba is the colour-glyph variant of `atlas_pack_alpha`;
// `src` is laid out RGBA, row-major.
atlas_pack_rgba :: proc(a: ^Atlas, src: []u8, w, h: u16, bearing: [2]f32) -> (slot: Atlas_Slot, err: Atlas_Error) {
	if int(w) > int(a.page_w) || int(h) > int(a.page_h) {
		err = .Slot_Too_Large
		return
	}
	return atlas_pack(a, src, w, h, bearing, .RGBA8)
}

@(private)
atlas_pack :: proc(a: ^Atlas, src: []u8, w, h: u16, bearing: [2]f32, format: Atlas_Format) -> (slot: Atlas_Slot, err: Atlas_Error) {
	pages: ^[dynamic]Atlas_Page = format == .Alpha8 ? &a.pages_alpha : &a.pages_color
	is_color := format == .RGBA8

	// Try existing pages.
	for i in 0..<len(pages) {
		if x, y, ok := page_try_pack(&pages[i], w, h); ok {
			page_copy_into(&pages[i], src, w, h, x, y)
			slot = atlas_slot_make(u16(i), pages[i].width, pages[i].height, x, y, w, h, bearing, is_color)
			return
		}
	}

	// All full — allocate a new page.
	page, perr := atlas_page_make(a.page_w, a.page_h, format, a.allocator)
	if perr != .None { err = perr; return }
	append(pages, page)
	new_idx := len(pages) - 1

	x, y, ok := page_try_pack(&pages[new_idx], w, h)
	if !ok { err = .Out_Of_Memory; return }
	page_copy_into(&pages[new_idx], src, w, h, x, y)
	slot = atlas_slot_make(u16(new_idx), pages[new_idx].width, pages[new_idx].height, x, y, w, h, bearing, is_color)
	return
}

@(private)
atlas_page_make :: proc(w, h: u16, format: Atlas_Format, allocator: mem.Allocator) -> (Atlas_Page, Atlas_Error) {
	bpp := 1 if format == .Alpha8 else 4
	pixels := make([]u8, int(w) * int(h) * bpp, allocator)
	if pixels == nil { return Atlas_Page{}, .Out_Of_Memory }
	return Atlas_Page{
		width   = w,
		height  = h,
		format  = format,
		pixels  = pixels,
		shelves = make([dynamic]Shelf, 0, 8),
	}, .None
}

@(private)
page_try_pack :: proc(p: ^Atlas_Page, w, h: u16) -> (x, y: u16, ok: bool) {
	// First try existing shelves.
	for &s in p.shelves {
		if s.height >= h && int(s.x_cursor) + int(w) <= int(p.width) {
			x = s.x_cursor
			y = s.y
			s.x_cursor += w
			return x, y, true
		}
	}
	// New shelf at the bottom.
	next_y: u16 = 0
	if len(p.shelves) > 0 {
		last := p.shelves[len(p.shelves) - 1]
		next_y = last.y + last.height
	}
	if int(next_y) + int(h) > int(p.height) { return 0, 0, false }
	append(&p.shelves, Shelf{y = next_y, height = h, x_cursor = w})
	return 0, next_y, true
}

@(private)
page_copy_into :: proc(p: ^Atlas_Page, src: []u8, w, h, x, y: u16) {
	bpp := 1 if p.format == .Alpha8 else 4
	row_bytes := int(w) * bpp
	for sy in 0..<int(h) {
		dst_off := (int(y) + sy) * int(p.width) * bpp + int(x) * bpp
		src_off := sy * row_bytes
		copy(p.pixels[dst_off:dst_off + row_bytes], src[src_off:src_off + row_bytes])
	}
	// Track dirty bbox for incremental upload.
	mark_dirty(p, x, y, w, h)
}

@(private)
mark_dirty :: proc(p: ^Atlas_Page, x, y, w, h: u16) {
	x1 := x + w
	y1 := y + h
	if !p.is_dirty {
		p.dirty_min = [2]u16{x, y}
		p.dirty_max = [2]u16{x1, y1}
		p.is_dirty = true
		return
	}
	if x < p.dirty_min[0]  { p.dirty_min[0] = x  }
	if y < p.dirty_min[1]  { p.dirty_min[1] = y  }
	if x1 > p.dirty_max[0] { p.dirty_max[0] = x1 }
	if y1 > p.dirty_max[1] { p.dirty_max[1] = y1 }
}

@(private)
atlas_slot_make :: proc(page_idx: u16, page_w, page_h, x, y, w, h: u16, bearing: [2]f32, is_color: bool) -> Atlas_Slot {
	return Atlas_Slot{
		page_index = page_idx,
		uv_rect    = [4]f32{
			f32(x)         / f32(page_w),
			f32(y)         / f32(page_h),
			f32(x + w)     / f32(page_w),
			f32(y + h)     / f32(page_h),
		},
		px_size  = [2]u16{w, h},
		bearing  = bearing,
		is_color = is_color,
	}
}

// atlas_flush_dirty clears every page's dirty bbox. Call after the
// consumer has uploaded the bbox-sized region to the GPU. Returns the
// list of dirty bboxes the consumer should re-upload — one per page
// that was actually dirty.
Atlas_Dirty :: struct {
	page_index: u16,
	is_color:   bool,
	x, y:       u16,
	w, h:       u16,
}

atlas_flush_dirty :: proc(a: ^Atlas, allocator := context.allocator) -> []Atlas_Dirty {
	out := make([dynamic]Atlas_Dirty, 0, len(a.pages_alpha) + len(a.pages_color), allocator)
	for &p, i in a.pages_alpha {
		if !p.is_dirty { continue }
		append(&out, Atlas_Dirty{
			page_index = u16(i), is_color = false,
			x = p.dirty_min[0], y = p.dirty_min[1],
			w = p.dirty_max[0] - p.dirty_min[0],
			h = p.dirty_max[1] - p.dirty_min[1],
		})
		p.is_dirty = false
	}
	for &p, i in a.pages_color {
		if !p.is_dirty { continue }
		append(&out, Atlas_Dirty{
			page_index = u16(i), is_color = true,
			x = p.dirty_min[0], y = p.dirty_min[1],
			w = p.dirty_max[0] - p.dirty_min[0],
			h = p.dirty_max[1] - p.dirty_min[1],
		})
		p.is_dirty = false
	}
	return out[:]
}
