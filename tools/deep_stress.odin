/*
Deep stress: random axis tuples × every glyph × bidi-aware layout
on synthetic strings. Designed to catch latent panics / use-after-
free / leak issues that the lighter unit tests don't.

Run:
    odin run tools/deep_stress.odin -file -o:speed
*/
package main

import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:os"

import runa "../"
import bidi "../bidi"

main :: proc() {
	// Wrap the whole run in a tracking allocator so any per-call leak
	// surfaces at the end.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		fmt.println()
		if len(track.allocation_map) > 0 {
			fmt.printfln("LEAK SUMMARY: %d allocations not freed", len(track.allocation_map))
			for _, entry in track.allocation_map {
				fmt.printfln("  %d bytes at %v: %s:%d", entry.size, entry.memory, entry.location.file_path, entry.location.line)
			}
		} else {
			fmt.println("no leaks")
		}
		if len(track.bad_free_array) > 0 {
			fmt.printfln("BAD FREES: %d", len(track.bad_free_array))
		} else {
			fmt.println("no bad frees")
		}
		mem.tracking_allocator_destroy(&track)
	}

	font_bytes, _ := os.read_entire_file_from_path("tests/fonts/InterVariable.ttf", context.allocator)
	defer delete(font_bytes)
	font, ferr := runa.font_load(font_bytes)
	if ferr != .None { fmt.eprintfln("load: %v", ferr); os.exit(1) }
	defer runa.font_destroy(&font)

	// Also exercise the CFF path: load + outline-every-glyph in a
	// second pass so a Cff leak / panic surfaces here too.
	cff_bytes, cff_read_err := os.read_entire_file_from_path("tests/fonts/LinLibertine-Regular.otf", context.allocator)
	cff_loaded := false
	cff_font: runa.Font
	if cff_read_err == nil {
		f, e := runa.font_load(cff_bytes)
		if e == .None {
			cff_font = f
			cff_loaded = true
		}
	}
	defer if cff_loaded { runa.font_destroy(&cff_font) }
	defer delete(cff_bytes)

	// And the CFF2 path — variable-CFF outlines (Source Code VF).
	cff2_bytes, cff2_read_err := os.read_entire_file_from_path("tests/fonts/SourceCodeVF.otf", context.allocator)
	cff2_loaded := false
	cff2_font: runa.Font
	if cff2_read_err == nil {
		f, e := runa.font_load(cff2_bytes)
		if e == .None {
			cff2_font = f
			cff2_loaded = true
		}
	}
	defer if cff2_loaded { runa.font_destroy(&cff2_font) }
	defer delete(cff2_bytes)

	// Devanagari — exercises the Indic shaper + GSUB types 5 / 6.
	dev_bytes, dev_read_err := os.read_entire_file_from_path("tests/fonts/NotoSansDevanagari.ttf", context.allocator)
	dev_loaded := false
	dev_font: runa.Font
	if dev_read_err == nil {
		f, e := runa.font_load(dev_bytes)
		if e == .None {
			dev_font = f
			dev_loaded = true
		}
	}
	defer if dev_loaded { runa.font_destroy(&dev_font) }
	defer delete(dev_bytes)

	axes := runa.font_axes(&font)
	fmt.printfln("axes=%d glyphs=%d cff=%v", len(axes), font.num_glyphs, cff_loaded)

	rand.reset(0xDEADBEEF)
	stack := runa.Font_Stack{&font}

	// Mix of strings — pure LTR, pure RTL (will render as notdef in
	// Inter but exercises the bidi pipeline), mixed.
	texts := [?]string{
		"Hello, world!",
		"שלום",
		"abc 123 שלום xyz",
		"prompt + 31 completion",
		"",
		"a",
		"\n",
		"\tindented\n",
	}

	c := runa.cache_make(context.allocator)
	defer runa.cache_destroy(&c)

	ITERS :: 2000
	for iter in 0..<ITERS {
		// Random axis values.
		for ax in axes {
			t := rand.float32()
			v := ax.min_value + t * (ax.max_value - ax.min_value)
			runa.font_set_variation(&font, ax.tag, v)
		}

		// Random text + size.
		text := texts[int(rand.uint32()) % len(texts)]
		size := 10 + rand.float32() * 60

		opts := runa.Paragraph_Opts{
			fonts     = stack,
			size      = size,
			max_width = rand.uint32() % 4 == 0 ? 50 + rand.float32() * 200 : 0,
		}

		lines, err := runa.layout_paragraph(text, opts, &c)
		if err != .None { fmt.eprintfln("iter %d layout err: %v", iter, err) }
		for &l in lines { runa.line_destroy(&l) }
		delete(lines)

		// Also exercise measure_text + outline extraction.
		w, h := runa.measure_text(text, opts)
		_, _ = w, h

		// Walk a random glyph's outline.
		gid := runa.Glyph_ID(int(rand.uint32()) % int(font.num_glyphs))
		out := runa.Outline{}
		runa.font_glyph_outline(&font, gid, &out)
		runa.outline_destroy(&out)

		_ = bidi.paragraph_direction(text)
	}

	fmt.printfln("stress completed (%d iters)", ITERS)

	// CFF sweep: outline every glyph of Linux Libertine, then dispose.
	if cff_loaded {
		cff_out := runa.Outline{}
		for g in 0..<int(cff_font.num_glyphs) {
			runa.font_glyph_outline(&cff_font, runa.Glyph_ID(g), &cff_out)
		}
		runa.outline_destroy(&cff_out)
		fmt.printfln("cff sweep: %d glyphs", cff_font.num_glyphs)
	}

	// CFF2 sweep: outline every glyph of Source Code VF.
	if cff2_loaded {
		cff2_out := runa.Outline{}
		for g in 0..<int(cff2_font.num_glyphs) {
			runa.font_glyph_outline(&cff2_font, runa.Glyph_ID(g), &cff2_out)
		}
		runa.outline_destroy(&cff2_out)
		fmt.printfln("cff2 sweep: %d glyphs", cff2_font.num_glyphs)
	}

	// Devanagari shape stress: shape a handful of Indic syllables
	// against the Noto Devanagari font. Each call exercises the
	// Indic syllable detector, reordering, and GSUB types 5 / 6.
	if dev_loaded {
		dev_strings := [?]string{"क", "क्त", "र्क", "कि", "की", "श्री", "कर्म", "विद्या"}
		dev_opts := runa.Paragraph_Opts{
			fonts = runa.Font_Stack{&dev_font},
			size  = 24,
			align = .Start,
		}
		for _ in 0..<ITERS / 4 {
			for s in dev_strings {
				lines, err := runa.layout_paragraph(s, dev_opts)
				if err == .None {
					for &l in lines { runa.line_destroy(&l) }
					delete(lines)
				}
			}
		}
		fmt.printfln("devanagari sweep: %d strings × %d iters", len(dev_strings), ITERS / 4)
	}
}
