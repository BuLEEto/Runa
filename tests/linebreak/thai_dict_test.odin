/*
Thai word-break dictionary tests.
*/
package linebreak_test

import "core:testing"
import linebreak "../../linebreak"

@(test)
test_thai_segments_hello :: proc(t: ^testing.T) {
	// "สวัสดี" = greeting "sawasdee". Common Thai dictionary words:
	// "สวัสดี" (whole word) is in the corpus, so we expect ONE
	// segment — no internal break inserted.
	text := []rune{'ส', 'ว', 'ั', 'ส', 'ด', 'ี'}
	breaks := make([]bool, len(text))
	defer delete(breaks)
	linebreak.thai_segment_breaks(text, breaks)
	for b, i in breaks {
		testing.expectf(t, !b, "unexpected break at %d", i)
	}
}

@(test)
test_thai_segments_two_words :: proc(t: ^testing.T) {
	// "สวัสดีครับ" = "sawasdee" (greeting) + "khrap" (male polite).
	// PyThaiNLP corpus has both as separate words → expect ONE
	// boundary inside the run, at the break between them.
	text := []rune{'ส', 'ว', 'ั', 'ส', 'ด', 'ี', 'ค', 'ร', 'ั', 'บ'}
	breaks := make([]bool, len(text))
	defer delete(breaks)
	linebreak.thai_segment_breaks(text, breaks)
	saw_break := false
	for b, i in breaks {
		if b {
			testing.expectf(t, !saw_break, "more than one break")
			saw_break = true
			testing.expect_value(t, i, 6)                  // boundary at "ครับ"
		}
	}
	testing.expect(t, saw_break, "no break found inside two-word phrase")
}

@(test)
test_thai_no_break_in_non_thai :: proc(t: ^testing.T) {
	// Mixed text with Latin should leave the Latin section untouched.
	text := []rune{'a', 'b', 'c', 'ส', 'ว', 'ั', 'ส', 'ด', 'ี', 'd', 'e'}
	breaks := make([]bool, len(text))
	defer delete(breaks)
	linebreak.thai_segment_breaks(text, breaks)
	for b, i in breaks {
		if i < 3 || i > 8 { testing.expectf(t, !b, "Latin region break at %d", i) }
	}
}
