/*
UAX #14 sanity checks. Full conformance (against LineBreakTest.txt) is
queued for v0.1 polish; this file covers the LB-subset the v0.1 engine
implements end-to-end.
*/
package linebreak_test

import "core:testing"

import lb "../../linebreak"

@(test)
test_property_basic :: proc(t: ^testing.T) {
	// ASCII letters → AL.
	testing.expect_value(t, lb.line_break_class('A'), lb.Line_Break_Class.AL)
	// ASCII space → SP.
	testing.expect_value(t, lb.line_break_class(' '), lb.Line_Break_Class.SP)
	// Newline → LF.
	testing.expect_value(t, lb.line_break_class('\n'), lb.Line_Break_Class.LF)
	// Hyphen-minus → HY.
	testing.expect_value(t, lb.line_break_class('-'), lb.Line_Break_Class.HY)
	// Combining acute → CM.
	testing.expect_value(t, lb.line_break_class(0x0301), lb.Line_Break_Class.CM)
}

@(test)
test_break_after_space :: proc(t: ^testing.T) {
	text := []rune{'A', 'B', ' ', 'C', 'D'}
	idx, mandatory := lb.next_break(text, 0)
	// Per LB18 — break after SP, so break opportunity is at position 3
	// (between SP and 'C').
	testing.expect_value(t, idx, 3)
	testing.expect_value(t, mandatory, false)
}

@(test)
test_hard_break_lf :: proc(t: ^testing.T) {
	text := []rune{'A', 'B', '\n', 'C'}
	idx, mandatory := lb.next_break(text, 0)
	// LB4: break after LF (cursor moves past the LF; mandatory).
	testing.expect_value(t, idx, 3)
	testing.expect_value(t, mandatory, true)
}

@(test)
test_no_break_inside_word :: proc(t: ^testing.T) {
	text := []rune{'H', 'e', 'l', 'l', 'o'}
	idx, mandatory := lb.next_break(text, 0)
	// No internal break — falls through to eot.
	testing.expect_value(t, idx, 5)
	testing.expect_value(t, mandatory, true)
}

@(test)
test_combining_mark_attaches :: proc(t: ^testing.T) {
	// "a" + combining acute. Must not break between them per LB9.
	text := []rune{'a', 0x0301, 'b'}
	idx, _ := lb.next_break(text, 0)
	// No break inside the cluster; engine walks to eot.
	testing.expect_value(t, idx, 3)
}

@(test)
test_break_after_hyphen :: proc(t: ^testing.T) {
	text := []rune{'A', '-', 'B'}
	idx, _ := lb.next_break(text, 0)
	// LB21 (subset): HY allows a break after.
	testing.expect_value(t, idx, 2)
}
