/*
Micro-profile of `shape_run` on a 5000-word paragraph. Prints
elapsed time for each stage so we can see where the cold path
spends its budget.
*/
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import runa  "../"
import parse "../parse"
import shape "../shape"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: shape_profile <font.ttf>")
		os.exit(2)
	}

	bytes, _ := os.read_entire_file_from_path(os.args[1], context.allocator)
	defer delete(bytes)

	font, err := runa.font_load(bytes)
	if err != .None { fmt.eprintfln("err: %v", err); os.exit(1) }
	defer runa.font_destroy(&font)

	words := [?]string{"the","quick","brown","fox","jumps","over","the","lazy","dog","and","then","runs","across","a","meadow","where","small","birds","are","singing"}
	b := strings.builder_make()
	for i in 0..<5000 {
		if i > 0 { fmt.sbprint(&b, " ") }
		fmt.sbprint(&b, words[i % len(words)])
	}
	text := strings.to_string(b)

	stack := runa.Font_Stack{&font}
	opts := runa.Paragraph_Opts{fonts = stack, size = 16}

	// Warm up.
	for _ in 0..<3 { _, _ = runa.measure_text(text, opts) }

	inputs := shape.Shape_Inputs{
		cmap         = &font._cmap,
		hmtx         = &font._hmtx,
		gsub         = &font._gsub if font._has_gsub else nil,
		gpos         = &font._gpos if font._has_gpos else nil,
		units_per_em = font.units_per_em,
	}
	sopts := shape.Shape_Run_Opts{script = parse.LATN_SCRIPT, language = parse.DFLT_LANG}

	// Full shape_run timed.
	for run_i in 0..<3 {
		free_all(context.temp_allocator)
		out := make([dynamic]shape.Shaped_Glyph, 0, len(text))
		t0 := time.now()
		shape.shape_run(&inputs, sopts, text, 16, &out)
		elapsed := time.since(t0)
		fmt.printfln("shape_run #%d: %v  (%d glyphs)", run_i, elapsed, len(out))
		delete(out)
	}

	// Shape stage-by-stage replica.
	for run_i in 0..<3 {
		free_all(context.temp_allocator)

		t_total := time.now()

		gids := make([dynamic]parse.Glyph_ID, 0, len(text), context.temp_allocator)
		clusters := make([dynamic]u32, 0, len(text), context.temp_allocator)
		t0 := time.now()
		byte_idx: u32 = 0
		for r in text {
			append(&gids, parse.cmap_lookup(&font._cmap, r))
			append(&clusters, byte_idx)
			if r < 0x80      { byte_idx += 1 }
			else if r < 0x800   { byte_idx += 2 }
			else if r < 0x10000 { byte_idx += 3 }
			else               { byte_idx += 4 }
		}
		t_walk := time.since(t0)

		t1 := time.now()
		t_gsub_each: [6]time.Duration
		feats := [?]parse.Tag{parse.tag("ccmp"), parse.tag("locl"), parse.tag("rlig"), parse.tag("liga"), parse.tag("clig"), parse.tag("calt")}
		for ft, fi in feats {
			ts := time.now()
			parse.gsub_apply_feature(&font._gsub, &gids, parse.LATN_SCRIPT, parse.DFLT_LANG, ft)
			t_gsub_each[fi] = time.since(ts)
		}
		t_gsub := time.since(t1)

		t2 := time.now()
		adjusts := make([]parse.Pos_Adjust, len(gids), context.temp_allocator)
		t_adj := time.since(t2)

		t3 := time.now()
		parse.gpos_apply_feature(&font._gpos, gids[:], adjusts, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("kern"))
		t_gpos := time.since(t3)

		t4 := time.now()
		out2 := make([dynamic]shape.Shaped_Glyph, 0, len(gids))
		scale := f32(16) / f32(font.units_per_em)
		for i in 0..<len(gids) {
			m := parse.hmtx_glyph_metric(&font._hmtx, gids[i])
			append(&out2, shape.Shaped_Glyph{
				glyph_id  = gids[i],
				x_advance = f32(m.advance_width) * scale,
			})
		}
		t_emit := time.since(t4)
		delete(out2)

		t_all := time.since(t_total)
		fmt.printfln("stages #%d:  total=%v  walk=%v  gsub=%v (per: %v)  adj=%v  gpos=%v  emit=%v",
		             run_i, t_all, t_walk, t_gsub, t_gsub_each, t_adj, t_gpos, t_emit)
	}

	// Codepoint walk only.
	for run_i in 0..<3 {
		t0 := time.now()
		count := 0
		for r in text {
			_ = parse.cmap_lookup(&font._cmap, r)
			count += 1
		}
		fmt.printfln("cmap-walk only #%d: %v  (%d cps)", run_i, time.since(t0), count)
	}

	// Single feature apply only.
	for run_i in 0..<3 {
		gids := make([dynamic]parse.Glyph_ID, 0, len(text))
		defer delete(gids)
		for r in text {
			append(&gids, parse.cmap_lookup(&font._cmap, r))
		}
		t0 := time.now()
		n := parse.gsub_apply_feature(&font._gsub, &gids, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("liga"))
		fmt.printfln("liga only #%d: %v  (%d substitutions, %d -> %d glyphs)", run_i, time.since(t0), n, len(text), len(gids))
		free_all(context.temp_allocator)
	}

	// GPOS kern timing.
	for run_i in 0..<3 {
		gids := make([]parse.Glyph_ID, 26000)
		defer delete(gids)
		for i in 0..<len(gids) { gids[i] = 50 }     // doesn't matter for timing
		adjusts := make([]parse.Pos_Adjust, len(gids))
		defer delete(adjusts)
		t0 := time.now()
		n := parse.gpos_apply_feature(&font._gpos, gids, adjusts, parse.LATN_SCRIPT, parse.DFLT_LANG, parse.tag("kern"))
		fmt.printfln("kern only #%d: %v  (%d adjustments)", run_i, time.since(t0), n)
		free_all(context.temp_allocator)
	}
}
