/*
End-to-end Font tests. Exercises font_load → lookup → outline against
a real font; this is the closest thing to a "smoke test" we get before
shaper / rasterizer land.
*/
package runa_test

import "core:log"
import "core:mem"
import "core:os"
import "core:testing"

import runa "../../"

ROBOTO   :: "tests/fonts/Roboto-Regular.ttf"
FIRACODE :: "tests/fonts/FiraCode-Regular.ttf"

@(private)
load_font_bytes :: proc(path: string) -> (data: []u8, ok: bool) {
	bytes, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return nil, false }
	return bytes, true
}

@(test)
test_font_load_roboto :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(bytes)

	font, err := runa.font_load(bytes)
	testing.expect_value(t, err, runa.Error.None)
	defer runa.font_destroy(&font)

	testing.expect_value(t, font.units_per_em, u16(2048))
	testing.expect(t, font.num_glyphs > 100, "Roboto has > 100 glyphs")
	testing.expect(t, font.ascent  > 0, "ascent positive")
	testing.expect(t, font.descent < 0, "descent negative")
}

@(test)
test_font_lookup_and_metrics :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(bytes)

	font, err := runa.font_load(bytes)
	testing.expect_value(t, err, runa.Error.None)
	defer runa.font_destroy(&font)

	gid := runa.font_lookup_glyph(&font, 'A')
	testing.expect(t, gid != 0, "'A' resolves")

	adv := runa.font_glyph_advance(&font, gid)
	testing.expect(t, adv > 0, "'A' has advance width")

	out := runa.Outline{}
	defer runa.outline_destroy(&out)

	oerr := runa.font_glyph_outline(&font, gid, &out)
	testing.expect_value(t, oerr, runa.Error.None)
	testing.expect(t, len(out.points) > 0, "'A' outline has points")
}

@(test)
test_font_load_rejects_truncated :: proc(t: ^testing.T) {
	// Less than the 12-byte SFNT header.
	_, err := runa.font_load([]u8{0, 1, 0, 0})
	testing.expect_value(t, err, runa.Error.Invalid_Table)
}

@(test)
test_cache_hit_returns_same_glyphs :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(bytes)

	font, err := runa.font_load(bytes)
	testing.expect_value(t, err, runa.Error.None)
	defer runa.font_destroy(&font)

	c := runa.cache_make()
	defer runa.cache_destroy(&c)

	first  := runa.shape_text_cached(&font, "Hello", 16, &c)
	second := runa.shape_text_cached(&font, "Hello", 16, &c)

	testing.expect_value(t, len(first), len(second))
	// Cache hit returns the *same* slice — pointers and length match.
	testing.expect(t, raw_data(first) == raw_data(second), "cache hit reuses storage")
}

@(test)
test_cache_hit_zero_allocations :: proc(t: ^testing.T) {
	// "No allocations in hot paths": a cache hit on
	// measure_text / shape_text must not allocate. Use a tracking
	// allocator scoped to the second call only.
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	c := runa.cache_make()
	defer runa.cache_destroy(&c)

	// Warm the cache with the first call.
	_ = runa.shape_text_cached(&font, "warm", 14, &c)

	// Scope a tracking allocator over the second (hit) call.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	prev := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	_ = runa.shape_text_cached(&font, "warm", 14, &c)
	context.allocator = prev

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_layout_paragraph_cached_matches_uncached :: proc(t: ^testing.T) {
	// The cached and uncached paths must produce byte-identical output
	// — same glyph IDs, clusters, advances. The cache is a perf hatch,
	// not a semantic divergence.
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	opts := runa.Paragraph_Opts{fonts = stack, size = 16, max_width = 80}

	long := "the quick brown fox jumps over the lazy dog"

	uncached_lines, _ := runa.layout_paragraph(long, opts)
	defer { for &l in uncached_lines { runa.line_destroy(&l) }; delete(uncached_lines) }

	c := runa.cache_make()
	defer runa.cache_destroy(&c)
	cached_lines, _ := runa.layout_paragraph(long, opts, &c)
	defer { for &l in cached_lines { runa.line_destroy(&l) }; delete(cached_lines) }

	testing.expect_value(t, len(cached_lines), len(uncached_lines))
	for i in 0..<min(len(cached_lines), len(uncached_lines)) {
		testing.expect_value(t, len(cached_lines[i].glyphs), len(uncached_lines[i].glyphs))
		for j in 0..<len(cached_lines[i].glyphs) {
			testing.expect_value(t, cached_lines[i].glyphs[j].glyph_id, uncached_lines[i].glyphs[j].glyph_id)
			testing.expect_value(t, cached_lines[i].glyphs[j].cluster,  uncached_lines[i].glyphs[j].cluster)
		}
	}
}

@(test)
test_layout_paragraph_cache_hit_skips_shaping :: proc(t: ^testing.T) {
	// Second call with the same cache must not re-shape — the
	// shape_text_cached path is now wired through layout_paragraph.
	// We assert this by checking the cache populated on the first
	// call and re-hits on the second (no new entries).
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	opts := runa.Paragraph_Opts{fonts = stack, size = 16}

	c := runa.cache_make()
	defer runa.cache_destroy(&c)

	// First call — populates the cache.
	first, _ := runa.layout_paragraph("Hello, world!", opts, &c)
	defer { for &l in first { runa.line_destroy(&l) }; delete(first) }

	// Snapshot cache size from the first call. Layout splits text
	// into one run (single font) so the cache holds exactly one
	// entry per (font, text, size) tuple.
	entries_after_first := runa.cache_size(&c)
	testing.expect(t, entries_after_first > 0, "cache populated by first layout call")

	// Second call — must hit cache, not add new entries.
	second, _ := runa.layout_paragraph("Hello, world!", opts, &c)
	defer { for &l in second { runa.line_destroy(&l) }; delete(second) }

	testing.expect_value(t, runa.cache_size(&c), entries_after_first)
}

@(test)
test_layout_paragraph_wraps :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	wide := runa.Paragraph_Opts{fonts = stack, size = 16, max_width = 10_000}
	narrow := runa.Paragraph_Opts{fonts = stack, size = 16, max_width = 60}

	long := "one two three four five six seven eight nine ten"

	wide_lines, _ := runa.layout_paragraph(long, wide)
	defer { for &l in wide_lines { runa.line_destroy(&l) }; delete(wide_lines) }
	testing.expect_value(t, len(wide_lines), 1)

	narrow_lines, _ := runa.layout_paragraph(long, narrow)
	defer { for &l in narrow_lines { runa.line_destroy(&l) }; delete(narrow_lines) }
	testing.expect(t, len(narrow_lines) > 1, "narrow max_width forces wrap")

	for l in narrow_lines {
		testing.expect(t, l.width <= 60 + 1, "each wrapped line under max_width")
	}
}

@(test)
test_layout_paragraph_hard_break :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	opts := runa.Paragraph_Opts{fonts = stack, size = 16, max_width = 1000}

	lines, _ := runa.layout_paragraph("hello\nworld", opts)
	defer { for &l in lines { runa.line_destroy(&l) }; delete(lines) }

	// LF forces a mandatory break.
	testing.expect_value(t, len(lines), 2)
}

@(test)
test_variable_font_axes_exposed :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { log.info("InterVariable.ttf not present; skipping"); return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	axes := runa.font_axes(&font)
	testing.expect(t, len(axes) >= 2, "Inter exposes at least 2 axes")

	saw_wght := false
	saw_opsz := false
	for ax in axes {
		if ax.tag == runa.Axis_Tag(0x77676874) { // 'wght'
			saw_wght = true
			testing.expect_value(t, ax.default_value, f32(400))
			testing.expect_value(t, ax.min_value, f32(100))
			testing.expect_value(t, ax.max_value, f32(900))
		}
		if ax.tag == runa.Axis_Tag(0x6F70737A) { // 'opsz'
			saw_opsz = true
		}
	}
	testing.expect(t, saw_wght && saw_opsz, "wght + opsz axes present")
}

@(test)
test_font_set_variation_changes_outline :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { log.info("InterVariable.ttf not present; skipping"); return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	gid := runa.font_lookup_glyph(&font, 'a')
	testing.expect(t, gid != 0, "'a' resolves in Inter")

	// Outline at the default instance.
	base := runa.Outline{}
	defer runa.outline_destroy(&base)
	testing.expect_value(t, runa.font_glyph_outline(&font, gid, &base), runa.Error.None)

	// Now crank wght up to 900 (max). Body strokes get noticeably
	// thicker — at least one point should shift.
	werr := runa.font_set_variation(&font, runa.Axis_Tag(0x77676874), 900)
	testing.expect_value(t, werr, runa.Error.None)

	bold := runa.Outline{}
	defer runa.outline_destroy(&bold)
	testing.expect_value(t, runa.font_glyph_outline(&font, gid, &bold), runa.Error.None)

	testing.expect_value(t, len(bold.points), len(base.points))
	any_shifted := false
	for i in 0..<len(bold.points) {
		if bold.points[i].x != base.points[i].x || bold.points[i].y != base.points[i].y {
			any_shifted = true
			break
		}
	}
	testing.expect(t, any_shifted, "wght=900 shifts at least one point of 'a'")
}

@(test)
test_hvar_shifts_advance_width :: proc(t: ^testing.T) {
	// At wght=900 every Latin glyph should be wider than at wght=400.
	// HVAR is what makes that true for the advance side; without it,
	// `font_glyph_advance` would return the default-instance value
	// regardless of axis state.
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	gid := runa.font_lookup_glyph(&font, 'a')
	WGHT :: runa.Axis_Tag(0x77676874)

	default_adv := runa.font_glyph_advance(&font, gid)

	testing.expect_value(t, runa.font_set_variation(&font, WGHT, 900), runa.Error.None)
	heavy_adv := runa.font_glyph_advance(&font, gid)

	testing.expect(t, heavy_adv > default_adv, "wght=900 yields a wider advance than default")
}

@(test)
test_layout_paragraph_axis_aware_widths :: proc(t: ^testing.T) {
	// `layout_paragraph` should give different line widths at
	// different wght values when HVAR is wired correctly.
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	opts  := runa.Paragraph_Opts{fonts = stack, size = 16}

	WGHT :: runa.Axis_Tag(0x77676874)
	runa.font_reset_variations(&font)
	regular_lines, _ := runa.layout_paragraph("Hello, world!", opts)
	defer { for &l in regular_lines { runa.line_destroy(&l) }; delete(regular_lines) }
	regular_width := regular_lines[0].width

	runa.font_set_variation(&font, WGHT, 900)
	heavy_lines, _ := runa.layout_paragraph("Hello, world!", opts)
	defer { for &l in heavy_lines { runa.line_destroy(&l) }; delete(heavy_lines) }
	heavy_width := heavy_lines[0].width

	testing.expect(t, heavy_width > regular_width, "bold paragraph is wider than regular")
}

@(test)
test_layout_paragraph_bidi_reorders_rtl :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	opts  := runa.Paragraph_Opts{fonts = stack, size = 16, direction = .RTL}

	// Hebrew alphabet — even though Roboto Regular doesn't ship full
	// Hebrew glyphs, the cmap returns gid 0 for misses; what we care
	// about is that the bidi pipeline tags glyphs at level 1 and the
	// L2 reorder reverses their order.
	lines, _ := runa.layout_paragraph("שלום", opts)
	defer { for &l in lines { runa.line_destroy(&l) }; delete(lines) }
	testing.expect_value(t, len(lines), 1)

	// Every glyph should land at level 1.
	saw_level_1 := false
	for g in lines[0].glyphs {
		if g.level == 1 { saw_level_1 = true; break }
	}
	testing.expect(t, saw_level_1, "RTL paragraph yields level-1 glyphs")

	// L2 reorder: clusters should appear in DECREASING byte order
	// (visual left-to-right of an RTL string is logical end → start).
	clusters_decreasing := true
	for i in 1..<len(lines[0].glyphs) {
		if lines[0].glyphs[i].cluster > lines[0].glyphs[i - 1].cluster {
			clusters_decreasing = false
			break
		}
	}
	testing.expect(t, clusters_decreasing, "RTL glyphs land in cluster-decreasing order")
}

@(test)
test_layout_paragraph_ltr_no_reorder :: proc(t: ^testing.T) {
	// Pure-LTR text should stay in cluster-increasing order — no
	// L2 reordering should happen.
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	opts  := runa.Paragraph_Opts{fonts = stack, size = 16}

	lines, _ := runa.layout_paragraph("Hello", opts)
	defer { for &l in lines { runa.line_destroy(&l) }; delete(lines) }
	testing.expect_value(t, len(lines), 1)

	for i in 1..<len(lines[0].glyphs) {
		testing.expect(t, lines[0].glyphs[i].cluster >= lines[0].glyphs[i - 1].cluster, "LTR clusters are monotonic")
	}
	for g in lines[0].glyphs {
		testing.expect_value(t, g.level, u8(0))
	}
}

@(test)
test_font_set_variation_out_of_range :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	// 1500 is well above wght's 900 max.
	err := runa.font_set_variation(&font, runa.Axis_Tag(0x77676874), 1500)
	testing.expect_value(t, err, runa.Error.Axis_Out_Of_Range)
}

@(test)
test_font_set_variation_static_font :: proc(t: ^testing.T) {
	// Static (non-variable) fonts return Unsupported_Format from
	// font_set_variation. Use Roboto.
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	err := runa.font_set_variation(&font, runa.Axis_Tag(0x77676874), 400)
	testing.expect_value(t, err, runa.Error.Unsupported_Format)
}

@(test)
test_font_load_firacode :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(FIRACODE)
	if !ok {
		log.info("FiraCode-Regular.ttf not present; skipping")
		return
	}
	defer delete(bytes)

	font, err := runa.font_load(bytes)
	testing.expect_value(t, err, runa.Error.None)
	defer runa.font_destroy(&font)

	// FiraCode is monospaced — every glyph in the long-metrics array
	// should share the same advance width. Spot-check a few.
	fi_advance := runa.font_glyph_advance(&font, runa.font_lookup_glyph(&font, 'i'))
	fa_advance := runa.font_glyph_advance(&font, runa.font_lookup_glyph(&font, 'm'))
	testing.expect_value(t, fi_advance, fa_advance)
}

// ---- Cache LRU eviction ----------------------------------------------
//
// runa.Cache used to be unbounded. Apps with high-churn unique text
// (code editors, log viewers, animated tickers) saw heap growth
// without bound. v1.x adds bounded LRU; these tests pin the policy.

@(test)
test_cache_lru_evicts_at_capacity :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	// Small cap so the test runs quickly.
	c := runa.cache_make(context.allocator, 8)
	defer runa.cache_destroy(&c)

	testing.expect_value(t, runa.cache_capacity(&c), 8)
	testing.expect_value(t, runa.cache_size(&c), 0)

	// Insert way past the cap with all-unique strings. Size must stay
	// pinned at the cap.
	for i in 0..<100 {
		txt := []u8{'a' + u8(i % 26), 'a' + u8((i / 26) % 26), 'a' + u8((i / 676) % 26)}
		_ = runa.shape_text_cached(&font, string(txt), 14, &c)
	}
	testing.expect_value(t, runa.cache_size(&c), 8)
}

@(test)
test_cache_lru_keeps_recently_used :: proc(t: ^testing.T) {
	// Pin the LRU policy: a key touched after every batch of new
	// inserts must survive eviction.
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	c := runa.cache_make(context.allocator, 4)
	defer runa.cache_destroy(&c)

	// Insert the "sticky" key first. Capture its slice for identity.
	sticky_first := runa.shape_text_cached(&font, "stick", 14, &c)
	sticky_ptr := raw_data(sticky_first)

	// Insert 20 unique strings, touching the sticky key every 3 calls
	// so it never falls to the LRU tail.
	for i in 0..<20 {
		txt := []u8{'q', 'a' + u8(i % 26), 'a' + u8((i / 26) % 26)}
		_ = runa.shape_text_cached(&font, string(txt), 14, &c)
		if i % 3 == 0 {
			_ = runa.shape_text_cached(&font, "stick", 14, &c)
		}
	}

	// "stick" must still be in the cache, and the slice we got on
	// the first call should still point to the same storage (no
	// allocation on the touch hits, no eviction).
	sticky_after := runa.shape_text_cached(&font, "stick", 14, &c)
	testing.expect(t, raw_data(sticky_after) == sticky_ptr, "sticky key survived LRU pressure")
	testing.expect_value(t, runa.cache_size(&c), 4)
}

@(test)
test_cache_unbounded_when_capacity_zero :: proc(t: ^testing.T) {
	// max_entries = 0 means no eviction (back-compat with v1.0).
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	c := runa.cache_make(context.allocator, 0)
	defer runa.cache_destroy(&c)

	for i in 0..<50 {
		txt := []u8{'z', 'a' + u8(i % 26), 'a' + u8((i / 26) % 26)}
		_ = runa.shape_text_cached(&font, string(txt), 14, &c)
	}
	testing.expect_value(t, runa.cache_size(&c), 50)
}

@(test)
test_cache_set_capacity_shrinks :: proc(t: ^testing.T) {
	// Setting a smaller cap at runtime should evict down to fit.
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	c := runa.cache_make(context.allocator, 0)
	defer runa.cache_destroy(&c)

	for i in 0..<30 {
		txt := []u8{'b', 'a' + u8(i % 26), 'a' + u8((i / 26) % 26)}
		_ = runa.shape_text_cached(&font, string(txt), 14, &c)
	}
	testing.expect_value(t, runa.cache_size(&c), 30)

	runa.cache_set_capacity(&c, 10)
	testing.expect_value(t, runa.cache_capacity(&c), 10)
	testing.expect_value(t, runa.cache_size(&c), 10)
}

@(test)
test_cache_eviction_no_leaks :: proc(t: ^testing.T) {
	// Tracking allocator over a high-churn burst — every byte
	// allocated during shaping must be freed when the cache evicts
	// or destroys.
	bytes, ok := load_font_bytes(ROBOTO)
	if !ok { return }
	defer delete(bytes)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = mem.tracking_allocator(&track)

		font, _ := runa.font_load(bytes)
		defer runa.font_destroy(&font)

		c := runa.cache_make(context.allocator, 16)
		defer runa.cache_destroy(&c)

		// Insert 500 unique strings with a 16-slot cap — that's 484
		// evictions plus 16 survivors plus the final destroy of those.
		for i in 0..<500 {
			txt := []u8{'k', 'a' + u8(i % 26), 'a' + u8((i / 26) % 26)}
			_ = runa.shape_text_cached(&font, string(txt), 14, &c)
		}
	}
	// All allocations from the inner scope must be reclaimed by the
	// destroys deferred at scope exit (font_destroy + cache_destroy).
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_variable_composite_glyph_outline :: proc(t: ^testing.T) {
	// Regression: a composite glyph's gvar deltas move its component
	// offsets, not the flattened outline points. Varying a flattened
	// composite mis-counts deltas and used to return .Invalid_Table, so
	// Inter's i / j / comma / etc. vanished at any non-default weight.
	// They must now produce a valid, non-empty, actually-shifted outline.
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { log.info("InterVariable.ttf not present; skipping"); return }
	defer delete(bytes)

	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	// Default-instance outline of 'i' for a shift comparison.
	i_gid := runa.font_lookup_glyph(&font, 'i')
	base := runa.Outline{}
	defer runa.outline_destroy(&base)
	testing.expect_value(t, runa.font_glyph_outline(&font, i_gid, &base), runa.Error.None)

	werr := runa.font_set_variation(&font, runa.Axis_Tag(0x77676874), 600) // 'wght'
	testing.expect_value(t, werr, runa.Error.None)

	// Composite glyphs, including a composite-of-composites ('ñ').
	for ch in ([]rune{'i', 'j', ',', ';', ':', '"', 'ñ'}) {
		gid := runa.font_lookup_glyph(&font, ch)
		o := runa.Outline{}
		defer runa.outline_destroy(&o)
		err := runa.font_glyph_outline(&font, gid, &o)
		testing.expectf(t, err == .None, "U+%04X @ wght=600 -> %v (want None)", ch, err)
		testing.expectf(t, len(o.points) > 0, "U+%04X @ wght=600 has no points", ch)
	}

	// The deltas must actually apply, not just avoid erroring.
	bold := runa.Outline{}
	defer runa.outline_destroy(&bold)
	testing.expect_value(t, runa.font_glyph_outline(&font, i_gid, &bold), runa.Error.None)
	testing.expect_value(t, len(bold.points), len(base.points))
	shifted := false
	for k in 0..<len(bold.points) {
		if bold.points[k].x != base.points[k].x || bold.points[k].y != base.points[k].y { shifted = true; break }
	}
	testing.expect(t, shifted, "wght=600 must shift at least one point of composite 'i'")
}
