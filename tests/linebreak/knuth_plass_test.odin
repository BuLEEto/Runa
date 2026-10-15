// Total-fit (Knuth–Plass) line breaking over synthetic item streams with
// hand-computed answers: box/glue widths chosen so the optimal break is
// forced and checkable, plus hyphenation, ragged mode and the greedy fallback.
package linebreak_test

import "core:testing"
import lb "../../linebreak"

B :: lb.box
G :: lb.glue
P :: lb.penalty

// Three 10-wide boxes joined by 10-wide glue (stretch 10, shrink 5). At
// width 30 the whole thing (natural 50) can't fit one line (shrink only 10),
// and breaking after box0 leaves a stretch-less short line — so the only
// feasible 2-line break is after box1: "box0 glue box1" == 30 exactly.
@(test)
test_optimal_forced_break_point :: proc(t: ^testing.T) {
	items := []lb.Item{ B(10), G(10, 10, 5), B(10), G(10, 10, 5), B(10) }
	breaks, ok := lb.break_lines(items, {30}, {})
	defer delete(breaks)
	testing.expect(t, ok, "must produce a result")
	testing.expect_value(t, len(breaks), 2)
	testing.expect_value(t, breaks[0].item, 3)              // the glue after box1
	testing.expect(t, abs(breaks[0].ratio) < 0.01, "first line is exactly full (ratio ~0)")
}

// Wide enough: one line. Natural 50 at width 70 is ratio 1.0 (<= tolerance 2),
// which beats any two-line split on demerits.
@(test)
test_single_line_when_wide :: proc(t: ^testing.T) {
	items := []lb.Item{ B(10), G(10, 10, 5), B(10), G(10, 10, 5), B(10) }
	breaks, ok := lb.break_lines(items, {70}, {})
	defer delete(breaks)
	testing.expect(t, ok)
	testing.expect_value(t, len(breaks), 1)
}

// A long word carrying an internal soft hyphen. At width 40 the loose
// "w1 w2" line (ratio 2.67) exceeds tolerance, so the optimiser breaks at the
// hyphen instead: the line ends flagged and the hyphen's width counts.
@(test)
test_hyphenation_break :: proc(t: ^testing.T) {
	items := []lb.Item{
		B(10), G(4, 3, 1), B(10), G(4, 3, 1), B(10), P(50, 3, true), B(10),
	}
	breaks, ok := lb.break_lines(items, {40}, {})
	defer delete(breaks)
	testing.expect(t, ok)
	testing.expect_value(t, len(breaks), 2)
	testing.expect_value(t, breaks[0].item, 5)     // the soft-hyphen penalty
	testing.expect(t, breaks[0].flagged, "first line ends at a drawn hyphen")
}

// Ragged mode reports no spreading: every line's ratio is 0, even where
// justified mode would have stretched.
@(test)
test_ragged_reports_zero_ratio :: proc(t: ^testing.T) {
	items := []lb.Item{ B(10), G(10, 10, 5), B(10), G(10, 10, 5), B(10) }
	breaks, ok := lb.break_lines(items, {30}, {ragged = true})
	defer delete(breaks)
	testing.expect(t, ok)
	for brk in breaks { testing.expect(t, brk.ratio == 0, "ragged lines are not spread") }
}

// Every reported break lands on a real breakpoint (a glue or a penalty, or
// the internally-appended terminator past the last item), and there is one
// break per line with the last covering the end.
@(test)
test_breaks_are_valid_positions :: proc(t: ^testing.T) {
	items := []lb.Item{}
	words := make([dynamic]lb.Item, context.temp_allocator)
	for i in 0 ..< 12 {
		append(&words, B(12))
		if i < 11 { append(&words, G(6, 4, 2)) }
	}
	items = words[:]
	breaks, ok := lb.break_lines(items, {60}, {})
	defer delete(breaks)
	testing.expect(t, ok)
	testing.expect(t, len(breaks) >= 2, "a 12-word run at width 60 wraps")
	for brk, i in breaks {
		if brk.item < len(items) {
			k := items[brk.item].kind
			testing.expectf(t, k == .Glue || k == .Penalty, "break %d at a non-breakpoint item", i)
		}
		if i < len(breaks) - 1 {
			testing.expect(t, brk.ratio >= -1.01, "a kept line is never overfull past shrink")
		}
	}
}

// The greedy fallback returns one break per line and never overruns where a
// glue was available to break at.
@(test)
test_greedy_fallback :: proc(t: ^testing.T) {
	words := make([dynamic]lb.Item, context.temp_allocator)
	for i in 0 ..< 10 {
		append(&words, B(12))
		if i < 9 { append(&words, G(6, 4, 2)) }
	}
	append(&words, G(0, 1e7, 0))
	append(&words, P(lb.PENALTY_FORCED))
	breaks := lb.break_greedy(words[:], {40})
	defer delete(breaks)
	testing.expect(t, len(breaks) >= 3, "narrow width forces several lines")
}

// The consecutive-hyphen cap holds: with a limit of 1, the output never has
// two flagged lines in a row, even when every word could hyphenate.
@(test)
test_consecutive_hyphen_cap :: proc(t: ^testing.T) {
	// Four long words, each splittable at a mid soft hyphen, narrow width.
	words := make([dynamic]lb.Item, context.temp_allocator)
	for i in 0 ..< 4 {
		append(&words, B(16), P(50, 3, true), B(16))
		if i < 3 { append(&words, G(6, 3, 1)) }
	}
	breaks, ok := lb.break_lines(words[:], {34}, {max_consecutive_hyphens = 1})
	defer delete(breaks)
	testing.expect(t, ok)
	prev_flagged := false
	for brk in breaks {
		testing.expect(t, !(brk.flagged && prev_flagged), "no two hyphenated lines in a row")
		prev_flagged = brk.flagged
	}
}

// Variable line widths: a narrow first line (indent) then wider lines. The
// first line must hold fewer words than the rest.
@(test)
test_variable_line_widths :: proc(t: ^testing.T) {
	words := make([dynamic]lb.Item, context.temp_allocator)
	for i in 0 ..< 10 {
		append(&words, B(10))
		if i < 9 { append(&words, G(5, 3, 1)) }
	}
	// First line 20 wide, the rest 60.
	breaks, ok := lb.break_lines(words[:], {20, 60}, {})
	defer delete(breaks)
	testing.expect(t, ok)
	testing.expect(t, len(breaks) >= 2, "narrow first line forces a wrap")
	// The first break is early (only ~1 box fits in width 20).
	testing.expect(t, breaks[0].item <= 2, "first (indented) line holds very little")
}
