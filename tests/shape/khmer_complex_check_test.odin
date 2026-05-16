/*
Khmer complex-cluster shaping — exercises the multi-consonant
COENG-driven subscripts plus pre-base vowel reorder. With the
"pre-base matra moves to start of cluster" rule in indic.odin,
the canonical Khmer word matches HarfBuzz byte-for-byte.
*/
package shape_test

import "core:os"
import "core:testing"

import runa  "../.."
import shape "../../shape"
import parse "../../parse"

@(test)
test_khmer_khmer_word :: proc(t: ^testing.T) {
	bytes, oerr := os.read_entire_file_from_path("tests/fonts/Khmer.ttf", context.allocator)
	if oerr != nil { return }
	defer delete(bytes)
	f, ferr := runa.font_load(bytes)
	if ferr != .None { return }
	defer runa.font_destroy(&f)

	out := make([dynamic]shape.Shaped_Glyph, 0, 16)
	defer delete(out)
	inputs := shape.Shape_Inputs{
		cmap = &f._cmap, hmtx = &f._hmtx,
		gsub = &f._gsub, gpos = &f._gpos, units_per_em = f.units_per_em,
	}
	opts := shape.Shape_Run_Opts{script = parse.tag("khmr"), language = parse.DFLT_LANG}
	// "ខ្មែរ" — KHA + COENG + MA + AE + RA. The Khmer word for "Khmer".
	// HarfBuzz: [108, 26, 192, 54] — AE (pre-base) moves to start,
	// COENG+MA collapse into subscript-MA glyph, base KHA + RA round
	// out the cluster.
	shape.shape_run(&inputs, opts, "ខ្មែរ", 48.0, &out)
	testing.expect_value(t, len(out), 4)
	if len(out) >= 4 {
		testing.expect_value(t, int(out[0].glyph_id), 108)
		testing.expect_value(t, int(out[1].glyph_id), 26)
		testing.expect_value(t, int(out[2].glyph_id), 192)
		testing.expect_value(t, int(out[3].glyph_id), 54)
	}
}
