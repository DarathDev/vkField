package vkField_utility

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:testing"

VKFIELD_IS_DEBUG :: ODIN_DEBUG
VKFIELD_IS_RELEASE :: !ODIN_DEBUG

panic :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok do return
	@(cold)
	internal :: proc(message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		if len(detail) > 0 do log.panicf("%s (%v)", message, detail[0], location = loc)
		else do log.panicf(message, location = loc)
	}
	internal(message, loc, ..detail)
}

fatal :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok do return
	@(cold)
	internal :: proc(message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		if len(detail) > 0 do log.fatalf("%s (%v)", message, detail[0], location = loc)
		else do log.fatalf(message, location = loc)
	}
	internal(message, loc, ..detail)
}

error :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok do return
	@(cold)
	internal :: proc(message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		if len(detail) > 0 do log.errorf("%s (%v)", message, detail[0], location = loc)
		else do log.errorf(message, location = loc)
	}
	internal(message, loc, ..detail)
}

warn :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok do return
	@(cold)
	internal :: proc(message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		if len(detail) > 0 do log.warnf("%s (%v)", message, detail[0], location = loc)
		else do log.warnf(message, location = loc)
	}
	internal(message, loc, ..detail)
}

ignore :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	// Intentionally do nothing
}

test :: #force_inline proc(t: ^testing.T, ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok do return
	@(cold)
	internal :: proc(t: ^testing.T, ok: bool, message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		if len(detail) > 0 do testing.expectf(t, ok, "%s (%v)", message, detail[0], loc = loc)
		else do testing.expectf(t, ok, message, loc = loc)
	}
	internal(t, ok, message, loc, ..detail)
}

ensure :: proc {
	ensure_bool_zero,
	ensure_bool_one,
	ensure_bool_two,
	ensure_bool_three,
	ensure_bool_four,
	ensure_enum_zero,
	ensure_enum_one,
	ensure_enum_two,
	ensure_enum_three,
	ensure_enum_four,
	ensure_union_zero,
	ensure_union_one,
	ensure_union_two,
	ensure_union_three,
	ensure_union_four,
}

verify :: proc {
	verify_bool_zero,
	verify_bool_one,
	verify_bool_two,
	verify_bool_three,
	verify_bool_four,
	verify_enum_zero,
	verify_enum_one,
	verify_enum_two,
	verify_enum_three,
	verify_enum_four,
	verify_union_zero,
	verify_union_one,
	verify_union_two,
	verify_union_three,
	verify_union_four,
}

confirm :: proc {
	confirm_bool_zero,
	confirm_bool_one,
	confirm_bool_two,
	confirm_bool_three,
	confirm_bool_four,
	confirm_enum_zero,
	confirm_enum_one,
	confirm_enum_two,
	confirm_enum_three,
	confirm_enum_four,
	confirm_union_zero,
	confirm_union_one,
	confirm_union_two,
	confirm_union_three,
	confirm_union_four,
}

assert :: proc {
	assert_bool_zero,
	assert_bool_one,
	assert_bool_two,
	assert_bool_three,
	assert_bool_four,
	assert_enum_zero,
	assert_enum_one,
	assert_enum_two,
	assert_enum_three,
	assert_enum_four,
	assert_union_zero,
	assert_union_one,
	assert_union_two,
	assert_union_three,
	assert_union_four,
}

check :: proc {
	check_bool_zero,
	check_bool_one,
	check_bool_two,
	check_bool_three,
	check_bool_four,
	check_enum_zero,
	check_enum_one,
	check_enum_two,
	check_enum_three,
	check_enum_four,
	check_union_zero,
	check_union_one,
	check_union_two,
	check_union_three,
	check_union_four,
}

assume :: proc {
	assume_bool_zero,
	assume_bool_one,
	assume_bool_two,
	assume_bool_three,
	assume_bool_four,
	assume_enum_zero,
	assume_enum_one,
	assume_enum_two,
	assume_enum_three,
	assume_enum_four,
	assume_union_zero,
	assume_union_one,
	assume_union_two,
	assume_union_three,
	assume_union_four,
}

expect :: proc {
	expect_bool_zero,
	expect_bool_one,
	expect_bool_two,
	expect_bool_three,
	expect_bool_four,
	expect_enum_zero,
	expect_enum_one,
	expect_enum_two,
	expect_enum_three,
	expect_enum_four,
	expect_union_zero,
	expect_union_one,
	expect_union_two,
	expect_union_three,
	expect_union_four,
}

expect_not :: proc {
	expect_not_bool_zero,
	expect_not_bool_one,
	expect_not_bool_two,
	expect_not_bool_three,
	expect_not_bool_four,
}

is_ok :: proc {
	is_ok_enum_zero,
	is_ok_enum_one,
	is_ok_enum_two,
	is_ok_enum_three,
	is_ok_enum_four,
	is_ok_union_zero,
	is_ok_union_one,
	is_ok_union_two,
	is_ok_union_three,
	is_ok_union_four,
}

ensure_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) where intrinsics.type_is_boolean(B) {
	panic(bool(condition), message, loc)
}

verify_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) -> bool where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_RELEASE {
		fatal(bool(condition), message, loc)
	} else {
		panic(bool(condition), message, loc)
	}
	return bool(condition)
}

confirm_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) -> bool where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_DEBUG {
		panic(bool(condition), message, loc)
	} else {
		error(bool(condition), message, loc)
	}
	return bool(condition)
}

assert_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_DEBUG {
		panic(bool(condition), message, loc)
	} else {
		ignore(bool(condition), message, loc)
	}
}

check_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) -> bool where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_RELEASE {
		ignore(bool(condition), message, loc)
	} else {
		warn(bool(condition), message, loc)
	}
	return bool(condition)
}

assume_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_DEBUG {
		warn(bool(condition), message, loc)
	}
}

expect_bool_zero :: #force_inline proc(t: ^testing.T, condition: $B, message := "", loc := #caller_location) -> bool where intrinsics.type_is_boolean(B) {
	test(t, bool(condition), message, loc)
	return bool(condition)
}

expect_not_bool_zero :: #force_inline proc(t: ^testing.T, condition: $B, message := "", loc := #caller_location) -> bool where intrinsics.type_is_boolean(B) {
	cond := bool(condition)
	test(t, !cond, message, loc)
	return !cond
}

ensure_bool_one :: #force_inline proc(value: $T, ok: $B, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_boolean(B) {
	panic(bool(ok), message, loc)
	return value
}

verify_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_RELEASE {
		fatal(bool(ok), message, loc)
	} else {
		panic(bool(ok), message, loc)
	}
	return value, bool(ok)
}

confirm_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		error(bool(ok), message, loc)
	}
	return value, bool(ok)
}

assert_bool_one :: #force_inline proc(value: $T, ok: $B, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		ignore(bool(ok), message, loc)
	}
	return value
}

check_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_RELEASE {
		ignore(bool(ok), message, loc)
	} else {
		warn(bool(ok), message, loc)
	}
	return value, bool(ok)
}

assume_bool_one :: #force_inline proc(value: $T, ok: $B, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_DEBUG {
		warn(bool(ok), message, loc)
	}
	return value
}

expect_bool_one :: #force_inline proc(
	t: ^testing.T,
	value: $T,
	ok: $B,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_boolean(B) #optional_ok {
	test(t, bool(ok), message, loc)
	return value, bool(ok)
}

expect_not_bool_one :: #force_inline proc(
	t: ^testing.T,
	value: $T,
	ok: $B,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_boolean(B) #optional_ok {
	test(t, !bool(ok), message, loc)
	return value, !bool(ok)
}

ensure_bool_two :: #force_inline proc(first: $A, second: $B, ok: $C, message := "", loc := #caller_location) -> (A, B) where intrinsics.type_is_boolean(C) {
	panic(bool(ok), message, loc)
	return first, second
}

verify_bool_two :: #force_inline proc(
	first: $A,
	second: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	when VKFIELD_IS_RELEASE {
		fatal(bool(ok), message, loc)
	} else {
		panic(bool(ok), message, loc)
	}
	return first, second, bool(ok)
}

confirm_bool_two :: #force_inline proc(
	first: $A,
	second: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	when VKFIELD_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		error(bool(ok), message, loc)
	}
	return first, second, bool(ok)
}

assert_bool_two :: #force_inline proc(first: $A, second: $B, ok: $C, message := "", loc := #caller_location) -> (A, B) where intrinsics.type_is_boolean(C) {
	when VKFIELD_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		ignore(bool(ok), message, loc)
	}
	return first, second
}

check_bool_two :: #force_inline proc(
	first: $A,
	second: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	when VKFIELD_IS_RELEASE {
		ignore(bool(ok), message, loc)
	} else {
		warn(bool(ok), message, loc)
	}
	return first, second, bool(ok)
}

assume_bool_two :: #force_inline proc(first: $A, second: $B, ok: $C, message := "", loc := #caller_location) -> (A, B) where intrinsics.type_is_boolean(C) {
	when VKFIELD_IS_DEBUG {
		warn(bool(ok), message, loc)
	}
	return first, second
}

expect_bool_two :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	test(t, bool(ok), message, loc)
	return first, second, bool(ok)
}

expect_not_bool_two :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	test(t, !bool(ok), message, loc)
	return first, second, !bool(ok)
}

ensure_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_boolean(D) {
	panic(bool(ok), message, loc)
	return first, second, third
}

verify_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_boolean(D) {
	when VKFIELD_IS_RELEASE {
		fatal(bool(ok), message, loc)
	} else {
		panic(bool(ok), message, loc)
	}
	return first, second, third, bool(ok)
}

confirm_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_boolean(D) {
	when VKFIELD_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		error(bool(ok), message, loc)
	}
	return first, second, third, bool(ok)
}

assert_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_boolean(D) {
	when VKFIELD_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		ignore(bool(ok), message, loc)
	}
	return first, second, third
}

check_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_boolean(D) {
	when VKFIELD_IS_RELEASE {
		ignore(bool(ok), message, loc)
	} else {
		warn(bool(ok), message, loc)
	}
	return first, second, third, bool(ok)
}

assume_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_boolean(D) {
	when VKFIELD_IS_DEBUG {
		warn(bool(ok), message, loc)
	}
	return first, second, third
}

expect_bool_three :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_boolean(D) {
	test(t, bool(ok), message, loc)
	return first, second, third, bool(ok)
}

expect_not_bool_three :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_boolean(D) {
	test(t, !bool(ok), message, loc)
	return first, second, third, !bool(ok)
}

ensure_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_boolean(E) {
	panic(bool(ok), message, loc)
	return first, second, third, fourth
}

verify_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_boolean(E) {
	when VKFIELD_IS_RELEASE {
		fatal(bool(ok), message, loc)
	} else {
		panic(bool(ok), message, loc)
	}
	return first, second, third, fourth, bool(ok)
}

confirm_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_boolean(E) {
	when VKFIELD_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		error(bool(ok), message, loc)
	}
	return first, second, third, fourth, bool(ok)
}

assert_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_boolean(E) {
	when VKFIELD_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		ignore(bool(ok), message, loc)
	}
	return first, second, third, fourth
}

check_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_boolean(E) {
	when VKFIELD_IS_RELEASE {
		ignore(bool(ok), message, loc)
	} else {
		warn(bool(ok), message, loc)
	}
	return first, second, third, fourth, bool(ok)
}

assume_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_boolean(E) {
	when VKFIELD_IS_DEBUG {
		warn(bool(ok), message, loc)
	}
	return first, second, third, fourth
}

expect_bool_four :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_boolean(E) {
	test(t, bool(ok), message, loc)
	return first, second, third, fourth, bool(ok)
}

expect_not_bool_four :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_boolean(E) {
	test(t, !bool(ok), message, loc)
	return first, second, third, fourth, !bool(ok)
}

ensure_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
}

verify_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		fatal(cast(int)err == 0, message, loc, err)
	} else {
		panic(cast(int)err == 0, message, loc, err)
	}
	return err
}

confirm_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		error(cast(int)err == 0, message, loc, err)
	}
	return err
}

assert_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		ignore(cast(int)err == 0, message, loc, err)
	}
}

check_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		ignore(cast(int)err == 0, message, loc, err)
	} else {
		warn(cast(int)err == 0, message, loc, err)
	}
	return err
}

assume_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		warn(cast(int)err == 0, message, loc, err)
	}
}

expect_enum_zero :: #force_inline proc(t: ^testing.T, err: $E, message := "", loc := #caller_location) -> bool where intrinsics.type_is_enum(E) {
	ok := cast(int)err == 0
	test(t, ok, message, loc, err)
	return ok
}

is_ok_enum_zero :: #force_inline proc(err: $E) -> bool where intrinsics.type_is_enum(E) {
	return cast(int)err == 0
}

ensure_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
	return value
}

verify_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> (T, E) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		fatal(cast(int)err == 0, message, loc, err)
	} else {
		panic(cast(int)err == 0, message, loc, err)
	}
	return value, err
}

confirm_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> (T, E) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		error(cast(int)err == 0, message, loc, err)
	}
	return value, err
}

assert_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		error(cast(int)err == 0, message, loc, err)
	}
	return value
}

check_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> (T, E) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		ignore(cast(int)err == 0, message, loc, err)
	} else {
		warn(cast(int)err == 0, message, loc, err)
	}
	return value, err
}

assume_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		warn(cast(int)err == 0, message, loc, err)
	}
	return value
}

expect_enum_one :: #force_inline proc(
	t: ^testing.T,
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_enum(E) #optional_ok {
	ok := cast(int)err == 0
	test(t, ok, message, loc, err)
	return value, ok
}

is_ok_enum_one :: #force_inline proc(value: $T, err: $E) -> (T, bool) where intrinsics.type_is_enum(E) {
	return value, cast(int)err == 0
}

ensure_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
	return first, second
}

verify_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		fatal(cast(int)err == 0, message, loc, err)
	} else {
		panic(cast(int)err == 0, message, loc, err)
	}
	return first, second, err
}

confirm_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		error(cast(int)err == 0, message, loc, err)
	}
	return first, second, err
}

assert_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		error(cast(int)err == 0, message, loc, err)
	}
	return first, second
}

check_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		ignore(cast(int)err == 0, message, loc, err)
	} else {
		warn(cast(int)err == 0, message, loc, err)
	}
	return first, second, err
}

assume_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		warn(cast(int)err == 0, message, loc, err)
	}
	return first, second
}

expect_enum_two :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_enum(E) {
	ok := cast(int)err == 0
	test(t, ok, message, loc, err)
	return first, second, ok
}

is_ok_enum_two :: #force_inline proc(first: $A, second: $B, err: $E) -> (A, B, bool) where intrinsics.type_is_enum(E) {
	return first, second, cast(int)err == 0
}

ensure_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
	return first, second, third
}

verify_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		fatal(cast(int)err == 0, message, loc, err)
	} else {
		panic(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, err
}

confirm_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		error(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, err
}

assert_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		error(cast(int)err == 0, message, loc, err)
	}
	return first, second, third
}

check_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		ignore(cast(int)err == 0, message, loc, err)
	} else {
		warn(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, err
}

assume_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		warn(cast(int)err == 0, message, loc, err)
	}
	return first, second, third
}

expect_enum_three :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_enum(E) {
	ok := cast(int)err == 0
	test(t, ok, message, loc, err)
	return first, second, third, ok
}

is_ok_enum_three :: #force_inline proc(first: $A, second: $B, third: $C, err: $E) -> (A, B, C, bool) where intrinsics.type_is_enum(E) {
	return first, second, third, cast(int)err == 0
}

ensure_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
	return first, second, third, fourth
}

verify_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		fatal(cast(int)err == 0, message, loc, err)
	} else {
		panic(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth, err
}

confirm_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		error(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth, err
}

assert_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		panic(cast(int)err == 0, message, loc, err)
	} else {
		error(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth
}

check_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_RELEASE {
		ignore(cast(int)err == 0, message, loc, err)
	} else {
		warn(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth, err
}

assume_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_enum(E) {
	when VKFIELD_IS_DEBUG {
		warn(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth
}

expect_enum_four :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_enum(E) {
	ok := cast(int)err == 0
	test(t, ok, message, loc, err)
	return first, second, third, fourth, ok
}

is_ok_enum_four :: #force_inline proc(first: $A, second: $B, third: $C, fourth: $D, err: $E) -> (A, B, C, D, bool) where intrinsics.type_is_enum(E) {
	return first, second, third, fourth, cast(int)err == 0
}

ensure_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
}

verify_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		fatal(err == E{}, message, loc, err)
	} else {
		panic(err == E{}, message, loc, err)
	}
	return err
}

confirm_union_zero :: #force_inline proc(
	err: $E,
	message := "",
	loc := #caller_location,
) -> E where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
	return err
}

assert_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
}

check_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		ignore(err == E{}, message, loc, err)
	} else {
		warn(err == E{}, message, loc, err)
	}
	return err
}

assume_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		warn(err == E{}, message, loc, err)
	}
}

expect_union_zero :: #force_inline proc(
	t: ^testing.T,
	err: $E,
	message := "",
	loc := #caller_location,
) -> bool where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	ok := err == E{}
	test(t, ok, message, loc, err)
	return ok
}

is_ok_union_zero :: #force_inline proc(err: $E) -> bool where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	return err == E{}
}

ensure_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> T where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
	return value
}

verify_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		fatal(err == E{}, message, loc, err)
	} else {
		panic(err == E{}, message, loc, err)
	}
	return value, err
}

confirm_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
	return value, err
}

assert_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> T where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
	return value
}

check_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		ignore(err == E{}, message, loc, err)
	} else {
		warn(err == E{}, message, loc, err)
	}
	return value, err
}

assume_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> T where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		warn(err == E{}, message, loc, err)
	}
	return value
}

expect_union_one :: #force_inline proc(
	t: ^testing.T,
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) #optional_ok {
	ok := err == E{}
	test(t, ok, message, loc, err)
	return value, ok
}

is_ok_union_one :: #force_inline proc(value: $T, err: $E) -> (T, bool) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	return value, err == E{}
}

ensure_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
	return first, second
}

verify_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		fatal(err == E{}, message, loc, err)
	} else {
		panic(err == E{}, message, loc, err)
	}
	return first, second, err
}

confirm_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
	return first, second, err
}

assert_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
	return first, second
}

check_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		ignore(err == E{}, message, loc, err)
	} else {
		warn(err == E{}, message, loc, err)
	}
	return first, second, err
}

assume_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		warn(err == E{}, message, loc, err)
	}
	return first, second
}

expect_union_two :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	ok := err == E{}
	test(t, ok, message, loc, err)
	return first, second, ok
}

is_ok_union_two :: #force_inline proc(first: $A, second: $B, err: $E) -> (A, B, bool) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	return first, second, err == E{}
}

ensure_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
	return first, second, third
}

verify_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		fatal(err == E{}, message, loc, err)
	} else {
		panic(err == E{}, message, loc, err)
	}
	return first, second, third, err
}

confirm_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
	return first, second, third, err
}

assert_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
	return first, second, third
}

check_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		ignore(err == E{}, message, loc, err)
	} else {
		warn(err == E{}, message, loc, err)
	}
	return first, second, third, err
}

assume_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		warn(err == E{}, message, loc, err)
	}
	return first, second, third
}

expect_union_three :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	ok := err == E{}
	test(t, ok, message, loc, err)
	return first, second, third, ok
}

is_ok_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	return first, second, third, err == E{}
}

ensure_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
	return first, second, third, fourth
}

verify_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		fatal(err == E{}, message, loc, err)
	} else {
		panic(err == E{}, message, loc, err)
	}
	return first, second, third, fourth, err
}

confirm_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
	return first, second, third, fourth, err
}

assert_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		panic(err == E{}, message, loc, err)
	} else {
		error(err == E{}, message, loc, err)
	}
	return first, second, third, fourth
}

check_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_RELEASE {
		ignore(err == E{}, message, loc, err)
	} else {
		warn(err == E{}, message, loc, err)
	}
	return first, second, third, fourth, err
}

assume_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VKFIELD_IS_DEBUG {
		warn(err == E{}, message, loc, err)
	}
	return first, second, third, fourth
}

expect_union_four :: #force_inline proc(
	t: ^testing.T,
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	ok := err == E{}
	test(t, ok, message, loc, err)
	return first, second, third, fourth, ok
}

is_ok_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	return first, second, third, fourth, err == E{}
}
