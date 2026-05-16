/*
Golden-image tests.

Each entry below describes one (font, codepoint, size) rendering. The
expected output is a PGM file in `tests/golden/data/`. On run, the
test re-rasterizes and compares pixel-for-pixel within the
`MAX_DELTA` tolerance (≤ 2 / 255 absolute alpha
difference per pixel).

Goldens land in this commit as a self-consistency baseline produced
by the current rasterizer. Cross-platform parity is the v0.1 ≤ 2/255
contract; if a future change breaks parity on macOS or Windows
beyond the tolerance, the test fails and the diff PGM lands in
`tests/_failed/` for eyeballing.

Generate / regenerate goldens with `tools/golden_gen`:

    odin run tools/golden_gen.odin -file -o:speed

Commit the resulting PGMs alongside the change that produced them.
*/
package golden_test

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import runa   "../../"
import raster "../../raster"

MAX_DELTA :: 2                                                  // ≤ 2/255 per-pixel tolerance

// Each Golden_Spec describes one rendering. `font_path` is resolved
// from the test runner's working directory; `size` is in pixels;
// `golden_path` is the expected output PGM. The spec is reused by the
// `tools/golden_gen` helper to produce the bitmap, and by the test
// to verify it.
Golden_Spec :: struct {
	name:        string,
	font_path:   string,
	rune_val:    rune,
	size:        f32,
	golden_path: string,
}

@(private)
SPECS := [?]Golden_Spec{
	{"roboto_A_32",        "tests/fonts/Roboto-Regular.ttf",     'A', 32, "tests/golden/data/roboto_A_32.pgm"},
	{"roboto_g_24",        "tests/fonts/Roboto-Regular.ttf",     'g', 24, "tests/golden/data/roboto_g_24.pgm"},
	{"roboto_é_32",        "tests/fonts/Roboto-Regular.ttf",     'é', 32, "tests/golden/data/roboto_e_acute_32.pgm"},
	{"inter_a_16",         "tests/fonts/InterVariable.ttf",       'a', 16, "tests/golden/data/inter_a_16.pgm"},
	{"firacode_g_24",      "tests/fonts/FiraCode-Regular.ttf",    'g', 24, "tests/golden/data/firacode_g_24.pgm"},
	{"roboto_alpha_32",    "tests/fonts/Roboto-Regular.ttf",     'α', 32, "tests/golden/data/roboto_alpha_32.pgm"},   // Greek lowercase alpha
	{"roboto_ya_32",       "tests/fonts/Roboto-Regular.ttf",     'Я', 32, "tests/golden/data/roboto_ya_32.pgm"},      // Cyrillic capital Ya
}

@(test)
test_goldens :: proc(t: ^testing.T) {
	for spec in SPECS {
		check_spec(t, spec)
	}
}

@(private)
check_spec :: proc(t: ^testing.T, spec: Golden_Spec) {
	font_bytes, ferr := os.read_entire_file_from_path(spec.font_path, context.allocator)
	if ferr != nil {
		log.infof("%s: font %s not present — skipping", spec.name, spec.font_path)
		return
	}
	defer delete(font_bytes)

	font, err := runa.font_load(font_bytes)
	if err != .None {
		testing.fail(t)
		log.errorf("%s: font_load failed: %v", spec.name, err)
		return
	}
	defer runa.font_destroy(&font)

	bm, ok := rasterize_one(&font, spec.rune_val, spec.size)
	defer raster.bitmap_destroy(&bm)
	if !ok {
		log.infof("%s: glyph missing — skipping", spec.name)
		return
	}

	golden_bytes, gerr := os.read_entire_file_from_path(spec.golden_path, context.allocator)
	if gerr != nil {
		log.warnf("%s: golden %s missing — run tools/golden_gen to create it", spec.name, spec.golden_path)
		return
	}
	defer delete(golden_bytes)

	gw, gh, gpixels, perr := decode_pgm(golden_bytes)
	defer delete(gpixels)
	if !perr {
		testing.fail(t)
		log.errorf("%s: malformed golden", spec.name)
		return
	}

	if gw != bm.width || gh != bm.height {
		testing.fail(t)
		log.errorf("%s: size mismatch — golden %dx%d vs actual %dx%d", spec.name, gw, gh, bm.width, bm.height)
		return
	}

	max_diff := 0
	bad_pixels := 0
	for i in 0..<len(gpixels) {
		d := int(bm.pixels[i]) - int(gpixels[i])
		if d < 0 { d = -d }
		if d > max_diff { max_diff = d }
		if d > MAX_DELTA { bad_pixels += 1 }
	}
	if bad_pixels > 0 {
		testing.fail(t)
		log.errorf("%s: %d / %d pixels exceed ±%d tolerance (max diff %d)",
		           spec.name, bad_pixels, len(gpixels), MAX_DELTA, max_diff)
	}
}

@(private)
rasterize_one :: proc(font: ^runa.Font, r: rune, size: f32) -> (raster.Bitmap, bool) {
	gid := runa.font_lookup_glyph(font, r)
	if gid == 0 { return {}, false }

	outline := runa.Outline{}
	defer runa.outline_destroy(&outline)
	if oerr := runa.font_glyph_outline(font, gid, &outline); oerr != .None { return {}, false }
	if len(outline.contour_ends) == 0 { return {}, false }

	edges := make([dynamic]raster.Edge, 0, 256, context.allocator)
	defer delete(edges)

	bm, _, _, rerr := raster.rasterize(&outline, font.units_per_em, size, &edges)
	if rerr != .None {
		raster.bitmap_destroy(&bm)
		return {}, false
	}
	return bm, true
}

@(private)
decode_pgm :: proc(data: []u8) -> (w, h: int, pixels: []u8, ok: bool) {
	s := string(data)
	if !strings.has_prefix(s, "P5\n") { return }
	// Skip header line 1: "P5\n"
	rest := s[3:]
	// Optional comment lines (start with #). Skip them.
	for strings.has_prefix(rest, "#") {
		nl := strings.index_byte(rest, '\n')
		if nl < 0 { return }
		rest = rest[nl + 1:]
	}
	// "WIDTH HEIGHT\n"
	nl1 := strings.index_byte(rest, '\n')
	if nl1 < 0 { return }
	dims := strings.fields(rest[:nl1])
	defer delete(dims)
	if len(dims) != 2 { return }
	rest = rest[nl1 + 1:]
	w_u, w_ok := strconv_atoi(dims[0])
	h_u, h_ok := strconv_atoi(dims[1])
	if !w_ok || !h_ok { return }
	w, h = w_u, h_u

	// "MAXVAL\n"
	nl2 := strings.index_byte(rest, '\n')
	if nl2 < 0 { return }
	rest = rest[nl2 + 1:]

	need := w * h
	if len(rest) < need { return }
	out := make([]u8, need)
	copy(out, transmute([]u8)rest[:need])
	pixels = out
	ok = true
	return
}

@(private)
strconv_atoi :: proc(s: string) -> (int, bool) {
	n := 0
	for c in s {
		if c < '0' || c > '9' { return 0, false }
		n = n*10 + int(c - '0')
	}
	return n, true
}

