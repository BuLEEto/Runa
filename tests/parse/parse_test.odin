/*
Parser tests. Some run against real bundled fonts (skipped with a warn
log if the font isn't present yet — local dev points at system fonts
via symlinks in tests/fonts/); others build synthetic byte slices to
exercise the error paths.
*/
package parse_test

import "core:log"
import "core:os"
import "core:testing"

import parse "../../parse"

ROBOTO   :: "tests/fonts/Roboto-Regular.ttf"
FIRACODE :: "tests/fonts/FiraCode-Regular.ttf"

@(private)
load_font :: proc(path: string) -> (data: []u8, ok: bool) {
	bytes, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return nil, false
	}
	return bytes, true
}

@(test)
test_table_index_roboto :: proc(t: ^testing.T) {
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, err := parse.parse_table_index(data)
	testing.expect_value(t, err, parse.Error.None)
	defer parse.table_index_destroy(&idx)

	testing.expect(t, parse.is_truetype(&idx), "Roboto-Regular is a TrueType-flavoured SFNT")
	testing.expect(t, parse.has_table(&idx, parse.tag("head")), "head table present")
	testing.expect(t, parse.has_table(&idx, parse.tag("maxp")), "maxp table present")
	testing.expect(t, parse.has_table(&idx, parse.tag("cmap")), "cmap table present")
	testing.expect(t, parse.has_table(&idx, parse.tag("glyf")), "glyf table present")
}

@(test)
test_head_roboto :: proc(t: ^testing.T) {
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, err := parse.parse_table_index(data)
	testing.expect_value(t, err, parse.Error.None)
	defer parse.table_index_destroy(&idx)

	head_bytes, ferr := parse.find_table(&idx, data, parse.tag("head"))
	testing.expect_value(t, ferr, parse.Error.None)

	head, herr := parse.parse_head(head_bytes)
	testing.expect_value(t, herr, parse.Error.None)

	// Roboto-Regular ships at unitsPerEm = 2048 (the canonical TrueType
	// power-of-two used by Microsoft fonts). Confirmed via `ttx -t head`.
	testing.expect_value(t, head.units_per_em, u16(2048))
	// `index_to_loc_format` flips between Short and Long across
	// Roboto releases (size-dependent). We just check the parser
	// returned one of the two valid variants.
	ok_fmt := head.index_to_loc_format == .Short || head.index_to_loc_format == .Long
	testing.expect(t, ok_fmt, "valid index_to_loc_format")
}

@(test)
test_maxp_roboto :: proc(t: ^testing.T) {
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, err := parse.parse_table_index(data)
	testing.expect_value(t, err, parse.Error.None)
	defer parse.table_index_destroy(&idx)

	maxp_bytes, ferr := parse.find_table(&idx, data, parse.tag("maxp"))
	testing.expect_value(t, ferr, parse.Error.None)

	mx, mxerr := parse.parse_maxp(maxp_bytes)
	testing.expect_value(t, mxerr, parse.Error.None)

	// A real font has thousands of glyphs; the exact number drifts
	// between Roboto releases. Use a sanity floor.
	testing.expect(t, mx.num_glyphs > 100, "Roboto has more than 100 glyphs")
}

@(test)
test_table_index_rejects_truncated :: proc(t: ^testing.T) {
	// Empty buffer: not enough bytes for the version field.
	idx, err := parse.parse_table_index([]u8{})
	testing.expect_value(t, err, parse.Error.Invalid_Table)
	_ = idx
}

@(test)
test_table_index_rejects_ttc :: proc(t: ^testing.T) {
	// TTC header: 'ttcf' magic at offset 0.
	ttc := []u8{'t', 't', 'c', 'f', 0, 1, 0, 0, 0, 0, 0, 1}
	_, err := parse.parse_table_index(ttc)
	testing.expect_value(t, err, parse.Error.Unsupported_Format)
}

@(test)
test_table_index_rejects_bad_magic :: proc(t: ^testing.T) {
	// 12 bytes of garbage that isn't any known SFNT magic.
	bad := []u8{0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0}
	_, err := parse.parse_table_index(bad)
	testing.expect_value(t, err, parse.Error.Invalid_Table)
}

@(test)
test_head_rejects_bad_magic :: proc(t: ^testing.T) {
	// A 54-byte head table with the magic field wrong.
	bytes := make([]u8, 54)
	defer delete(bytes)
	// Leave the magic at offset 12 as zero — head expects 0x5F0F3CF5.
	_, err := parse.parse_head(bytes)
	testing.expect_value(t, err, parse.Error.Invalid_Table)
}

@(test)
test_reader_overrun_returns_error :: proc(t: ^testing.T) {
	r := parse.Reader{data = []u8{1, 2}}
	_, e1 := parse.read_u16(&r)
	testing.expect_value(t, e1, parse.Error.None)
	_, e2 := parse.read_u16(&r)             // empty now
	testing.expect_value(t, e2, parse.Error.Invalid_Table)
}

@(test)
test_tag_packs_big_endian :: proc(t: ^testing.T) {
	// 'head' = 0x68_65_61_64 packed big-endian.
	testing.expect_value(t, parse.tag("head"), parse.Tag(0x68656164))
}

@(test)
test_cmap_roboto_basic :: proc(t: ^testing.T) {
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, err := parse.parse_table_index(data)
	testing.expect_value(t, err, parse.Error.None)
	defer parse.table_index_destroy(&idx)

	cmap_bytes, ferr := parse.find_table(&idx, data, parse.tag("cmap"))
	testing.expect_value(t, ferr, parse.Error.None)

	cm, cerr := parse.parse_cmap(cmap_bytes)
	testing.expect_value(t, cerr, parse.Error.None)
	defer parse.cmap_destroy(&cm)

	// 'A' (U+0041) is part of basic Latin and must resolve.
	a := parse.cmap_lookup(&cm, 'A')
	testing.expect(t, a != 0, "Roboto maps 'A'")

	// Space is special-cased in some fonts; should still be present.
	sp := parse.cmap_lookup(&cm, ' ')
	testing.expect(t, sp != 0, "Roboto maps space")

	// U+FFFE is a non-character — guaranteed never to map.
	missing := parse.cmap_lookup(&cm, '￾')
	testing.expect_value(t, missing, parse.Glyph_ID(0))
}

@(test)
test_cmap_firacode_ligature_codepoints :: proc(t: ^testing.T) {
	data, ok := load_font(FIRACODE)
	if !ok {
		log.info("FiraCode-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, err := parse.parse_table_index(data)
	testing.expect_value(t, err, parse.Error.None)
	defer parse.table_index_destroy(&idx)

	cmap_bytes, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, cerr := parse.parse_cmap(cmap_bytes)
	testing.expect_value(t, cerr, parse.Error.None)
	defer parse.cmap_destroy(&cm)

	// Programming-font fundamentals: 'f', 'i', '-', '>', '='.
	test_runes := [?]rune{'f', 'i', '-', '>', '='}
	for cp in test_runes {
		g := parse.cmap_lookup(&cm, cp)
		testing.expect(t, g != 0, "FiraCode maps printable ASCII")
	}
}

@(test)
test_cmap_rejects_bad_version :: proc(t: ^testing.T) {
	// version != 0 is malformed.
	bad := []u8{0, 1, 0, 0}
	_, err := parse.parse_cmap(bad)
	testing.expect_value(t, err, parse.Error.Invalid_Table)
}

@(test)
test_hhea_hmtx_roboto :: proc(t: ^testing.T) {
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, err := parse.parse_table_index(data)
	testing.expect_value(t, err, parse.Error.None)
	defer parse.table_index_destroy(&idx)

	hhea_bytes, _ := parse.find_table(&idx, data, parse.tag("hhea"))
	hh, hherr := parse.parse_hhea(hhea_bytes)
	testing.expect_value(t, hherr, parse.Error.None)

	// Roboto's vertical metrics are positive ascent / negative descent —
	// the canonical orientation. Sanity-floor only; numbers shift across
	// Roboto releases.
	testing.expect(t, hh.ascender  > 0, "ascender positive")
	testing.expect(t, hh.descender < 0, "descender negative")
	testing.expect(t, hh.number_of_h_metrics > 0, "at least one hMetric")

	maxp_bytes, _ := parse.find_table(&idx, data, parse.tag("maxp"))
	mx, _ := parse.parse_maxp(maxp_bytes)

	hmtx_bytes, _ := parse.find_table(&idx, data, parse.tag("hmtx"))
	hmtx, hmerr := parse.new_hmtx(hmtx_bytes, hh.number_of_h_metrics, mx.num_glyphs)
	testing.expect_value(t, hmerr, parse.Error.None)

	// Look up 'A' via cmap, then check its advance is non-zero.
	cmap_bytes, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_bytes)
	defer parse.cmap_destroy(&cm)

	gid := parse.cmap_lookup(&cm, 'A')
	testing.expect(t, gid != 0, "'A' resolves")

	m := parse.hmtx_glyph_metric(&hmtx, gid)
	testing.expect(t, m.advance_width > 0, "'A' has non-zero advance width")
}

@(test)
test_loca_glyf_roboto :: proc(t: ^testing.T) {
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	head_bytes, _ := parse.find_table(&idx, data, parse.tag("head"))
	head, _ := parse.parse_head(head_bytes)

	maxp_bytes, _ := parse.find_table(&idx, data, parse.tag("maxp"))
	mx, _ := parse.parse_maxp(maxp_bytes)

	loca_bytes, _ := parse.find_table(&idx, data, parse.tag("loca"))
	loca, lerr := parse.parse_loca(loca_bytes, head.index_to_loc_format, mx.num_glyphs)
	testing.expect_value(t, lerr, parse.Error.None)
	defer parse.loca_destroy(&loca)

	glyf_bytes, _ := parse.find_table(&idx, data, parse.tag("glyf"))
	g := parse.new_glyf(glyf_bytes)

	cmap_bytes, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_bytes)
	defer parse.cmap_destroy(&cm)

	gid := parse.cmap_lookup(&cm, 'A')
	testing.expect(t, gid != 0, "'A' resolves")

	out := parse.Outline{}
	defer parse.outline_destroy(&out)

	oerr := parse.glyf_outline(&g, &loca, gid, &out)
	testing.expect_value(t, oerr, parse.Error.None)

	testing.expect(t, len(out.contour_ends) > 0, "'A' has at least one contour")
	testing.expect(t, len(out.points) > 0, "'A' has outline points")

	// Sanity: the bounding box should enclose at least one point.
	testing.expect(t, out.x_max > out.x_min, "x bbox is non-empty")
	testing.expect(t, out.y_max > out.y_min, "y bbox is non-empty")
}

@(test)
test_glyf_composite_accent :: proc(t: ^testing.T) {
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	head_bytes, _ := parse.find_table(&idx, data, parse.tag("head"))
	head, _ := parse.parse_head(head_bytes)

	maxp_bytes, _ := parse.find_table(&idx, data, parse.tag("maxp"))
	mx, _ := parse.parse_maxp(maxp_bytes)

	loca_bytes, _ := parse.find_table(&idx, data, parse.tag("loca"))
	loca, _ := parse.parse_loca(loca_bytes, head.index_to_loc_format, mx.num_glyphs)
	defer parse.loca_destroy(&loca)

	glyf_bytes, _ := parse.find_table(&idx, data, parse.tag("glyf"))
	g := parse.new_glyf(glyf_bytes)

	cmap_bytes, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_bytes)
	defer parse.cmap_destroy(&cm)

	// 'é' is canonically a composite of 'e' + combining acute. Roboto
	// encodes precomposed Latin Extended-A as composites for size.
	gid := parse.cmap_lookup(&cm, 'é')
	testing.expect(t, gid != 0, "'é' resolves in Roboto")

	out := parse.Outline{}
	defer parse.outline_destroy(&out)

	oerr := parse.glyf_outline(&g, &loca, gid, &out)
	testing.expect_value(t, oerr, parse.Error.None)

	// 'é' must contain at least two contours (the 'e' shape + the accent).
	testing.expect(t, len(out.contour_ends) >= 2, "'é' has multiple contours")
}

@(test)
test_hmtx_zero_metrics_rejected :: proc(t: ^testing.T) {
	// number_of_h_metrics == 0 is malformed — at least one long-metric
	// is required by spec.
	_, err := parse.new_hmtx([]u8{}, 0, 10)
	testing.expect_value(t, err, parse.Error.Invalid_Table)
}

@(test)
test_gsub_liga_roboto_fi :: proc(t: ^testing.T) {
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	if !parse.has_table(&idx, parse.tag("GSUB")) {
		log.info("Roboto build has no GSUB; skipping")
		return
	}
	gsub_b, _ := parse.find_table(&idx, data, parse.tag("GSUB"))
	g, gerr := parse.new_gsub(gsub_b)
	testing.expect_value(t, gerr, parse.Error.None)

	gids := make([dynamic]parse.Glyph_ID, 0, 4)
	defer delete(gids)
	append(&gids, parse.cmap_lookup(&cm, 'f'))
	append(&gids, parse.cmap_lookup(&cm, 'i'))
	testing.expect_value(t, len(gids), 2)

	parse.gsub_apply_feature(&g, &gids, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("liga"))

	// True ligature: two glyphs collapse to one.
	testing.expect_value(t, len(gids), 1)
}

@(test)
test_gsub_calt_firacode_arrow :: proc(t: ^testing.T) {
	data, ok := load_font(FIRACODE)
	if !ok {
		log.info("FiraCode-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	gsub_b, _ := parse.find_table(&idx, data, parse.tag("GSUB"))
	g, _ := parse.new_gsub(gsub_b)

	gids := make([dynamic]parse.Glyph_ID, 0, 4)
	defer delete(gids)
	append(&gids, parse.cmap_lookup(&cm, '-'))
	append(&gids, parse.cmap_lookup(&cm, '>'))
	before := []parse.Glyph_ID{gids[0], gids[1]}

	parse.gsub_apply_feature(&g, &gids, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("calt"))

	// FiraCode's calt is contextual styling, not collapsing. The glyph
	// count stays the same, but at least one glyph ID changes.
	testing.expect_value(t, len(gids), 2)
	changed := gids[0] != before[0] || gids[1] != before[1]
	testing.expect(t, changed, "calt rewrote '->' glyphs")
}

@(test)
test_gpos_kerning_roboto_AV :: proc(t: ^testing.T) {
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	if !parse.has_table(&idx, parse.tag("GPOS")) {
		log.info("Roboto build has no GPOS; skipping")
		return
	}

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	gpos_b, _ := parse.find_table(&idx, data, parse.tag("GPOS"))
	gp, gerr := parse.new_gpos(gpos_b)
	testing.expect_value(t, gerr, parse.Error.None)

	// 'A' followed by 'V' is the textbook negative-kern pair in every
	// Latin font. The adjustment must be a negative x_advance on the
	// first glyph.
	gids := []parse.Glyph_ID{parse.cmap_lookup(&cm, 'A'), parse.cmap_lookup(&cm, 'V')}
	adjusts := make([]parse.Pos_Adjust, 2)
	defer delete(adjusts)

	parse.gpos_apply_feature(&gp, gids, adjusts, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("kern"))
	testing.expect(t, adjusts[0].x_advance < 0, "A-V kerning must be negative")
}

TWEMOJI :: "tests/fonts/Twemoji-Mozilla.ttf"

@(test)
test_colr_cpal_fox :: proc(t: ^testing.T) {
	data, ok := load_font(TWEMOJI)
	if !ok {
		log.info("Twemoji-Mozilla.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	testing.expect(t, parse.has_table(&idx, parse.tag("COLR")), "COLR present")
	testing.expect(t, parse.has_table(&idx, parse.tag("CPAL")), "CPAL present")

	colr_b, _ := parse.find_table(&idx, data, parse.tag("COLR"))
	cpal_b, _ := parse.find_table(&idx, data, parse.tag("CPAL"))
	cr, cerr := parse.new_colr(colr_b)
	testing.expect_value(t, cerr, parse.Error.None)
	cp, perr := parse.new_cpal(cpal_b)
	testing.expect_value(t, perr, parse.Error.None)

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	fox_gid := parse.cmap_lookup(&cm, '🦊')
	testing.expect(t, fox_gid != 0, "fox glyph present")
	testing.expect(t, parse.colr_is_base(&cr, fox_gid), "fox is a colour base")

	layers, lerr := parse.colr_layers(&cr, fox_gid)
	testing.expect_value(t, lerr, parse.Error.None)
	defer delete(layers)
	testing.expect(t, len(layers) >= 4, "fox has multiple COLR layers")

	// Each layer's palette colour should be non-transparent.
	any_visible := false
	for lyr in layers {
		c := parse.cpal_lookup(&cp, 0, lyr.palette_index)
		if c.a > 0 { any_visible = true }
	}
	testing.expect(t, any_visible, "at least one layer is non-transparent")
}

NOTO_COLRV1 :: "tests/fonts/NotoColorEmoji-COLRv1.ttf"

@(test)
test_colr_v1_paint_tree :: proc(t: ^testing.T) {
	data, ok := load_font(NOTO_COLRV1)
	if !ok {
		log.info("NotoColorEmoji-COLRv1.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	colr_b, _ := parse.find_table(&idx, data, parse.tag("COLR"))
	cr, cerr := parse.new_colr(colr_b)
	testing.expect_value(t, cerr, parse.Error.None)
	testing.expect(t, cr.version >= 1, "COLR is v1")
	testing.expect(t, cr.v1_paint_count > 0, "BaseGlyphList non-empty")

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	// Grin-face emoji 😀 (U+1F600) is in every modern Noto Color Emoji.
	grin_gid := parse.cmap_lookup(&cm, 0x1F600)
	testing.expect(t, grin_gid != 0, "grin emoji glyph present")

	layers, lerr := parse.colr_layers(&cr, grin_gid)
	testing.expect_value(t, lerr, parse.Error.None)
	defer delete(layers)
	testing.expect(t, len(layers) > 0, "grin emoji produces at least one layer")
}

@(test)
test_colr_v1_brush_layers :: proc(t: ^testing.T) {
	data, ok := load_font(NOTO_COLRV1)
	if !ok {
		log.info("NotoColorEmoji-COLRv1.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	colr_b, _ := parse.find_table(&idx, data, parse.tag("COLR"))
	cr, cerr := parse.new_colr(colr_b)
	testing.expect_value(t, cerr, parse.Error.None)

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	// Sweep all base-glyph paint trees and confirm at least one
	// produces a Linear brush with non-degenerate stops. Noto Color
	// Emoji COLRv1 ships ~1500 emojis with linear-gradient layers.
	found_linear := false
	for g in 0..<int(cr.v1_paint_count) {
		layers := make([dynamic]parse.Colr_Brush_Layer, 0, 8)
		ok := parse.colr_v1_brush_layers(&cr, parse.Glyph_ID(g), &layers)
		if !ok { parse.colr_brush_layers_destroy(&layers); continue }
		for lyr in layers {
			if lyr.brush.kind == .Linear && len(lyr.brush.stops) >= 2 {
				found_linear = true
				testing.expect(t, lyr.brush.stops[0].offset <= lyr.brush.stops[len(lyr.brush.stops) - 1].offset, "stops ascending")
				testing.expect(t, lyr.brush.p0 != lyr.brush.p1, "gradient endpoints differ")
				break
			}
		}
		parse.colr_brush_layers_destroy(&layers)
		if found_linear { break }
	}
	_ = cm
	testing.expect(t, found_linear, "font produces at least one Linear brush")
}

SOURCE_CODE_VF :: "tests/fonts/SourceCodeVF.otf"

@(test)
test_cff2_variable_instance :: proc(t: ^testing.T) {
	data, ok := load_font(SOURCE_CODE_VF)
	if !ok {
		log.info("SourceCodeVF.otf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	cff2_bytes, _ := parse.find_table(&idx, data, parse.tag("CFF2"))
	cff2, _ := parse.new_cff2(cff2_bytes)
	defer parse.cff2_destroy(&cff2)

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	gid := parse.cmap_lookup(&cm, 'a')

	out_def: parse.Outline
	defer parse.outline_destroy(&out_def)
	_ = parse.cff2_glyph_outline(&cff2, gid, &out_def, nil)

	// Heavy: single-axis font, wght normalised to its maximum (+1).
	out_heavy: parse.Outline
	defer parse.outline_destroy(&out_heavy)
	axis := []f32{1.0}
	_ = parse.cff2_glyph_outline(&cff2, gid, &out_heavy, axis)

	// Both should produce non-empty outlines with the same contour
	// count, but the heavy instance should differ in at least one
	// point coordinate (gvar / blend changes the geometry).
	testing.expect(t, len(out_def.points)  > 0, "default outline has points")
	testing.expect(t, len(out_heavy.points) > 0, "heavy outline has points")
	testing.expect_value(t, len(out_def.contour_ends), len(out_heavy.contour_ends))
	differs := false
	min_len := min(len(out_def.points), len(out_heavy.points))
	for i in 0..<min_len {
		if out_def.points[i] != out_heavy.points[i] { differs = true; break }
	}
	testing.expect(t, differs, "non-default instance shifts at least one point")
}

@(test)
test_cff2_loads_and_outlines :: proc(t: ^testing.T) {
	data, ok := load_font(SOURCE_CODE_VF)
	if !ok {
		log.info("SourceCodeVF.otf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	testing.expect(t, parse.has_table(&idx, parse.tag("CFF2")), "CFF2 present")

	cff2_bytes, _ := parse.find_table(&idx, data, parse.tag("CFF2"))
	cff2, cerr := parse.new_cff2(cff2_bytes)
	testing.expect_value(t, cerr, parse.Error.None)
	defer parse.cff2_destroy(&cff2)

	testing.expect(t, cff2.num_glyphs > 100, "non-trivial glyph count")
	testing.expect(t, len(cff2.fdarray) >= 1, "at least one FD")
	testing.expect(t, cff2.default_num_regions >= 1, "VarStore parsed")

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	out: parse.Outline
	defer parse.outline_destroy(&out)
	gid_a := parse.cmap_lookup(&cm, 'a')
	testing.expect(t, gid_a != 0, "'a' glyph present")
	oerr := parse.cff2_glyph_outline(&cff2, gid_a, &out)
	testing.expect_value(t, oerr, parse.Error.None)
	testing.expect(t, len(out.points) > 0, "outline non-empty")
	testing.expect(t, len(out.contour_ends) >= 1, "at least one contour")
	testing.expect(t, out.x_max > out.x_min && out.y_max > out.y_min, "bbox sane")
}

LIBERTINE :: "tests/fonts/LinLibertine-Regular.otf"

@(test)
test_cff_loads_and_outlines :: proc(t: ^testing.T) {
	data, ok := load_font(LIBERTINE)
	if !ok {
		log.info("LinLibertine-Regular.otf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)

	testing.expect(t, parse.is_cff(&idx), "Linux Libertine is CFF-flavoured")
	testing.expect(t, parse.has_table(&idx, parse.tag("CFF ")), "CFF table present")

	cff_b, _ := parse.find_table(&idx, data, parse.tag("CFF "))
	c, cerr := parse.new_cff(cff_b)
	testing.expect_value(t, cerr, parse.Error.None)
	defer parse.cff_destroy(&c)

	testing.expect(t, c.num_glyphs > 100, "Linux Libertine has > 100 glyphs")
	testing.expect_value(t, c.charstring_type, 2)

	// Outline a known glyph (gid 0 = .notdef typically has a box;
	// gid 1 often has content; use the cmap to find 'A').
	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)
	gid := parse.cmap_lookup(&cm, 'A')
	testing.expect(t, gid != 0, "'A' resolves")

	out := parse.Outline{}
	defer parse.outline_destroy(&out)
	oerr := parse.cff_glyph_outline(&c, gid, &out)
	testing.expect_value(t, oerr, parse.Error.None)
	testing.expect(t, len(out.contour_ends) >= 1, "'A' has at least one contour")
	testing.expect(t, len(out.points)        > 10, "'A' has multiple flattened points")
	testing.expect(t, out.x_max > out.x_min, "x bbox non-empty")
	testing.expect(t, out.y_max > out.y_min, "y bbox non-empty")
}

@(test)
test_gpos_mark_to_base :: proc(t: ^testing.T) {
	// "a" (gid X) followed by COMBINING ACUTE (U+0301). With the
	// `mark` feature applied, the combining acute should receive a
	// non-zero placement so it lands over the 'a' rather than at the
	// pen position.
	data, ok := load_font(ROBOTO)
	if !ok {
		log.info("Roboto-Regular.ttf not present; skipping")
		return
	}
	defer delete(data)

	idx, _ := parse.parse_table_index(data)
	defer parse.table_index_destroy(&idx)
	if !parse.has_table(&idx, parse.tag("GPOS")) {
		log.info("Roboto build has no GPOS; skipping")
		return
	}

	cmap_b, _ := parse.find_table(&idx, data, parse.tag("cmap"))
	cm, _ := parse.parse_cmap(cmap_b)
	defer parse.cmap_destroy(&cm)

	gpos_b, _ := parse.find_table(&idx, data, parse.tag("GPOS"))
	gp, _ := parse.new_gpos(gpos_b)

	gids := []parse.Glyph_ID{parse.cmap_lookup(&cm, 'a'), parse.cmap_lookup(&cm, 0x0301)}
	if gids[0] == 0 || gids[1] == 0 {
		log.info("Roboto build doesn't carry both 'a' and U+0301; skipping")
		return
	}

	adjusts := make([]parse.Pos_Adjust, 2)
	defer delete(adjusts)

	parse.gpos_apply_feature(&gp, gids, adjusts, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("mark"))
	// The combining mark (index 1) should get a non-zero placement
	// from the mark-to-base lookup — it has to shift up + sideways
	// to land on the 'a' anchor.
	got_placement := adjusts[1].x_placement != 0 || adjusts[1].y_placement != 0
	testing.expect(t, got_placement, "combining acute receives a mark-to-base placement")
}

@(test)
test_cmap_unsupported_when_no_unicode :: proc(t: ^testing.T) {
	// version 0, one encoding record with (platform=99, encoding=99) —
	// not in our priority lists. Should bail with Unsupported_Format.
	bytes := []u8{
		0, 0,                                // version
		0, 1,                                // numTables
		0, 99, 0, 99, 0, 0, 0, 12,           // platformID, encodingID, offset
		0, 4, 0, 32,                         // bogus subtable header
	}
	_, err := parse.parse_cmap(bytes)
	testing.expect_value(t, err, parse.Error.Unsupported_Format)
}
