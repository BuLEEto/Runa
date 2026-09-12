// Per-call OpenType feature control. Inter's "->" ligates via calt by
// default; disabling it splits the arrow into two glyphs / two clusters.
package runa_test

import "core:testing"
import runa "../../"

@(private="file")
NO_LIGATURES :: bit_set[runa.Feature]{.Ligatures, .Contextual_Ligatures, .Contextual_Alternates}

@(private="file")
shape_counts :: proc(font: ^runa.Font, text: string, dis: bit_set[runa.Feature]) -> (glyphs, clusters: int, advance: f32) {
	out := make([dynamic]runa.Shaped_Glyph, 0, 16, context.temp_allocator)
	runa.shape_text(font, text, 16, &out, disable_features = dis)
	seen: map[u32]bool = make(map[u32]bool, 8, context.temp_allocator)
	for g in out {
		advance += g.x_advance
		seen[g.cluster] = true
	}
	return len(out), len(seen), advance
}

// Disabling ligatures splits "->" into two glyphs with two clusters — the
// property an editor needs so the caret and single-character selection land
// between the two characters instead of inside one ligature.
@(test)
test_disable_ligatures_splits_glyphs_and_clusters :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	// Default: the arrow ligates to one glyph / one cluster.
	g, c, _ := shape_counts(&font, "->", {})
	testing.expect_value(t, g, 1)
	testing.expect_value(t, c, 1)

	// The whole ligature group off (the code-editor recipe): two glyphs.
	g, c, _ = shape_counts(&font, "->", NO_LIGATURES)
	testing.expect_value(t, g, 2)
	testing.expect_value(t, c, 2)

	// Single-bit granularity: Inter forms "->" via calt, so that bit alone
	// splits it, while a non-participating bit leaves it ligated.
	g, _, _ = shape_counts(&font, "->", {.Contextual_Alternates})
	testing.expect_value(t, g, 2)
	g, _, _ = shape_counts(&font, "->", {.Ligatures})
	testing.expect_value(t, g, 1)
}

// The measured width must reflect the feature set and stay equal to the sum
// of the shaped advances under both settings — otherwise wrapping computed
// from measurement disagrees with what is drawn.
@(test)
test_disable_ligatures_changes_measured_width_consistently :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	opts_on  := runa.Paragraph_Opts{fonts = stack, size = 16}
	opts_off := runa.Paragraph_Opts{fonts = stack, size = 16, disable_features = NO_LIGATURES}

	w_on,  _ := runa.measure_text("->", opts_on)
	w_off, _ := runa.measure_text("->", opts_off)

	// Splitting the arrow ligature widens the run.
	testing.expect(t, w_off > w_on, "ligatures-off width should exceed ligated width")

	// measure_text must equal the sum of shaped advances for the same set.
	_, _, adv_on  := shape_counts(&font, "->", {})
	_, _, adv_off := shape_counts(&font, "->", NO_LIGATURES)
	testing.expect(t, abs(w_on  - adv_on)  < 0.05, "measure(on) must match shaped advance")
	testing.expect(t, abs(w_off - adv_off) < 0.05, "measure(off) must match shaped advance")
}

// The feature set is part of the shape cache key: a ligated and a
// ligatures-off shaping of the same (font, size, text) must not collide.
@(test)
test_feature_set_is_part_of_shape_cache_key :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	c := runa.cache_make()
	defer runa.cache_destroy(&c)

	on1  := runa.shape_text_cached(&font, "->", 16, &c)                                  // ligated: 1 glyph
	off  := runa.shape_text_cached(&font, "->", 16, &c, disable_features = NO_LIGATURES) // split: 2 glyphs
	on2  := runa.shape_text_cached(&font, "->", 16, &c)                                  // ligated again (still cached)

	testing.expect_value(t, len(on1), 1)
	testing.expect_value(t, len(off), 2)   // would be 1 (stale hit) if the key ignored features
	testing.expect_value(t, len(on2), 1)
}

// Regression: the zero value ({}) leaves default shaping untouched — the
// arrow still ligates, ordinary text is unchanged.
@(test)
test_default_feature_set_unchanged :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	g, _, _ := shape_counts(&font, "->", {})
	testing.expect_value(t, g, 1)   // ligature still forms by default

	// Non-ligating text is identical with and without the flag.
	g_on,  _, adv_on  := shape_counts(&font, "abc", {})
	g_off, _, adv_off := shape_counts(&font, "abc", NO_LIGATURES)
	testing.expect_value(t, g_on, 3)
	testing.expect_value(t, g_off, 3)
	testing.expect(t, abs(adv_on - adv_off) < 0.001, "non-ligating text advance must not change")
}

// Wrapping foundation: measure_text, measure_text_cached and layout_paragraph
// width must agree under both settings, or a wrapper breaks in the wrong place.
@(test)
test_all_width_paths_agree_under_features :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	text  := "x -> y -> z end"   // arrows to ligate + spaces (break opportunities)

	for dis in ([]bit_set[runa.Feature]{ {}, NO_LIGATURES }) {
		opts := runa.Paragraph_Opts{fonts = stack, size = 16, disable_features = dis}

		w_measure, _ := runa.measure_text(text, opts)

		c := runa.cache_make()
		defer runa.cache_destroy(&c)
		w_cached, _ := runa.measure_text_cached(text, opts, &c)

		lines, err := runa.layout_paragraph(text, opts)
		testing.expect_value(t, err, runa.Error.None)
		w_layout: f32 = 0
		for l in lines { w_layout += l.width }
		for &l in lines { runa.line_destroy(&l) }
		delete(lines)

		testing.expect(t, abs(w_measure - w_cached) < 0.05, "measure vs measure_cached must agree")
		testing.expect(t, abs(w_measure - w_layout) < 0.05, "measure vs layout_paragraph width must agree")
	}
}
