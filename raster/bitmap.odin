package raster

// Bitmap is a CPU-side 8-bit-alpha image produced by the rasterizer.
// Memory is owned by `pixels`; consumers free with `bitmap_destroy`.
//
// Bitmaps are row-major, top-down (row 0 is the highest pixel) — the
// same orientation as PNG/PPM, so the demo writer doesn't need to flip.
Bitmap :: struct {
	width:  int,
	height: int,
	pixels: []u8,
}

bitmap_make :: proc(width, height: int, allocator := context.allocator) -> (b: Bitmap, ok: bool) {
	if width <= 0 || height <= 0 {
		return Bitmap{}, true                // zero-size bitmap is valid (e.g. space glyph)
	}
	pixels := make([]u8, width * height, allocator)
	if pixels == nil { return Bitmap{}, false }
	return Bitmap{width = width, height = height, pixels = pixels}, true
}

bitmap_destroy :: proc(b: ^Bitmap, allocator := context.allocator) {
	delete(b.pixels, allocator)
	b^ = {}
}
