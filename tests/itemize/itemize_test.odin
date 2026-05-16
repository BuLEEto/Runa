/*
UAX #24 script segmentation tests. Exercises the property lookup
and the Common / Inherited fold rules.
*/
package itemize_test

import "core:testing"

import iz "../../itemize"

@(test)
test_script_of_basic :: proc(t: ^testing.T) {
	testing.expect_value(t, iz.script_of('A'), iz.LATIN)
	testing.expect_value(t, iz.script_of('α'), iz.GREEK)
	testing.expect_value(t, iz.script_of('Я'), iz.CYRILLIC)
	testing.expect_value(t, iz.script_of(' '), iz.COMMON)
	testing.expect_value(t, iz.script_of('1'), iz.COMMON)
	testing.expect_value(t, iz.script_of(0x0301), iz.INHERITED)        // combining acute
	testing.expect_value(t, iz.script_of('א'), iz.HEBREW)
	testing.expect_value(t, iz.script_of('日'), iz.HAN)
}

@(test)
test_segment_pure_latin :: proc(t: ^testing.T) {
	runs := make([dynamic]iz.Run, 0, 4)
	defer delete(runs)
	iz.segment("Hello, world!", &runs)

	testing.expect_value(t, len(runs), 1)
	testing.expect_value(t, runs[0].script, iz.LATIN)
	testing.expect_value(t, runs[0].byte_start, 0)
	testing.expect_value(t, runs[0].byte_end, len("Hello, world!"))
}

@(test)
test_segment_latin_greek :: proc(t: ^testing.T) {
	runs := make([dynamic]iz.Run, 0, 4)
	defer delete(runs)
	iz.segment("Latin και Greek", &runs)
	// "Latin " then "και" then " Greek": Common between scripts folds
	// into the preceding run; trailing Common goes with Latin.
	// Expected: 2 runs (Latin folding the space, Greek folding "και").
	testing.expect(t, len(runs) >= 2, "at least two scripts in mixed text")

	saw_latin := false
	saw_greek := false
	for r in runs {
		if r.script == iz.LATIN { saw_latin = true }
		if r.script == iz.GREEK { saw_greek = true }
	}
	testing.expect(t, saw_latin && saw_greek, "both Latin and Greek runs present")
}

@(test)
test_segment_combining_inherits :: proc(t: ^testing.T) {
	runs := make([dynamic]iz.Run, 0, 4)
	defer delete(runs)
	iz.segment("ábc", &runs)             // a + combining acute + bc

	// Should be one Latin run; the combining mark inherits.
	testing.expect_value(t, len(runs), 1)
	testing.expect_value(t, runs[0].script, iz.LATIN)
}

@(test)
test_grapheme_ascii :: proc(t: ^testing.T) {
	it := iz.grapheme_iter_make("abc")
	count := 0
	for {
		_, _, ok := iz.grapheme_iter_next(&it)
		if !ok { break }
		count += 1
	}
	testing.expect_value(t, count, 3)
}

@(test)
test_grapheme_emoji_zwj :: proc(t: ^testing.T) {
	// "👨‍👩‍👧" — family emoji = 3 emoji + 2 ZWJ joining them → 1 cluster.
	it := iz.grapheme_iter_make("\U0001F468‍\U0001F469‍\U0001F467")
	count := 0
	for {
		_, _, ok := iz.grapheme_iter_next(&it)
		if !ok { break }
		count += 1
	}
	testing.expect_value(t, count, 1)
}

@(test)
test_grapheme_devanagari_conjunct :: proc(t: ^testing.T) {
	// क् + त = क्त (KA + VIRAMA + TA = one conjunct cluster via GB9c).
	it := iz.grapheme_iter_make("क्त")
	count := 0
	for {
		_, _, ok := iz.grapheme_iter_next(&it)
		if !ok { break }
		count += 1
	}
	testing.expect_value(t, count, 1)
}

@(test)
test_grapheme_regional_indicator_pair :: proc(t: ^testing.T) {
	// 🇬🇧 flag of UK = two regional indicators forming one cluster.
	it := iz.grapheme_iter_make("\U0001F1EC\U0001F1E7")
	count := 0
	for {
		_, _, ok := iz.grapheme_iter_next(&it)
		if !ok { break }
		count += 1
	}
	testing.expect_value(t, count, 1)
}

@(test)
test_grapheme_crlf :: proc(t: ^testing.T) {
	// CR LF should form one cluster (GB3).
	it := iz.grapheme_iter_make("\r\n")
	count := 0
	for {
		_, _, ok := iz.grapheme_iter_next(&it)
		if !ok { break }
		count += 1
	}
	testing.expect_value(t, count, 1)
}

@(test)
test_word_iter_basic :: proc(t: ^testing.T) {
	// Two letter words separated by a space — yields 3 segments
	// ("hello", " ", "world") because the UAX #29 iterator partitions
	// the text into atoms, not just word-letters.
	it := iz.word_iter_make("hello world")
	count := 0
	for {
		_, _, ok := iz.word_iter_next(&it)
		if !ok { break }
		count += 1
	}
	testing.expect_value(t, count, 3)
}

@(test)
test_word_iter_apostrophe :: proc(t: ^testing.T) {
	// WB6/7 binds "don't" into one word.
	it := iz.word_iter_make("don't")
	count := 0
	for {
		_, _, ok := iz.word_iter_next(&it)
		if !ok { break }
		count += 1
	}
	testing.expect_value(t, count, 1)
}

@(test)
test_sentence_iter_basic :: proc(t: ^testing.T) {
	// Two sentences separated by ". " — SB11 breaks after the period.
	it := iz.sentence_iter_make("Hello world. Goodbye.")
	count := 0
	for {
		_, _, ok := iz.sentence_iter_next(&it)
		if !ok { break }
		count += 1
	}
	testing.expect_value(t, count, 2)
}

@(test)
test_sentence_iter_abbrev :: proc(t: ^testing.T) {
	// SB7: "U.S.A. is" is one sentence (abbreviation handling).
	it := iz.sentence_iter_make("U.S.A. is here.")
	count := 0
	for {
		_, _, ok := iz.sentence_iter_next(&it)
		if !ok { break }
		count += 1
	}
	testing.expect_value(t, count, 1)
}
