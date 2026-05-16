/*
Perf bench harness. Walks the canonical scenarios (warm
cache, modern x86_64) and prints a one-line-per-scenario report.

Numbers go to stdout as plain text plus a JSON record so CI can diff
against the previous main-branch baseline. The JSON shape:

    {"commit": "<sha>", "scenarios": [{"name": "...", "ns": 12345}, ...]}

The perf targets (warm cache, x86_64):

    font_load(InterVariable.ttf)              ≤   5 000 000 ns
    measure_text("Hello, world!", size=16)    ≤     200 000 ns cold
    measure_text(...) cached                  ≤       5 000 ns
    layout_paragraph(5 000 words) cold        ≤  30 000 000 ns
    layout_paragraph(5 000 words) cached      ≤   1 000 000 ns
    raster_glyph (32 px, 8-bit alpha)         ≤     100 000 ns

The cached numbers are aspirational at v0.1 — the Cache type isn't
wired up yet. The harness reports cold numbers across the board and
prints the targets so a developer eyeballs the gap.

Run:
    odin run tools/bench.odin -file -- tests/fonts/Roboto-Regular.ttf
*/
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import runa   "../"
import raster "../raster"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: bench <font.ttf>")
		os.exit(2)
	}
	path := os.args[1]

	bytes, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil { fmt.eprintfln("read: %v", rerr); os.exit(1) }
	defer delete(bytes)

	// font_load
	font_load_ns := bench_ns(50, proc(state: rawptr) {
		ctx := cast(^Bench_Ctx)state
		font, err := runa.font_load(ctx.bytes)
		if err == .None { runa.font_destroy(&font) }
	}, &Bench_Ctx{bytes = bytes})

	font, err := runa.font_load(bytes)
	if err != .None { fmt.eprintfln("font_load: %v", err); os.exit(1) }
	defer runa.font_destroy(&font)

	// measure_text + layout_paragraph
	stack := runa.Font_Stack{&font}
	opts := runa.Paragraph_Opts{fonts = stack, size = 16}

	short_text := "Hello, world!"
	measure_short_ns := bench_ns(2000, proc(state: rawptr) {
		ctx := cast(^Bench_Ctx2)state
		_, _ = runa.measure_text(ctx.text, ctx.opts)
	}, &Bench_Ctx2{text = short_text, opts = opts})

	long_text := build_long_text(5000)
	defer delete(long_text)
	measure_long_ns := bench_ns(20, proc(state: rawptr) {
		ctx := cast(^Bench_Ctx2)state
		_, _ = runa.measure_text(ctx.text, ctx.opts)
	}, &Bench_Ctx2{text = long_text, opts = opts})

	layout_long_ns := bench_ns(20, proc(state: rawptr) {
		ctx := cast(^Bench_Ctx2)state
		lines, _ := runa.layout_paragraph(ctx.text, ctx.opts)
		for &l in lines { runa.line_destroy(&l) }
		delete(lines)
	}, &Bench_Ctx2{text = long_text, opts = opts})

	// Cached path — `Cache` enables the zero-alloc hit guarantee per
	// Warm the cache then iterate measurement-only.
	c := runa.cache_make()
	defer runa.cache_destroy(&c)

	cached_ctx := &Bench_Cached_Ctx{font = &font, text = short_text, size = 16, cache = &c}
	_ = runa.shape_text_cached(&font, short_text, 16, &c) // warm
	measure_short_cached_ns := bench_ns(20_000, proc(state: rawptr) {
		ctx := cast(^Bench_Cached_Ctx)state
		_ = runa.shape_text_cached(ctx.font, ctx.text, ctx.size, ctx.cache)
	}, cached_ctx)

	// 5000-word cached: warm with one walk, then re-walk with the cache
	// every iteration. The cache stores per-run shapes, so re-walking
	// the same word list hits each word's cached buffer.
	cached_long_ctx := &Bench_Cached_Ctx{font = &font, text = long_text, size = 16, cache = &c}
	_ = runa.shape_text_cached(&font, long_text, 16, &c) // warm
	measure_long_cached_ns := bench_ns(200, proc(state: rawptr) {
		ctx := cast(^Bench_Cached_Ctx)state
		_ = runa.shape_text_cached(ctx.font, ctx.text, ctx.size, ctx.cache)
	}, cached_long_ctx)

	// raster_glyph
	gid := runa.font_lookup_glyph(&font, 'g')
	outline := runa.Outline{}
	defer runa.outline_destroy(&outline)
	runa.font_glyph_outline(&font, gid, &outline)
	edges := make([dynamic]raster.Edge, 0, 256)
	defer delete(edges)
	rast_ns := bench_ns(200, proc(state: rawptr) {
		ctx := cast(^Bench_Ctx3)state
		bm, _, _, _ := raster.rasterize(ctx.outline, ctx.upem, 32.0, ctx.edges)
		raster.bitmap_destroy(&bm)
	}, &Bench_Ctx3{outline = &outline, upem = font.units_per_em, edges = &edges})

	fmt.println("scenario                                                target (ns)         measured (ns)")
	report("font_load(font.ttf)",                       5_000_000, font_load_ns)
	report("measure_text(short, cold)",                   200_000, measure_short_ns)
	report("shape_text_cached(short, hit)",                  5_000, measure_short_cached_ns)
	report("measure_text(5000-word, cold)",            30_000_000, measure_long_ns)
	report("shape_text_cached(5000-word, hit)",         1_000_000, measure_long_cached_ns)
	report("layout_paragraph(5000-word, cold)",        30_000_000, layout_long_ns)
	report("raster_glyph('g', 32px)",                     100_000, rast_ns)

	// JSON summary for CI ingestion.
	json := strings.builder_make()
	defer strings.builder_destroy(&json)
	fmt.sbprintf(&json, `{{"scenarios":[`)
	json_row(&json, "font_load",                 font_load_ns,   true)
	json_row(&json, "measure_short_cold",        measure_short_ns, false)
	json_row(&json, "measure_long_cold",         measure_long_ns, false)
	json_row(&json, "layout_paragraph_cold",     layout_long_ns, false)
	json_row(&json, "raster_glyph_g_32",         rast_ns,        false)
	fmt.sbprintf(&json, `]}}`)
	fmt.println()
	fmt.println(strings.to_string(json))
}

Bench_Ctx        :: struct { bytes: []u8 }
Bench_Ctx2       :: struct { text: string, opts: runa.Paragraph_Opts }
Bench_Ctx3       :: struct { outline: ^runa.Outline, upem: u16, edges: ^[dynamic]raster.Edge }
Bench_Cached_Ctx :: struct { font: ^runa.Font, text: string, size: f32, cache: ^runa.Cache }

bench_ns :: proc(iters: int, fn: proc(state: rawptr), state: rawptr) -> u64 {
	// Warmup.
	for _ in 0..<min(iters, 10) { fn(state) }

	start := time.now()
	for _ in 0..<iters { fn(state) }
	elapsed := time.since(start)
	return u64(time.duration_nanoseconds(elapsed)) / u64(iters)
}

report :: proc(name: string, target_ns, measured_ns: u64) {
	ratio := f32(measured_ns) / f32(target_ns)
	flag := "OK"
	if measured_ns > target_ns { flag = "!!" }
	fmt.printf("%-50s %10.3f ms target   %10.3f ms measured   %s (%.2fx)\n",
		name,
		f32(target_ns)   / 1_000_000.0,
		f32(measured_ns) / 1_000_000.0,
		flag, ratio)
}

json_row :: proc(b: ^strings.Builder, name: string, ns: u64, first: bool) {
	if !first { fmt.sbprintf(b, ",") }
	fmt.sbprintf(b, `{{"name":"%s","ns":%d}}`, name, ns)
}

build_long_text :: proc(word_count: int) -> string {
	// Bigram-realistic English-ish text: round-robins through a small
	// pool of common words. Long enough that hot caches matter; small
	// enough that the harness fits in a few ms per scenario.
	words := [?]string{
		"the", "quick", "brown", "fox", "jumps", "over", "the",
		"lazy", "dog", "and", "then", "runs", "across", "a",
		"meadow", "where", "small", "birds", "are", "singing",
	}
	b := strings.builder_make()
	for i in 0..<word_count {
		if i > 0 { fmt.sbprint(&b, " ") }
		fmt.sbprint(&b, words[i % len(words)])
	}
	return strings.to_string(b)
}
