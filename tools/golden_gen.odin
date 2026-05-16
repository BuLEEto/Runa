/*
Generate canonical golden PGMs for `tests/golden/golden_test`.

The spec list here MUST mirror tests/golden/golden_test.odin's
SPECS. Producing the goldens is a separate program because it
WRITES to the repo (committing the deterministic baseline) — the
test itself only READS.

Run:
    odin run tools/golden_gen.odin -file -o:speed
*/
package main

import "core:fmt"
import "core:os"

import runa   "../"
import raster "../raster"

Golden_Spec :: struct {
	font_path:   string,
	rune_val:    rune,
	size:        f32,
	golden_path: string,
}

SPECS := [?]Golden_Spec{
	{"tests/fonts/Roboto-Regular.ttf",  'A', 32, "tests/golden/data/roboto_A_32.pgm"},
	{"tests/fonts/Roboto-Regular.ttf",  'g', 24, "tests/golden/data/roboto_g_24.pgm"},
	{"tests/fonts/Roboto-Regular.ttf",  'é', 32, "tests/golden/data/roboto_e_acute_32.pgm"},
	{"tests/fonts/InterVariable.ttf",    'a', 16, "tests/golden/data/inter_a_16.pgm"},
	{"tests/fonts/FiraCode-Regular.ttf", 'g', 24, "tests/golden/data/firacode_g_24.pgm"},
	{"tests/fonts/Roboto-Regular.ttf",  'α', 32, "tests/golden/data/roboto_alpha_32.pgm"},
	{"tests/fonts/Roboto-Regular.ttf",  'Я', 32, "tests/golden/data/roboto_ya_32.pgm"},
}

main :: proc() {
	wrote := 0
	skipped := 0
	for spec in SPECS {
		font_bytes, ferr := os.read_entire_file_from_path(spec.font_path, context.allocator)
		if ferr != nil {
			fmt.eprintfln("skip %s: font missing", spec.golden_path)
			skipped += 1
			continue
		}
		defer delete(font_bytes)

		font, err := runa.font_load(font_bytes)
		if err != .None {
			fmt.eprintfln("skip %s: font_load: %v", spec.golden_path, err)
			skipped += 1
			continue
		}
		defer runa.font_destroy(&font)

		gid := runa.font_lookup_glyph(&font, spec.rune_val)
		if gid == 0 {
			fmt.eprintfln("skip %s: glyph for %v not in font", spec.golden_path, spec.rune_val)
			skipped += 1
			continue
		}

		outline := runa.Outline{}
		defer runa.outline_destroy(&outline)
		if oerr := runa.font_glyph_outline(&font, gid, &outline); oerr != .None {
			fmt.eprintfln("skip %s: outline: %v", spec.golden_path, oerr)
			skipped += 1
			continue
		}
		if len(outline.contour_ends) == 0 {
			fmt.eprintfln("skip %s: empty outline", spec.golden_path)
			skipped += 1
			continue
		}

		edges := make([dynamic]raster.Edge, 0, 256)
		defer delete(edges)

		bm, _, _, rerr := raster.rasterize(&outline, font.units_per_em, spec.size, &edges)
		if rerr != .None {
			fmt.eprintfln("skip %s: rasterize: %v", spec.golden_path, rerr)
			skipped += 1
			continue
		}
		defer raster.bitmap_destroy(&bm)

		if !write_pgm(spec.golden_path, bm.pixels, bm.width, bm.height) {
			fmt.eprintfln("FAIL write %s", spec.golden_path)
			continue
		}
		fmt.printfln("wrote %s  (%dx%d)", spec.golden_path, bm.width, bm.height)
		wrote += 1
	}
	fmt.printfln("%d wrote, %d skipped", wrote, skipped)
}

write_pgm :: proc(path: string, pixels: []u8, w, h: int) -> bool {
	header := fmt.tprintf("P5\n%d %d\n255\n", w, h)
	buf := make([]u8, len(header) + len(pixels))
	defer delete(buf)
	copy(buf[:len(header)], transmute([]u8)header)
	copy(buf[len(header):], pixels)
	if err := os.write_entire_file(path, buf); err != nil {
		return false
	}
	return true
}
