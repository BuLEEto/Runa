/*
Bit-flip fuzzer for `font_load`. Loads each seed font, then makes N
copies with K random bytes mutated and tries to parse each one.

Malformed input must surface as
an `Error` value, never a panic. A panic blocks the v0.1 release. The
DoD asks for 10 000 mutations per seed; the default below is 1 000 for
quick local runs — bump with --iters for the full sweep.

Run:
    odin run tools/bit_flip_fuzz.odin -file -- \
        tests/fonts/Roboto-Regular.ttf \
        tests/fonts/FiraCode-Regular.ttf \
        --iters 10000

The harness reports per-error-kind counts plus the count of malformed
fonts that loaded successfully (which is a parser-correctness check —
loads should be sparse).
*/
package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"

import runa "../"

main :: proc() {
	iters := 1000
	max_flips := 32
	seeds := make([dynamic]string, 0, 8)
	defer delete(seeds)

	skip_next := false
	for i in 1..<len(os.args) {
		if skip_next { skip_next = false; continue }
		a := os.args[i]
		switch a {
		case "--iters":
			if i + 1 < len(os.args) {
				v, _ := strconv.parse_int(os.args[i + 1])
				if v > 0 { iters = v }
				skip_next = true
			}
		case "--flips":
			if i + 1 < len(os.args) {
				v, _ := strconv.parse_int(os.args[i + 1])
				if v > 0 { max_flips = v }
				skip_next = true
			}
		case:
			append(&seeds, a)
		}
	}

	if len(seeds) == 0 {
		fmt.eprintln("usage: bit_flip_fuzz <seed.ttf>... [--iters N] [--flips K]")
		os.exit(2)
	}

	rand.reset(u64(0xCAFE_BABE))

	for path in seeds {
		seed, rerr := os.read_entire_file_from_path(path, context.allocator)
		if rerr != nil {
			fmt.printfln("%s: read err=%v", path, rerr)
			continue
		}
		fmt.printfln("--- %s (%d bytes) ---", path, len(seed))

		baseline, berr := runa.font_load(seed)
		if berr != .None {
			fmt.printfln("  baseline FAIL %v", berr)
			delete(seed)
			continue
		}
		runa.font_destroy(&baseline)

		// Tally per-error to spot patterns ("did Glyph_Not_Found
		// occur 4× more than Invalid_Table? unusual").
		counts: map[runa.Error]int
		defer delete(counts)
		spurious_loads := 0

		mutated := make([]u8, len(seed))
		defer delete(mutated)

		for k in 0..<iters {
			copy(mutated, seed)
			flips := 1 + int(rand.uint32()) % max_flips
			for _ in 0..<flips {
				pos := int(rand.uint32()) % len(mutated)
				bit := u8(1 << (rand.uint32() % 8))
				mutated[pos] ~= bit
			}
			font, err := runa.font_load(mutated)
			counts[err] += 1
			if err == .None {
				// A "successful" load on garbage isn't *wrong* — it
				// means the mutation didn't hit a checked field — but
				// it's worth tracking to know how lossy the validation
				// is.
				spurious_loads += 1
				runa.font_destroy(&font)
			}
			_ = k
		}

		fmt.printfln("  %d iters", iters)
		fmt.printfln("    spurious successful loads: %d", spurious_loads)
		for err, n in counts {
			fmt.printfln("    %v: %d", err, n)
		}
		delete(seed)
	}
}
