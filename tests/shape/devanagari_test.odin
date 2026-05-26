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
