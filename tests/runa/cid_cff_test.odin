// CID-keyed CFF1 outlines. A CID font's Top DICT has ROS (no top-level
// Private); each glyph takes its local subrs from one of many Font DICTs
// in an FDArray, chosen per-glyph by FDSelect. Before that machinery was
// wired onto the CFF1 path, every glyph calling a local subr came out
// blank — most of Noto Sans CJK / Source Han. Needs the system
// fonts-noto-cjk package; skips when absent, like the other font tests.
package runa_test

import "core:log"
import "core:testing"
import runa "../../"

@(private="file")
NOTO_CJK :: "tests/fonts/NotoSansCJK.ttc"

@(test)
test_cid_cff_glyphs_draw :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes(NOTO_CJK)
	if !ok {
		log.info("NotoSansCJK.ttc not present; skipping CID-CFF test")
		return
	}
	defer delete(bytes)

	// It's a collection: font_load rejects it, font_load_face picks a face.
	testing.expect(t, runa.font_num_faces(bytes) >= 2, "Noto CJK is a collection")
	_, plain_err := runa.font_load(bytes)
	testing.expect_value(t, plain_err, runa.Error.Unsupported_Format)

	font, err := runa.font_load_face(bytes, 0)
	testing.expect_value(t, err, runa.Error.None)
	defer runa.font_destroy(&font)

	testing.expect(t, font._has_cff, "Noto CJK face 0 is CFF")
	testing.expect(t, font._cff.is_cid, "Noto CJK is CID-keyed (ROS in Top DICT)")

	// Each of these exercises per-FD local subrs — all blank before the fix.
	out := runa.Outline{}
	defer runa.outline_destroy(&out)
	for r in ([]rune{'語', 'フ', 'イ', '混', 'ざ', '文', '安', '하', '세'}) {
		gid := runa.font_lookup_glyph(&font, r)
		testing.expectf(t, gid != 0, "%r must be in the cmap", r)
		oerr := runa.font_glyph_outline(&font, gid, &out)
		testing.expect_value(t, oerr, runa.Error.None)
		testing.expectf(t, len(out.points) > 0, "%r must produce an outline (got 0 points)", r)
	}
}
