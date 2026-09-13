/*
Thai word-break tests. The dictionary is opt-in (-define:RUNA_THAI_DICT=true);
these adapt to the build: dictionary segmentation when on, grapheme-cluster
fallback when off (the default).
*/
package linebreak_test

import "core:testing"
import linebreak "../../linebreak"

THAI_DICT :: #config(RUNA_THAI_DICT, false)

@(test)
test_thai_segments_hello :: proc(t: ^testing.T) {
	// "สวัสดี" = "sawasdee". It's a single corpus word, so the dictionary
	// inserts no interior break; the fallback breaks between clusters.
	text := []rune{'ส', 'ว', 'ั', 'ส', 'ด', 'ี'}
	breaks := make([]bool, len(text))
	defer delete(breaks)
	linebreak.thai_segment_breaks(text, breaks)

	any_break := false
	for b in breaks { if b { any_break = true } }
	when THAI_DICT {
		testing.expect(t, !any_break, "dictionary: whole word, no interior break")
	} else {
		testing.expect(t, any_break, "fallback: expected grapheme breaks")
	}
}

@(test)
test_thai_segments_two_words :: proc(t: ^testing.T) {
	// "สวัสดีครับ" = "sawasdee" + "khrap". Dictionary: one boundary at 6.
	text := []rune{'ส', 'ว', 'ั', 'ส', 'ด', 'ี', 'ค', 'ร', 'ั', 'บ'}
	breaks := make([]bool, len(text))
	defer delete(breaks)
	linebreak.thai_segment_breaks(text, breaks)

	when THAI_DICT {
		saw_break := false
		for b, i in breaks {
			if b {
				testing.expectf(t, !saw_break, "more than one break")
				saw_break = true
				testing.expect_value(t, i, 6)              // boundary at "ครับ"
			}
		}
		testing.expect(t, saw_break, "no break found inside two-word phrase")
	} else {
		any_break := false
		for b in breaks { if b { any_break = true } }
		testing.expect(t, any_break, "fallback: expected grapheme breaks")
	}
}

@(test)
test_thai_no_break_in_non_thai :: proc(t: ^testing.T) {
	// Mixed text: the Latin sections must never get a Thai break, either mode.
	text := []rune{'a', 'b', 'c', 'ส', 'ว', 'ั', 'ส', 'ด', 'ี', 'd', 'e'}
	breaks := make([]bool, len(text))
	defer delete(breaks)
	linebreak.thai_segment_breaks(text, breaks)
	for b, i in breaks {
		if i < 3 || i > 8 { testing.expectf(t, !b, "Latin region break at %d", i) }
	}
}
