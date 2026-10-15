// Pins the named GSUB/GPOS feature-tag constants against `tag(...)`, so a
// transposed hex digit in a constant can't ship silently.
package parse_test

import "core:testing"
import parse "../../parse"

@(test)
test_feature_tag_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, parse.FEAT_CCMP, parse.tag("ccmp"))
	testing.expect_value(t, parse.FEAT_LOCL, parse.tag("locl"))
	testing.expect_value(t, parse.FEAT_RLIG, parse.tag("rlig"))
	testing.expect_value(t, parse.FEAT_CASE, parse.tag("case"))
	testing.expect_value(t, parse.FEAT_SMCP, parse.tag("smcp"))
	testing.expect_value(t, parse.FEAT_C2SC, parse.tag("c2sc"))
	testing.expect_value(t, parse.FEAT_ONUM, parse.tag("onum"))
	testing.expect_value(t, parse.FEAT_LIGA, parse.tag("liga"))
	testing.expect_value(t, parse.FEAT_CLIG, parse.tag("clig"))
	testing.expect_value(t, parse.FEAT_DLIG, parse.tag("dlig"))
	testing.expect_value(t, parse.FEAT_CALT, parse.tag("calt"))
	testing.expect_value(t, parse.FEAT_KERN, parse.tag("kern"))
}
