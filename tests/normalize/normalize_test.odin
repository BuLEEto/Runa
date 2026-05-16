/*
UAX #15 normalization unit tests. The full conformance harness
lives at `tools/norm_conformance.odin` and exercises all 20 034
NormalizationTest.txt rows; these tests pin a handful of canonical
examples — written with explicit \x byte escapes to keep the
sequence bytes unambiguous — so a regression in NFC / NFD / NFKC /
NFKD shows up in the test runner directly.
*/
package normalize_test

import "core:testing"

import nm "../../normalize"

// U+00C1   Á        precomposed Latin Capital A with Acute
PRECOMP_A_ACUTE :: "\xC3\x81"
// U+0041 U+0301    A + combining acute (decomposed)
DECOMP_A_ACUTE  :: "A\xCC\x81"
// U+0041 U+0327 U+0301    A + cedilla + acute (NFD with reorder)
DECOMP_A_CED_ACUTE :: "A\xCC\xA7\xCC\x81"
// U+0041 U+0301 U+0327    A + acute + cedilla (pre-reorder — NOT NFD)
DECOMP_A_ACUTE_CED :: "A\xCC\x81\xCC\xA7"
// U+1100 U+1161   Hangul L + V (decomposed)
HANGUL_LV_DECOMP :: "\xE1\x84\x80\xE1\x85\xA1"
// U+AC00          Hangul syllable 가 (composed)
HANGUL_GA :: "\xEA\xB0\x80"
// U+FB01           LATIN SMALL LIGATURE FI
LIGATURE_FI :: "\xEF\xAC\x81"

@(test)
test_nfc_combining_to_precomposed :: proc(t: ^testing.T) {
	out := nm.to_nfc(DECOMP_A_ACUTE)
	defer delete(out)
	testing.expect_value(t, out, PRECOMP_A_ACUTE)
}

@(test)
test_nfd_precomposed_decomposes :: proc(t: ^testing.T) {
	out := nm.to_nfd(PRECOMP_A_ACUTE)
	defer delete(out)
	testing.expect_value(t, out, DECOMP_A_ACUTE)
}

@(test)
test_nfd_canonical_reorder :: proc(t: ^testing.T) {
	// Acute(230) before cedilla(202) violates canonical order — NFD
	// reorders to cedilla(202), acute(230). The precomposed Á (which
	// the source starts as if you pass the precomposed form) then
	// decomposes to A + acute and the trailing cedilla is reordered.
	// Easier: start with the pre-reorder NFD form directly.
	out := nm.to_nfd(DECOMP_A_ACUTE_CED)
	defer delete(out)
	testing.expect_value(t, out, DECOMP_A_CED_ACUTE)
}

@(test)
test_nfd_hangul_decompose :: proc(t: ^testing.T) {
	out := nm.to_nfd(HANGUL_GA)
	defer delete(out)
	testing.expect_value(t, out, HANGUL_LV_DECOMP)
}

@(test)
test_nfc_hangul_compose :: proc(t: ^testing.T) {
	out := nm.to_nfc(HANGUL_LV_DECOMP)
	defer delete(out)
	testing.expect_value(t, out, HANGUL_GA)
}

@(test)
test_nfkd_compat_decomposition :: proc(t: ^testing.T) {
	out := nm.to_nfkd(LIGATURE_FI)
	defer delete(out)
	testing.expect_value(t, out, "fi")
}

@(test)
test_nfd_singleton_identity :: proc(t: ^testing.T) {
	out := nm.to_nfd("hello")
	defer delete(out)
	testing.expect_value(t, out, "hello")
}

@(test)
test_ccc_lookup :: proc(t: ^testing.T) {
	testing.expect_value(t, nm.ccc('A'),    0)    // starter
	testing.expect_value(t, nm.ccc(0x0301), 230)  // combining acute
	testing.expect_value(t, nm.ccc(0x0327), 202)  // combining cedilla
}
