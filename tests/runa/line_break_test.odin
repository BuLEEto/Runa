// End-to-end Knuth–Plass line breaking through the single-font convenience:
// real shaping feeds the box/glue/penalty build, and the returned lines must
// tile the source text (spaces at a break discarded) and end at the text end.
package runa_test

import "core:strings"
import "core:testing"
import runa "../../"

@(private="file")
PARA :: "The quick brown fox jumps over the lazy dog while the sun sets slowly behind the distant rolling hills."

@(private="file")
check_tiling :: proc(t: ^testing.T, lines: []runa.Text_Line, text: string) {
	testing.expect(t, len(lines) > 0, "at least one line")
	testing.expect_value(t, lines[0].start, 0)
	testing.expect_value(t, lines[len(lines) - 1].end, len(text))
	for ln, i in lines {
		testing.expectf(t, ln.start >= 0 && ln.start <= ln.end && ln.end <= len(text),
			"line %d range [%d,%d) out of bounds", i, ln.start, ln.end)
		if i > 0 {
			// The next line starts at or after the previous end (the gap is
			// the discarded break space).
			testing.expectf(t, ln.start >= lines[i - 1].end, "line %d starts before previous end", i)
		}
	}
}

@(test)
test_break_text_wraps_and_tiles :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/Roboto-Regular.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	lines, got := runa.break_text(&font, PARA, 16, {260})
	defer delete(lines)
	testing.expect(t, got, "break_text succeeds")
	testing.expect(t, len(lines) >= 3, "a long paragraph at 260px wraps to several lines")
	check_tiling(t, lines, PARA)
}

// Degenerate inputs must still tile to the end of the text and never crash:
// empty, all-spaces, a bare newline, only soft hyphens, trailing newline.
@(test)
test_break_text_edge_cases :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/Roboto-Regular.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	for s in ([]string{" ", "   ", "\n", "\n\n", "x\ny", "a­b", "­", "end­"}) {
		for w in ([]f32{10, 60, 400}) {
			lines, got := runa.break_text(&font, s, 16, {w})
			if !got { testing.expectf(t, false, "ok=false for %q", s); continue }
			defer delete(lines)
			testing.expectf(t, lines[0].start == 0, "start!=0 for %q", s)
			testing.expectf(t, lines[len(lines)-1].end == len(s), "last end %d != len %d for %q", lines[len(lines)-1].end, len(s), s)
			prev := 0
			for ln in lines {
				testing.expectf(t, ln.start >= 0 && ln.start <= ln.end && ln.end <= len(s), "range oob for %q", s)
				testing.expectf(t, ln.start >= prev, "overlap for %q", s)
				prev = ln.end
			}
		}
	}
}

// Spaceless scripts must still wrap: break_text uses runa's UAX #14 engine,
// so CJK breaks between characters (not one overflowing line). Needs the
// system CJK collection; skips when absent.
@(test)
test_break_text_cjk_wraps :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/NotoSansCJK.ttc")
	if !ok { return }
	defer delete(bytes)
	font, ferr := runa.font_load_face(bytes, 0)
	if ferr != .None { return }
	defer runa.font_destroy(&font)

	cjk := "日本語のファイル名と混ざった文、そして安寧世界のために働く人"
	lines, got := runa.break_text(&font, cjk, 24, {200})
	defer delete(lines)
	testing.expect(t, got)
	testing.expect(t, len(lines) >= 3, "a spaceless CJK run must wrap, not overflow one line")
	check_tiling(t, lines, cjk)
}

@(test)
test_break_text_single_line_when_wide :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/Roboto-Regular.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	lines, got := runa.break_text(&font, PARA, 16, {5000})
	defer delete(lines)
	testing.expect(t, got)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0].start, 0)
	testing.expect_value(t, lines[0].end, len(PARA))
}

// A long word with a mid soft hyphen, at a width that only fits the first
// half, must break at the hyphen — the line is marked hyphenated.
@(test)
test_break_text_soft_hyphen :: proc(t: ^testing.T) {
	bytes, ok := load_font_bytes("tests/fonts/Roboto-Regular.ttf")
	if !ok { return }
	defer delete(bytes)
	font, _ := runa.font_load(bytes)
	defer runa.font_destroy(&font)

	text := "antidis­establish­mentarianism follows the rule"
	lines, got := runa.break_text(&font, text, 16, {120})
	defer delete(lines)
	testing.expect(t, got)
	check_tiling(t, lines, text)

	any_hyphen := false
	for ln in lines { if ln.hyphenated { any_hyphen = true } }
	testing.expect(t, any_hyphen, "a soft hyphen must be used at this width")

	// A hyphenated line's text really does end at a soft hyphen position.
	for ln in lines {
		if ln.hyphenated {
			testing.expect(t, strings.contains_rune(text[ln.start:min(ln.end + 2, len(text))], '­'),
				"hyphenated line should end adjacent to a soft hyphen")
		}
	}
}
