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

// RASTER_MAX_DIM caps a single glyph bitmap's width/height. No legitimate
// glyph renders larger; the cap turns a pathological size or a malicious
// font's absurd glyph bbox (both feed `bbox × size` into the dimensions)
// into a graceful failure instead of an unbounded allocation / OOM.
RASTER_MAX_DIM :: 4096

bitmap_make :: proc(width, height: int, allocator := context.allocator) -> (b: Bitmap, ok: bool) {
	if width <= 0 || height <= 0 {
		return Bitmap{}, true                // zero-size bitmap is valid (e.g. space glyph)
	}
	if width > RASTER_MAX_DIM || height > RASTER_MAX_DIM {
		return Bitmap{}, false               // absurd dimensions — refuse rather than OOM
	}
	pixels := make([]u8, width * height, allocator)
	if pixels == nil { return Bitmap{}, false }
	return Bitmap{width = width, height = height, pixels = pixels}, true
}

bitmap_destroy :: proc(b: ^Bitmap, allocator := context.allocator) {
	delete(b.pixels, allocator)
	b^ = {}
}
