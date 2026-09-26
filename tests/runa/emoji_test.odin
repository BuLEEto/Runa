// Emoji + variation-selector layout. VS16 (U+FE0F) is a default-ignorable
// that no text font covers; it routes to the emoji fallback font, which
// ships no space glyph, so the old zero-advance-space substitution turned
// it into .notdef — an emoji followed by a visible box (rikkiti req 152).
package runa_test

import "core:testing"
import runa "../../"

@(private="file")
INTER   :: "tests/fonts/InterVariable.ttf"
@(private="file")
TWEMOJI :: "tests/fonts/Twemoji-Mozilla.ttf"

// layout_paragraph over a {text, emoji} stack must never emit .notdef for a
// default-ignorable, and the selector must add no width.
@(test)
test_emoji_variation_selector_no_notdef_box :: proc(t: ^testing.T) {
	ib, ok := load_font_bytes(INTER)
	if !ok { return }
	defer delete(ib)
	inter, _ := runa.font_load(ib)
	defer runa.font_destroy(&inter)

	tb, tok := load_font_bytes(TWEMOJI)
	if !tok { return }
	defer delete(tb)
	twem, _ := runa.font_load(tb)
	defer runa.font_destroy(&twem)

	stack := runa.Font_Stack{&inter, &twem}

	for pair in ([]string{"❤️", "✌️", "❄️", "✈️"}) {
		base := pair[:len(pair)-3] // strip the 3-byte U+FE0F

		opts := runa.Paragraph_Opts{fonts = stack, size = 28}
		lines, err := runa.layout_paragraph(pair, opts)
		testing.expect_value(t, err, runa.Error.None)
		defer { for &l in lines { runa.line_destroy(&l) }; delete(lines) }

		w_pair, _ := runa.measure_text(pair, opts)
		w_base, _ := runa.measure_text(base, opts)

		prev := -1
		for line in lines {
			for g in line.glyphs {
				testing.expectf(t, g.glyph_id != 0, "%q: no glyph may be .notdef", pair)
				c := int(g.cluster)
				testing.expectf(t, c >= prev, "%q: clusters non-decreasing", pair)
				testing.expectf(t, c >= 0 && c < len(pair), "%q: cluster names a real byte", pair)
				prev = c
			}
		}

		// The selector paints nothing and costs no width: base+VS16 measures
		// exactly as the base alone.
		testing.expectf(t, abs(w_pair - w_base) < 0.01,
			"%q width %.2f should equal base %.2f (VS16 adds no width)", pair, w_pair, w_base)
	}
}
