package main

import "core:fmt"

import lb "../linebreak"

main :: proc() {
	runes := []rune{0x1B05, 0x05BE}
	fmt.println("classes:", lb.line_break_class(runes[0]), lb.line_break_class(runes[1]))
	idx, m := lb.next_break(runes, 0)
	fmt.println("next_break(0):", idx, "mandatory:", m)
}
