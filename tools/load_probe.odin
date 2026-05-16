/*
Try loading every font in tests/fonts/ — used to spot which DoD test
fonts the current parser chokes on.
*/
package main

import "core:fmt"
import "core:os"

import runa "../"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: load_probe <font.ttf>...")
		os.exit(2)
	}
	for path in os.args[1:] {
		bytes, rerr := os.read_entire_file_from_path(path, context.allocator)
		if rerr != nil { fmt.printfln("%s: read err=%v", path, rerr); continue }
		defer delete(bytes)

		font, err := runa.font_load(bytes)
		if err != .None {
			fmt.printfln("%s: FAIL %v", path, err)
		} else {
			fmt.printfln("%s: OK upem=%d glyphs=%d ascent=%.0f descent=%.0f", path, font.units_per_em, font.num_glyphs, font.ascent, font.descent)
			runa.font_destroy(&font)
		}
	}
}
