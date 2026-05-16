/*
Bengali shaper smoke tests. Same pattern as devanagari_test.odin —
exercise the Indic pipeline against system Noto Bengali, compare
against HarfBuzz reference output.
*/
package shape_test

import "core:os"
import "core:testing"

import runa  "../.."
import shape "../../shape"
import parse "../../parse"

NOTO_BENG :: "tests/fonts/NotoSansBengali.ttf"

Beng_Test_Ctx :: struct {
	font:  runa.Font,
	bytes: []u8,
	gids:  []parse.Glyph_ID,
}

beng_test_destroy :: proc(c: ^Beng_Test_Ctx) {
	delete(c.gids)
	runa.font_destroy(&c.font)
	delete(c.bytes)
}

shape_bengali :: proc(t: ^testing.T, text: string) -> (Beng_Test_Ctx, bool) {
	ctx: Beng_Test_Ctx
	bytes, oerr := os.read_entire_file_from_path(NOTO_BENG, context.allocator)
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
	opts := shape.Shape_Run_Opts{script = parse.tag("beng"), language = parse.DFLT_LANG}
	shape.shape_run(&inputs, opts, text, 48.0, &out)

	ctx.gids = make([]parse.Glyph_ID, len(out))
	for sg, i in out { ctx.gids[i] = sg.glyph_id }
	return ctx, true
}

@(test)
test_bengali_single_consonant :: proc(t: ^testing.T) {
	ctx, ok := shape_bengali(t, "ক") // KA
	if !ok { return }
	defer beng_test_destroy(&ctx)
	// HarfBuzz: [20]
	testing.expect_value(t, len(ctx.gids), 1)
	testing.expect_value(t, int(ctx.gids[0]), 20)
}

@(test)
test_bengali_kta_akhand :: proc(t: ^testing.T) {
	ctx, ok := shape_bengali(t, "ক্ত") // KA + VIRAMA + TA -> akhand ligature
	if !ok { return }
	defer beng_test_destroy(&ctx)
	// HarfBuzz: [287] — single ligated glyph via `akhn`.
	testing.expect_value(t, len(ctx.gids), 1)
	testing.expect_value(t, int(ctx.gids[0]), 287)
}

@(test)
test_bengali_reph :: proc(t: ^testing.T) {
	ctx, ok := shape_bengali(t, "র্ক") // RA + VIRAMA + KA
	if !ok { return }
	defer beng_test_destroy(&ctx)
	// HarfBuzz: [20, 131] — base k + reph.
	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 20)
	testing.expect_value(t, int(ctx.gids[1]), 131)
}

@(test)
test_bengali_pre_base_matra :: proc(t: ^testing.T) {
	ctx, ok := shape_bengali(t, "কি") // KA + I-MATRA (Visual_Order_Left)
	if !ok { return }
	defer beng_test_destroy(&ctx)
	// HarfBuzz: [55, 20] — i-matra rendered BEFORE base k.
	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 55)
	testing.expect_value(t, int(ctx.gids[1]), 20)
}

@(test)
test_bengali_post_base_matra :: proc(t: ^testing.T) {
	ctx, ok := shape_bengali(t, "কী") // KA + II-MATRA (no reorder)
	if !ok { return }
	defer beng_test_destroy(&ctx)
	// HarfBuzz: [20, 56] — encoded order kept.
	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 20)
	testing.expect_value(t, int(ctx.gids[1]), 56)
}
