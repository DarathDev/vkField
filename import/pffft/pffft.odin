package pffft

import "core:math"
when ODIN_OS == .Darwin || ODIN_OS == .Linux {
	foreign import lib "pffft.a"
} else when ODIN_OS == .Windows {
	foreign import lib "pffft.lib"
}

Direction :: enum {
	FORWARD,
	BACKWARD,
}

Transform :: enum {
	REAL,
	COMPLEX,
}

PffftSession :: rawptr

@(default_calling_convention = "c", link_prefix = "pffft_")
foreign lib {
	new_setup :: proc(N: int, transform: Transform) -> PffftSession ---
	destroy_setup :: proc(session: PffftSession) ---
	transform :: proc(session: PffftSession, input: [^]f32, output: [^]f32, work: [^]f32, direction: Direction) ---
	transform_ordered :: proc(session: PffftSession, input: [^]f32, output: [^]f32, work: [^]f32, direction: Direction) ---
	zreorder :: proc(session: PffftSession, input: [^]f32, output: [^]f32, direction: Direction) ---
	zconvolve_accumulate :: proc(session: PffftSession, dft_a: [^]f32, dft_b: [^]f32, dft_ab: [^]f32, scaling: f32) ---
	aligned_malloc :: proc(nb_bytes: uint) -> rawptr ---
	aligned_free :: proc(session: rawptr) ---
	simd_size :: proc() -> int ---
}

adjust_n :: proc(n: int) -> int {
	n := n
	n = max((n + 31) & ~int(31), 32)
	n = math.next_power_of_two(n)
	return n
}
