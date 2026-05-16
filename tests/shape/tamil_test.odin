/*
Tamil shaper smoke tests. Tamil quirks: no reph (uses visible
pulli instead), I-matra IPC = Right (doesn't reorder pre-base).
*/
package shape_test

import "core:os"
import "core:testing"

import runa  "../.."
import shape "../../shape"
import parse "../../parse"

NOTO_TAML :: "tests/fonts/NotoSansTamil.ttf"

Taml_Test_Ctx :: struct {
	font:  runa.Font,
	bytes: []u8,
	gids:  []parse.Glyph_ID,
}

taml_test_destroy :: proc(c: ^Taml_Test_Ctx) {
	delete(c.gids)
	runa.font_destroy(&c.font)
	delete(c.bytes)
}

shape_tamil :: proc(t: ^testing.T, text: string) -> (Taml_Test_Ctx, bool) {
	ctx: Taml_Test_Ctx
	bytes, oerr := os.read_entire_file_from_path(NOTO_TAML, context.allocator)
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
	opts := shape.Shape_Run_Opts{script = parse.tag("taml"), language = parse.DFLT_LANG}
	shape.shape_run(&inputs, opts, text, 48.0, &out)

	ctx.gids = make([]parse.Glyph_ID, len(out))
	for sg, i in out { ctx.gids[i] = sg.glyph_id }
	return ctx, true
}

@(test)
test_tamil_single_consonant :: proc(t: ^testing.T) {
	ctx, ok := shape_tamil(t, "க") // KA
	if !ok { return }
	defer taml_test_destroy(&ctx)
	// HarfBuzz: [18]
	testing.expect_value(t, len(ctx.gids), 1)
	testing.expect_value(t, int(ctx.gids[0]), 18)
}

@(test)
test_tamil_no_reph_for_ra :: proc(t: ^testing.T) {
	ctx, ok := shape_tamil(t, "ர்க") // RA + VIRAMA + KA — pulli'd, not reph
	if !ok { return }
	defer taml_test_destroy(&ctx)
	// HarfBuzz: [90, 18] — composed (RA + pulli) glyph, then base k.
	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 90)
	testing.expect_value(t, int(ctx.gids[1]), 18)
}

@(test)
test_tamil_no_pre_base_reorder :: proc(t: ^testing.T) {
	ctx, ok := shape_tamil(t, "கி") // KA + I (Tamil IPC=Right, no reorder)
	if !ok { return }
	defer taml_test_destroy(&ctx)
	// HarfBuzz: [18, 166] — encoded order kept.
	testing.expect_value(t, len(ctx.gids), 2)
	testing.expect_value(t, int(ctx.gids[0]), 18)
	testing.expect_value(t, int(ctx.gids[1]), 166)
}
