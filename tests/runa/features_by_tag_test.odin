// Turning OpenType features on by tag (the HarfBuzz-style `features` list),
// the font-has-feature query, and precedence over the deprecated
// `disable_features`. smcp / onum ride the identical gsub_apply_feature path;
// the bundled Inter carries `zero` / `case` / `kern` (used here) but not
// `smcp` — which is itself the fallback case font_has_feature is for.
package runa_test

import "core:testing"
import runa "../../"

@(private="file")
INTER :: "tests/fonts/InterVariable.ttf"

@(private="file")
glyph_ids :: proc(font: ^runa.Font, text: string, feats: []runa.Feature_Setting) -> (ids: [dynamic]u32, advance: f32) {
	out := make([dynamic]runa.Shaped_Glyph, 0, 16, context.temp_allocator)
	runa.shape_text(font, text, 16, &out, features = feats)
	ids = make([dynamic]u32, 0, len(out), context.temp_allocator)
	for g in out { append(&ids, u32(g.glyph_id)); advance += g.x_advance }
	return
}

@(private="file")
ids_differ :: proc(a, b: [dynamic]u32) -> bool {
	if len(a) != len(b) { return true }
	for v, i in a { if v != b[i] { return true } }
	return false
}

// A feature turned on by tag substitutes glyphs: `zero` swaps '0' for the
// slashed zero — same glyph count (a single substitution), different id.
@(test)
test_feature_on_by_tag :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(INTER)
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	plain, _ := glyph_ids(&font, "0", nil)
	slash, _ := glyph_ids(&font, "0", {runa.feature("zero")})

	testing.expect_value(t, len(slash), len(plain))   // single-sub: count unchanged
	testing.expect(t, ids_differ(plain, slash), "`zero` must change the '0' glyph")
}

// font_has_feature answers both ways: present (`zero`) and absent (`smcp`,
// which Inter lacks). The absent answer is the hook for faking small caps.
@(test)
test_font_has_feature_query :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(INTER)
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	testing.expect(t, runa.font_has_feature(&font, "zero"), "Inter has zero")
	testing.expect(t, !runa.font_has_feature(&font, "smcp"), "Inter has no smcp")
	testing.expect(t, !runa.font_has_feature(&font, "zzzz"), "no such feature tag")
}

// kern is discretionary: turning it off changes the run width (a caller
// spacing letters out wants it off so the tracking isn't fought). Roboto's
// kern is a direct pair-pos lookup, so runa applies it; Inter's is behind
// an extension lookup runa doesn't execute yet, so it would show no change.
@(test)
test_kern_off_by_tag_changes_width :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/Roboto-Regular.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	_, adv_on  := glyph_ids(&font, "AVA Wo.", nil)
	_, adv_off := glyph_ids(&font, "AVA Wo.", {runa.feature("kern", false)})
	testing.expect(t, adv_off > adv_on, "kern off must widen the run (removes negative kerning)")
}

// Regression: Inter wraps its main kerning in a GPOS extension lookup
// (type 9). Now that extension lookups are executed, that kerning applies —
// turning kern off widens the run. Before, Inter kerning silently did nothing.
@(test)
test_extension_kern_applies :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(INTER)
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	_, adv_on  := glyph_ids(&font, "AVA Wo.", nil)
	_, adv_off := glyph_ids(&font, "AVA Wo.", {runa.feature("kern", false)})
	testing.expect(t, adv_off > adv_on, "Inter's extension-wrapped kern must apply")
}

// A `features` entry wins over the deprecated `disable_features` for the
// same tag: calt disabled by the bit set but re-enabled by the list stays on.
@(test)
test_features_override_disable_features :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(INTER)
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	out := make([dynamic]runa.Shaped_Glyph, 0, 8, context.temp_allocator)
	runa.shape_text(&font, "->", 16, &out,
		disable_features = {.Contextual_Alternates},   // would split the arrow
		features = {runa.feature("calt", true)})        // but the list turns it back on
	testing.expect_value(t, len(out), 1)                // ligated: the list wins
}

// NO_LIGATURES must be sliceable — `runa.NO_LIGATURES[:]` has to compile
// (it's @(rodata), not a constant) and actually turn ligatures off.
@(test)
test_no_ligatures_slice :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(INTER)
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	on  := make([dynamic]runa.Shaped_Glyph, context.temp_allocator)
	off := make([dynamic]runa.Shaped_Glyph, context.temp_allocator)
	runa.shape_text(&font, "->", 16, &on)
	runa.shape_text(&font, "->", 16, &off, features = runa.NO_LIGATURES[:])   // must compile
	testing.expect_value(t, len(on), 1)    // Inter ligates the arrow via calt
	testing.expect_value(t, len(off), 2)   // NO_LIGATURES splits it
}

// The `features` list is part of the shape cache key: a `zero` shaping and a
// plain shaping of the same (font, size, text) must not collide.
@(test)
test_feature_list_is_part_of_cache_key :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(INTER)
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	c := runa.cache_make()
	defer runa.cache_destroy(&c)

	plain := runa.shape_text_cached(&font, "0", 16, &c)
	slash := runa.shape_text_cached(&font, "0", 16, &c, features = {runa.feature("zero")})
	plain2 := runa.shape_text_cached(&font, "0", 16, &c)   // plain again, still cached

	testing.expect(t, plain[0].glyph_id != slash[0].glyph_id, "zero slot must not collide with plain")
	testing.expect_value(t, plain2[0].glyph_id, plain[0].glyph_id)
}
