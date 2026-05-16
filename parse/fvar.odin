package parse

// fvar — Font Variations Table.
//
// Enumerates the variation axes a variable font exposes (`wght`,
// `wdth`, `opsz`, `slnt`, `ital`, plus any custom axes the designer
// added). Each axis has a min / default / max value in user-facing
// units, plus a name-table id for UI display.
//
// `fvar` is the entry point for variable-font support: once we know
// the axes, we can normalise caller-supplied user-coordinates
// (`font_set_variation`) and ask `gvar` for the matching per-glyph
// outline deltas.
//
// At v0.5 we parse axes only; the named-instances list is read but
// not exposed (Skald and friends don't need it yet).
//
// References: OpenType spec, "fvar — Font Variations Table".

FVAR_VERSION_1_0 :: u32(0x00010000)

// Variation_Axis is one row from the fvar axis array. Values are in
// "user" coordinates as the designer wrote them. The shaper / glyph
// pipeline works in *normalised* coordinates ([-1, 0, +1] tuples);
// `normalize_axis_value` converts.
Variation_Axis :: struct {
	tag:        Tag,
	min_value:  f32,
	default_value: f32,
	max_value:  f32,
	flags:      u16,
	name_id:    u16,
}

Fvar :: struct {
	axes: []Variation_Axis,
}

// parse_fvar decodes the axis list from the `fvar` table. Allocates
// `axes` from `allocator`; caller frees with `fvar_destroy`.
parse_fvar :: proc(data: []u8, allocator := context.allocator) -> (f: Fvar, err: Error) {
	r := Reader{data = data}

	version := read_u32(&r) or_return
	if version != FVAR_VERSION_1_0 { err = .Unsupported_Format; return }

	axes_off := read_u16(&r) or_return
	skip(&r, 2) or_return                            // reserved (= 2)
	axis_count := read_u16(&r) or_return
	axis_size  := read_u16(&r) or_return             // must be 20 in v1.0
	skip(&r, 2) or_return                            // instanceCount — skipped
	skip(&r, 2) or_return                            // instanceSize — skipped

	if axis_size < 20 { err = .Invalid_Table; return }

	axes := make([]Variation_Axis, axis_count, allocator)
	if axes == nil && axis_count > 0 { err = .Out_Of_Memory; return }

	for i in 0..<int(axis_count) {
		rec_off := int(axes_off) + i * int(axis_size)
		rr := reader_at(data, rec_off) or_return
		tag       := read_tag(&rr) or_return
		min_raw   := read_i32(&rr) or_return
		def_raw   := read_i32(&rr) or_return
		max_raw   := read_i32(&rr) or_return
		flags     := read_u16(&rr) or_return
		name_id   := read_u16(&rr) or_return
		axes[i] = Variation_Axis{
			tag           = tag,
			min_value     = fixed_16_16(min_raw),
			default_value = fixed_16_16(def_raw),
			max_value     = fixed_16_16(max_raw),
			flags         = flags,
			name_id       = name_id,
		}
	}
	f.axes = axes
	return
}

fvar_destroy :: proc(f: ^Fvar, allocator := context.allocator) {
	delete(f.axes, allocator)
	f^ = {}
}

// fvar_find_axis returns the axis record whose tag matches, or false
// if the font doesn't expose it. Used by `font_set_variation` to
// validate user input.
fvar_find_axis :: proc(f: ^Fvar, tag: Tag) -> (axis: Variation_Axis, ok: bool) {
	for a in f.axes {
		if a.tag == tag { return a, true }
	}
	return {}, false
}

// normalize_axis_value clamps `user_value` to the axis's
// [min, default, max] range and remaps it linearly to the normalised
// [-1, 0, +1] coordinate space `gvar` uses. The full UAX-equivalent
// transform via `avar` (axis-value mapping) is applied separately by
// the avar table when present — this helper does the user→normalised
// step, and avar then re-maps that result if the font has non-linear
// axis ramps.
normalize_axis_value :: proc(a: Variation_Axis, user_value: f32) -> f32 {
	v := user_value
	if v < a.min_value { v = a.min_value }
	if v > a.max_value { v = a.max_value }
	if v == a.default_value { return 0 }
	if v < a.default_value {
		denom := a.default_value - a.min_value
		if denom <= 0 { return 0 }
		return (v - a.default_value) / denom        // negative side
	}
	denom := a.max_value - a.default_value
	if denom <= 0 { return 0 }
	return (v - a.default_value) / denom            // positive side
}

@(private)
fixed_16_16 :: #force_inline proc(raw: i32) -> f32 {
	return f32(raw) / 65536.0
}
