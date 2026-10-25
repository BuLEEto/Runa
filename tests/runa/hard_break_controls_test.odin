// Hard line/paragraph-break controls (LF, CR, NEL, LS, PS, VT, FF) must not
// paint. A font's cmap maps them to .notdef, and many fonts ship a *drawable*
// .notdef box (SF Compact, Roboto, …), so without blanking they draw a visible
// box at every hard break. They must stay in the cluster stream (layout + source
// mapping depend on it) as a zero-advance, non-drawn glyph. Reported upstream
// against v1.5.1 on macOS/SF Compact; reproduces on any font with a drawn .notdef.
package runa_test

import "core:fmt"
import "core:testing"
import runa "../../"

@(private="file")
HARD_BREAKS :: []rune{'\n', '\r', '\u0085', ' ', ' ', '\u000B', '\u000C'}

@(test)
test_hard_break_controls_blanked :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/Roboto-Regular.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	// Premise: Roboto's .notdef is actually drawable, else the test is vacuous.
	nd := runa.Outline{}
	runa.font_glyph_outline(&font, 0, &nd)
	premise := len(nd.contour_ends) > 0
	runa.outline_destroy(&nd)
	testing.expect(t, premise, "Roboto .notdef must be drawable for this test to mean anything")

	for r in HARD_BREAKS {
		text := fmt.tprintf("a%rb", r)          // control sits at byte cluster 1
		sg := make([dynamic]runa.Shaped_Glyph, 0, 4, context.temp_allocator)
		runa.shape_text(&font, text, 32, &sg)

		seen := 0
		for g in sg {
			if int(g.cluster) == 1 {
				seen += 1
				testing.expectf(t, g.glyph_id != 0, "U+%04X must not emit a .notdef glyph", r)
				testing.expectf(t, g.x_advance == 0, "U+%04X must have zero advance (got %.2f)", r, g.x_advance)
			}
		}
		testing.expectf(t, seen == 1, "U+%04X must stay in the cluster stream exactly once (got %d)", r, seen)
	}
}

// TAB a font doesn't map (cmap → .notdef) is whitespace, not a break: it
// renders as the font's space (one space wide), never a .notdef box. Inter
// leaves tab unmapped (unlike Roboto, which has its own tab glyph), so it
// exercises the fix.
@(test)
test_tab_renders_as_space :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/InterVariable.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	space := runa.font_lookup_glyph(&font, ' ')
	sp := make([dynamic]runa.Shaped_Glyph, 0, 2, context.temp_allocator)
	runa.shape_text(&font, " ", 32, &sp)
	space_adv := len(sp) > 0 ? sp[0].x_advance : 0

	sg := make([dynamic]runa.Shaped_Glyph, 0, 4, context.temp_allocator)
	runa.shape_text(&font, "a\tb", 32, &sg)
	for g in sg {
		if int(g.cluster) == 1 {
			testing.expect_value(t, g.glyph_id, space)        // tab → space glyph (no box)
			testing.expect(t, abs(g.x_advance - space_adv) < 0.01, "tab must be one space wide")
		}
	}
}

// C0 / C1 / DEL controls blank to a zero-advance space — present in the cluster
// stream, never a .notdef box, no width.
@(test)
test_nonprinting_controls_blanked :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/Roboto-Regular.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	for r in ([]rune{'\u0001', '\u0007', '\u001F', '\u007F', '\u0090'}) {
		text := fmt.tprintf("a%rb", r)
		sg := make([dynamic]runa.Shaped_Glyph, 0, 4, context.temp_allocator)
		runa.shape_text(&font, text, 32, &sg)
		seen := 0
		for g in sg {
			if int(g.cluster) == 1 {
				seen += 1
				testing.expectf(t, g.glyph_id != 0, "U+%04X must not emit .notdef", r)
				testing.expectf(t, g.x_advance == 0, "U+%04X must have zero advance", r)
			}
		}
		testing.expectf(t, seen == 1, "U+%04X must stay in the cluster stream once", r)
	}
}

// Genuinely missing *printable* glyphs are still .notdef — that box is correct.
@(test)
test_missing_printable_still_notdef :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/Roboto-Regular.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	// A CJK ideograph Roboto doesn't cover must still map to .notdef (gid 0).
	gid := runa.font_lookup_glyph(&font, '語')
	testing.expect_value(t, gid, u16(0))
	sg := make([dynamic]runa.Shaped_Glyph, 0, 2, context.temp_allocator)
	runa.shape_text(&font, "語", 32, &sg)
	testing.expect(t, len(sg) == 1 && sg[0].glyph_id == 0, "missing printable glyph stays .notdef")
}

// Layout case from the report: a hard break splits the paragraph but leaves no
// drawable .notdef in the produced lines. Covers LF, CRLF, empty + trailing lines.
@(test)
test_newline_no_notdef_in_layout :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/Roboto-Regular.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	stack := runa.Font_Stack{&font}
	for text in ([]string{"first\nsecond", "first\r\nsecond", "a\n\nb", "first\n"}) {
		lines, err := runa.layout_paragraph(text, runa.Paragraph_Opts{fonts = stack, size = 32})
		testing.expect_value(t, err, runa.Error.None)
		for ln in lines {
			for g in ln.glyphs {
				testing.expectf(t, g.glyph_id != 0, "a laid-out line of %q must hold no .notdef glyph", text)
			}
		}
		for &l in lines { runa.line_destroy(&l) }
		delete(lines)
	}
}
