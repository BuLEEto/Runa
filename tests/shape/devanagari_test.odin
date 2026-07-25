/*
Devanagari shaper smoke tests — shape a handful of canonical
syllables end-to-end through `shape_run` against
`tests/fonts/NotoSansDevanagari.ttf` and check the gid sequence
matches HarfBuzz's reference output. Skipped if the font isn't
present (symlinked from system Noto).
*/
package shape_test

import "core:os"
import "core:testing"

import runa  "../.."
import shape "../../shape"
import parse "../../parse"

NOTO_DEV :: "tests/fonts/NotoSansDevanagari.ttf"

@(test)
test_devanagari_kta_conjunct :: proc(t: ^testing.T) {
	ctx, ok := shape_devanagari(t, "क्त") // KA + VIRAMA + TA
	if !ok { return }
	defer dev_test_destroy(&ctx)

	// HarfBuzz: [183, 40] — half-k + ta.
	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 183)
	testing.expect_value(t, int(ctx.gids[1]), 40)
}

@(test)
test_devanagari_reph :: proc(t: ^testing.T) {
	ctx, ok := shape_devanagari(t, "र्क") // RA + VIRAMA + KA, reph cluster
	if !ok { return }
	defer dev_test_destroy(&ctx)

	// HarfBuzz: [25, 181] — base k + reph mark.
	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 25)
	testing.expect_value(t, int(ctx.gids[1]), 181)
}

@(test)
test_devanagari_lone_reph :: proc(t: ^testing.T) {
	// "र्" — RA + VIRAMA with no base consonant after it (a "lone reph").
	// reorder_reph used to compute base_idx == len and index past the
	// glyph array, panicking. Must shape cleanly and produce glyphs.
	ctx, ok := shape_devanagari(t, "र्")
	if !ok { return }
	defer dev_test_destroy(&ctx)
	testing.expect(t, len(ctx.gids) >= 1, "lone reph should still produce glyphs")
}

@(test)
test_devanagari_reph_before_non_indic :: proc(t: ^testing.T) {
	// "र् क" — a word ending in RA + VIRAMA, then SPACE, then KA.
	// The space breaks the cluster at lo+2, so the reph syllable has no
	// base consonant. `identify_base` used to fall back to
	// `base_idx = scan_from`, which in that case points at the *next*
	// syllable's first glyph — and `reorder_reph` then rotated the space
	// to the front of the run. Output was [3, 181, 25] (space, reph, ka)
	// instead of [181, 3, 25].
	//
	// This is in-bounds-but-wrong, so the v1.2.1 `base >= len(gids)`
	// guard never fired: silent text corruption, not a crash.
	//
	// NOTE: unlike the rest of this file, the exact gids here are NOT
	// HarfBuzz-verified. HarfBuzz emits [52, 81, 3, 25] — it declines to
	// form a reph at all when there is no base consonant to carry it,
	// whereas runa applies `rphf` buffer-wide with no positional gate and
	// collapses RA+VIRAMA to rephdeva (181). That composition divergence
	// is a separate, pre-existing defect. What this test pins is the
	// *ordering*, which HarfBuzz agrees with: the space stays after the
	// syllable. See test_devanagari_reph_punct_order_robust for the
	// version-independent form of the same invariant.
	ctx, ok := shape_devanagari(t, "र् क")
	if !ok { return }
	defer dev_test_destroy(&ctx)

	testing.expect_value(t, len(ctx.gids), 3)
	testing.expect_value(t, int(ctx.gids[0]), 181) // reph  (runa-specific, not HB)
	testing.expect_value(t, int(ctx.gids[1]), 3)   // space
	testing.expect_value(t, int(ctx.gids[2]), 25)  // ka
}

@(test)
test_devanagari_reph_before_danda :: proc(t: ^testing.T) {
	// Same defect, reached via the danda (U+0964) — Devanagari's full
	// stop, so this is the common real-text trigger rather than a
	// synthetic one. Punctuation must not sort ahead of the syllable.
	//
	// Same caveat as above: HarfBuzz emits [52, 81, 104]; the reph
	// composition is runa-specific, the ordering is the invariant.
	ctx, ok := shape_devanagari(t, "र्।")
	if !ok { return }
	defer dev_test_destroy(&ctx)

	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 181) // reph  (runa-specific, not HB)
	testing.expect_value(t, int(ctx.gids[1]), 104) // danda
}

@(test)
test_devanagari_reph_punct_order_robust :: proc(t: ^testing.T) {
	// Version-independent form of the two tests above: resolve the gids
	// through the font's own cmap instead of hardcoding them, so this
	// survives a font update and can run in CI (which fetches a different
	// NotoSansDevanagari build — the rest of this suite is skipped there
	// precisely because it pins exact gids).
	//
	// Invariant: a syllable-final reph must not let the following
	// punctuation sort ahead of it. Pre-fix the space came out first.
	ctx, ok := shape_devanagari(t, "र् क")
	if !ok { return }
	defer dev_test_destroy(&ctx)

	space_gid := runa.font_lookup_glyph(&ctx.font, ' ')
	ka_gid    := runa.font_lookup_glyph(&ctx.font, 'क')

	space_at := -1
	for g, i in ctx.gids { if g == space_gid { space_at = i; break } }

	testing.expect(t, space_at > 0, "space must not be the first glyph — the reph syllable precedes it")
	testing.expect(t, len(ctx.gids) >= 2, "expected at least a syllable glyph and the space")
	testing.expect_value(t, ctx.gids[len(ctx.gids) - 1], ka_gid) // trailing KA stays last
}

@(test)
test_devanagari_reph_with_independent_vowel :: proc(t: ^testing.T) {
	// "कर्अ" — KA, then a reph whose base is an INDEPENDENT VOWEL rather
	// than a consonant. The OpenType Devanagari grammar's vowel-based
	// syllable is `[Ra H] V [N] ... [{M}] [SM] [(H|VD)]`, so this is
	// spec-sanctioned, not a defective cluster.
	//
	// Guards the fix for the reph-before-punctuation bug from
	// overcorrecting: an earlier attempt gated the `identify_base`
	// fallback on `!has_reph` alone, which discarded the vowel as a base
	// and emitted the reph BEFORE it ([25, 181, 9]). rephdeva has zero
	// advance and paints backwards from its pen, so that put the mark on
	// the preceding letter.
	//
	// HarfBuzz reference: [25, 9, 181] — ka, adeva, rephdeva.
	ctx, ok := shape_devanagari(t, "कर्अ")
	if !ok { return }
	defer dev_test_destroy(&ctx)

	testing.expect_value(t, len(ctx.gids), 3)
	testing.expect_value(t, int(ctx.gids[0]), 25)  // ka
	testing.expect_value(t, int(ctx.gids[1]), 9)   // adeva — the base
	testing.expect_value(t, int(ctx.gids[2]), 181) // rephdeva, after its base
}

@(test)
test_devanagari_reph_vowel_pre_base_matra :: proc(t: ^testing.T) {
	// "र्अि" — reph + independent vowel + pre-base I-matra. Exercises
	// reorder_pre_base_matra on a vowel base: the matra must reorder to
	// the front AND pick up its contextual pre-base form (604), not the
	// plain post-base one (67).
	//
	// HarfBuzz reference: [604, 9, 181].
	ctx, ok := shape_devanagari(t, "र्अि")
	if !ok { return }
	defer dev_test_destroy(&ctx)

	testing.expect_value(t, len(ctx.gids), 3)
	testing.expect_value(t, int(ctx.gids[0]), 604) // pre-base I-matra form
	testing.expect_value(t, int(ctx.gids[1]), 9)   // adeva
	testing.expect_value(t, int(ctx.gids[2]), 181) // rephdeva
}

@(test)
test_devanagari_pre_base_matra :: proc(t: ^testing.T) {
	ctx, ok := shape_devanagari(t, "कि") // KA + I-MATRA (pre-base)
	if !ok { return }
	defer dev_test_destroy(&ctx)

	// HarfBuzz: [607, 25] — i-matra rendered BEFORE base k.
	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 607)
	testing.expect_value(t, int(ctx.gids[1]), 25)
}

@(test)
test_devanagari_post_base_matra :: proc(t: ^testing.T) {
	ctx, ok := shape_devanagari(t, "की") // KA + II-MATRA (post-base, no reorder)
	if !ok { return }
	defer dev_test_destroy(&ctx)

	// HarfBuzz: [25, 655] — base k then ii-matra (encoded order kept).
	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 25)
	testing.expect_value(t, int(ctx.gids[1]), 655)
}

@(test)
test_devanagari_single_consonant :: proc(t: ^testing.T) {
	ctx, ok := shape_devanagari(t, "क") // KA alone
	if !ok { return }
	defer dev_test_destroy(&ctx)

	// HarfBuzz: [25].
	testing.expect_value(t, len(ctx.gids), 1)
	testing.expect_value(t, int(ctx.gids[0]), 25)
}

// dev_test_ctx is the cleanup bundle each test returns from
// shape_devanagari. Caller defers dev_test_destroy.
Dev_Test_Ctx :: struct {
	font:  runa.Font,
	bytes: []u8,
	gids:  []parse.Glyph_ID,
}

dev_test_destroy :: proc(c: ^Dev_Test_Ctx) {
	delete(c.gids)
	runa.font_destroy(&c.font)
	delete(c.bytes)
}

shape_devanagari :: proc(t: ^testing.T, text: string) -> (Dev_Test_Ctx, bool) {
	ctx: Dev_Test_Ctx
	bytes, oerr := os.read_entire_file_from_path(NOTO_DEV, context.allocator)
	if oerr != nil { return ctx, false }
	ctx.bytes = bytes
	f, ferr := runa.font_load(bytes)
	if ferr != .None { delete(bytes); return ctx, false }
	ctx.font = f

	out := make([dynamic]shape.Shaped_Glyph, 0, 16)
	defer delete(out)
	inputs := shape.Shape_Inputs{
		cmap         = &ctx.font._cmap,
		hmtx         = &ctx.font._hmtx,
		gsub         = ctx.font._has_gsub ? &ctx.font._gsub : nil,
		gpos         = ctx.font._has_gpos ? &ctx.font._gpos : nil,
		hvar         = nil,
		axis_values  = nil,
		units_per_em = ctx.font.units_per_em,
	}
	opts := shape.Shape_Run_Opts{script = parse.tag("deva"), language = parse.DFLT_LANG}
	shape.shape_run(&inputs, opts, text, 48.0, &out)

	ctx.gids = make([]parse.Glyph_ID, len(out))
	for sg, i in out { ctx.gids[i] = sg.glyph_id }
	return ctx, true
}

@(test)
test_devanagari_kti_multi_consonant_pre_base :: proc(t: ^testing.T) {
	// "क्ति" — KA + VIRAMA + TA + I-MATRA. The I-matra is a pre-base
	// vowel sign and must move to the START of the cluster, not just
	// before the base consonant. HarfBuzz: [604, 183, 40] — pre-base
	// I-matra variant, half-K, TA.
	ctx, ok := shape_devanagari(t, "क्ति")
	if !ok { return }
	defer dev_test_destroy(&ctx)
	testing.expect_value(t, len(ctx.gids), 3)
	testing.expect_value(t, int(ctx.gids[0]), 604)
	testing.expect_value(t, int(ctx.gids[1]), 183)
	testing.expect_value(t, int(ctx.gids[2]), 40)
}
