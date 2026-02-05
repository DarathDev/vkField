package vkfield

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:mem"
import os "core:os/os2"
import "core:testing"
import vk "vendor:vulkan"

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
	ensure_mem_zero,
	ensure_mem_one,
	ensure_mem_two,
	ensure_os_zero,
	ensure_os_one,
	ensure_os_two,
	ensure_vkResult_zero,
	ensure_vkResult_one,
	ensure_vkResult_two,
}

verify :: proc {
	verify_bool_zero,
	verify_bool_one,
	verify_bool_two,
	verify_mem_zero,
	verify_mem_one,
	verify_mem_two,
	verify_os_zero,
	verify_os_one,
	verify_os_two,
	verify_vkResult_zero,
	verify_vkResult_one,
	verify_vkResult_two,
}

confirm :: proc {
	confirm_bool_zero,
	confirm_bool_one,
	confirm_bool_two,
	confirm_mem_zero,
	confirm_mem_one,
	confirm_mem_two,
	confirm_os_zero,
	confirm_os_one,
	confirm_os_two,
	confirm_vkResult_zero,
	confirm_vkResult_one,
	confirm_vkResult_two,
}

assert :: proc {
	assert_bool_zero,
	assert_bool_one,
	assert_bool_two,
	assert_mem_zero,
	assert_mem_one,
	assert_mem_two,
	assert_os_zero,
	assert_os_one,
	assert_os_two,
	assert_vkResult_zero,
	assert_vkResult_one,
	assert_vkResult_two,
}

check :: proc {
	check_bool_zero,
	check_bool_one,
	check_bool_two,
	check_mem_zero,
	check_mem_one,
	check_mem_two,
	check_os_zero,
	check_os_one,
	check_os_two,
	check_vkResult_zero,
	check_vkResult_one,
	check_vkResult_two,
}

assume :: proc {
	assume_bool_zero,
	assume_bool_one,
	assume_bool_two,
	assume_mem_zero,
	assume_mem_one,
	assume_mem_two,
	assume_os_zero,
	assume_os_one,
	assume_os_two,
	assume_vkResult_zero,
	assume_vkResult_one,
	assume_vkResult_two,
}

expect :: proc {
	expect_bool_zero,
	expect_bool_one,
	expect_bool_two,
	expect_mem_zero,
	expect_mem_one,
	expect_mem_two,
	expect_os_zero,
	expect_os_one,
	expect_os_two,
	expect_vkResult_zero,
	expect_vkResult_one,
	expect_vkResult_two,
}

expect_not :: proc {
	expect_not_bool_zero,
	expect_not_bool_one,
	expect_not_bool_two,
}

isOk :: proc {
	isOk_mem_zero,
	isOk_mem_one,
	isOk_mem_two,
	isOk_os_zero,
	isOk_os_one,
	isOk_os_two,
	isOk_vkResult_zero,
	isOk_vkResult_one,
	isOk_vkResult_two,
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

ensure_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression(value),
	loc := #caller_location,
) -> T where intrinsics.type_is_boolean(B) {
	panic(bool(ok), message, loc)
	return value
}

verify_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression(value),
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
	message := #caller_expression(value),
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

assert_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression(value),
	loc := #caller_location,
) -> T where intrinsics.type_is_boolean(B) {
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
	message := #caller_expression(value),
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

assume_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression(value),
	loc := #caller_location,
) -> T where intrinsics.type_is_boolean(B) {
	when VKFIELD_IS_DEBUG {
		warn(bool(ok), message, loc)
	}
	return value
}

expect_bool_one :: #force_inline proc(
	t: ^testing.T,
	value: $T,
	ok: $B,
	message := #caller_expression(value),
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
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_boolean(B) #optional_ok {
	test(t, !bool(ok), message, loc)
	return value, !bool(ok)
}

ensure_bool_two :: #force_inline proc(value: $A, other: $B, ok: $C, message := "", loc := #caller_location) -> (A, B) where intrinsics.type_is_boolean(C) {
	panic(bool(ok), message, loc)
	return value, other
}

verify_bool_two :: #force_inline proc(
	value: $A,
	other: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	when RUDIMENT_IS_RELEASE || RUDIMENT_IS_BETA {
		fatal(bool(ok), message, loc)
	} else {
		panic(bool(ok), message, loc)
	}
	return value, other, bool(ok)
}

confirm_bool_two :: #force_inline proc(
	value: $A,
	other: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	when RUDIMENT_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		error(bool(ok), message, loc)
	}
	return value, other, bool(ok)
}

assert_bool_two :: #force_inline proc(value: $A, other: $B, ok: $C, message := "", loc := #caller_location) -> (A, B) where intrinsics.type_is_boolean(C) {
	when VKFIELD_IS_DEBUG {
		panic(bool(ok), message, loc)
	} else {
		ignore(bool(ok), message, loc)
	}
	return value, other
}

check_bool_two :: #force_inline proc(
	value: $A,
	other: $B,
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
	return value, other, bool(ok)
}

assume_bool_two :: #force_inline proc(value: $A, other: $B, ok: $C, message := "", loc := #caller_location) -> (A, B) where intrinsics.type_is_boolean(C) {
	when VKFIELD_IS_DEBUG {
		warn(bool(ok), message, loc)
	}
	return value, other
}

expect_bool_two :: #force_inline proc(
	t: ^testing.T,
	value: $A,
	other: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	test(t, bool(ok), message, loc)
	return value, other, bool(ok)
}

expect_not_bool_two :: #force_inline proc(
	t: ^testing.T,
	value: $A,
	other: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	test(t, !bool(ok), message, loc)
	return value, other, !bool(ok)
}

ensure_mem_zero :: #force_inline proc(err: mem.Allocator_Error, message := "", loc := #caller_location) {
	panic(err == nil, message, loc, err)
}

verify_mem_zero :: #force_inline proc(err: mem.Allocator_Error, message := "", loc := #caller_location) -> mem.Allocator_Error {
	when VKFIELD_IS_RELEASE {
		fatal(err == nil, message, loc, err)
	} else {
		panic(err == nil, message, loc, err)
	}
	return err
}

confirm_mem_zero :: #force_inline proc(err: mem.Allocator_Error, message := "", loc := #caller_location) -> mem.Allocator_Error {
	when VKFIELD_IS_DEBUG {
		panic(err == nil, message, loc, err)
	} else {
		error(err == nil, message, loc, err)
	}
	return err
}

assert_mem_zero :: #force_inline proc(err: mem.Allocator_Error, message := "", loc := #caller_location) {
	when VKFIELD_IS_DEBUG {
		panic(err == nil, message, loc, err)
	} else {
		ignore(err == nil, message, loc, err)
	}
}

check_mem_zero :: #force_inline proc(err: mem.Allocator_Error, message := "", loc := #caller_location) -> mem.Allocator_Error {
	when VKFIELD_IS_RELEASE {
		ignore(err == nil, message, loc, err)
	} else {
		warn(err == nil, message, loc, err)
	}
	return err
}

assume_mem_zero :: #force_inline proc(err: mem.Allocator_Error, message := "", loc := #caller_location) {
	when VKFIELD_IS_DEBUG {
		warn(err == nil, message, loc, err)
	}
}

expect_mem_zero :: #force_inline proc(t: ^testing.T, err: mem.Allocator_Error, message := "", loc := #caller_location) -> bool {
	ok := err == nil
	test(t, ok, message, loc, err)
	return ok
}

isOk_mem_zero :: #force_inline proc(err: mem.Allocator_Error) -> bool {
	return err == nil
}

ensure_mem_one :: #force_inline proc(value: $T, err: mem.Allocator_Error, message := #caller_expression(value), loc := #caller_location) -> T {
	panic(err == nil, message, loc, err)
	return value
}

verify_mem_one :: #force_inline proc(
	value: $T,
	err: mem.Allocator_Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	T,
	mem.Allocator_Error,
) {
	when VKFIELD_IS_RELEASE {
		fatal(err == nil, message, loc, err)
	} else {
		panic(err == nil, message, loc, err)
	}
	return value, err
}

confirm_mem_one :: #force_inline proc(
	value: $T,
	err: mem.Allocator_Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	T,
	mem.Allocator_Error,
) {
	when VKFIELD_IS_DEBUG {
		panic(err == nil, message, loc, err)
	} else {
		error(err == nil, message, loc, err)
	}
	return value, err
}

assert_mem_one :: #force_inline proc(value: $T, err: mem.Allocator_Error, message := #caller_expression(value), loc := #caller_location) -> T {
	when VKFIELD_IS_DEBUG {
		panic(err == nil, message, loc, err)
	} else {
		ignore(err == nil, message, loc, err)
	}
	return value
}

check_mem_one :: #force_inline proc(
	value: $T,
	err: mem.Allocator_Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	T,
	mem.Allocator_Error,
) {
	when VKFIELD_IS_RELEASE {
		ignore(err == nil, message, loc, err)
	} else {
		warn(err == nil, message, loc, err)
	}
	return value, err
}

assume_mem_one :: #force_inline proc(value: $T, err: mem.Allocator_Error, message := #caller_expression(value), loc := #caller_location) -> T {
	when VKFIELD_IS_DEBUG {
		warn(err == nil, message, loc, err)
	}
	return value
}

expect_mem_one :: #force_inline proc(
	t: ^testing.T,
	value: $T,
	err: mem.Allocator_Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	T,
	bool,
) #optional_ok {
	ok := err == nil
	test(t, ok, message, loc, err)
	return value, ok
}

isOk_mem_one :: #force_inline proc(value: $T, err: mem.Allocator_Error) -> (T, bool) {
	return value, err == nil
}

ensure_mem_two :: #force_inline proc(value: $A, other: $B, err: mem.Allocator_Error, message := #caller_expression(value), loc := #caller_location) -> (A, B) {
	panic(err == nil, message, loc, err)
	return value, other
}

verify_mem_two :: #force_inline proc(
	value: $A,
	other: $B,
	err: mem.Allocator_Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	A,
	B,
	mem.Allocator_Error,
) {
	when VKFIELD_IS_RELEASE {
		fatal(err == nil, message, loc, err)
	} else {
		panic(err == nil, message, loc, err)
	}
	return value, other, err
}

confirm_mem_two :: #force_inline proc(
	value: $A,
	other: $B,
	err: mem.Allocator_Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	A,
	B,
	mem.Allocator_Error,
) {
	when VKFIELD_IS_DEBUG {
		panic(err == nil, message, loc, err)
	} else {
		error(err == nil, message, loc, err)
	}
	return value, other, err
}

assert_mem_two :: #force_inline proc(value: $A, other: $B, err: mem.Allocator_Error, message := #caller_expression(value), loc := #caller_location) -> (A, B) {
	when VKFIELD_IS_DEBUG {
		panic(err == nil, message, loc, err)
	} else {
		ignore(err == nil, message, loc, err)
	}
	return value, other
}

check_mem_two :: #force_inline proc(
	value: $A,
	other: $B,
	err: mem.Allocator_Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	A,
	B,
	mem.Allocator_Error,
) {
	when VKFIELD_IS_RELEASE {
		ignore(err == nil, message, loc, err)
	} else {
		warn(err == nil, message, loc, err)
	}
	return value, other, err
}

assume_mem_two :: #force_inline proc(value: $A, other: $B, err: mem.Allocator_Error, message := #caller_expression(value), loc := #caller_location) -> (A, B) {
	when VKFIELD_IS_DEBUG {
		warn(err == nil, message, loc, err)
	}
	return value, other
}

expect_mem_two :: #force_inline proc(
	t: ^testing.T,
	value: $A,
	other: $B,
	err: mem.Allocator_Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) {
	ok := err == nil
	test(t, ok, message, loc, err)
	return value, other, ok
}

isOk_mem_two :: #force_inline proc(value: $A, other: $B, err: mem.Allocator_Error) -> (A, B, bool) {
	return value, other, err == nil
}

ensure_os_zero :: #force_inline proc(err: os.Error, message := "", loc := #caller_location) {
	panic(err == os.ERROR_NONE, message, loc, err)
}

verify_os_zero :: #force_inline proc(err: os.Error, message := "", loc := #caller_location) -> os.Error {
	when VKFIELD_IS_RELEASE {
		fatal(err == os.ERROR_NONE, message, loc, err)
	} else {
		panic(err == os.ERROR_NONE, message, loc, err)
	}
	return err
}

confirm_os_zero :: #force_inline proc(err: os.Error, message := "", loc := #caller_location) -> os.Error {
	when VKFIELD_IS_DEBUG {
		panic(err == os.ERROR_NONE, message, loc, err)
	} else {
		error(err == os.ERROR_NONE, message, loc, err)
	}
	return err
}

assert_os_zero :: #force_inline proc(err: os.Error, message := "", loc := #caller_location) {
	when VKFIELD_IS_DEBUG {
		panic(err == os.ERROR_NONE, message, loc, err)
	} else {
		ignore(err == os.ERROR_NONE, message, loc, err)
	}
}

check_os_zero :: #force_inline proc(err: os.Error, message := "", loc := #caller_location) -> os.Error {
	when VKFIELD_IS_RELEASE {
		ignore(err == os.ERROR_NONE, message, loc, err)
	} else {
		warn(err == os.ERROR_NONE, message, loc, err)
	}
	return err
}

assume_os_zero :: #force_inline proc(err: os.Error, message := "", loc := #caller_location) {
	when VKFIELD_IS_DEBUG {
		warn(err == os.ERROR_NONE, message, loc, err)
	}
}

expect_os_zero :: #force_inline proc(t: ^testing.T, err: os.Error, message := "", loc := #caller_location) -> bool {
	ok := err == os.ERROR_NONE
	test(t, ok, message, loc, err)
	return ok
}

isOk_os_zero :: #force_inline proc(err: os.Error) -> bool {
	return err == os.ERROR_NONE
}

ensure_os_one :: #force_inline proc(value: $T, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> T {
	panic(err == os.ERROR_NONE, message, loc, err)
	return value
}

verify_os_one :: #force_inline proc(value: $T, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> (T, os.Error) {
	when VKFIELD_IS_RELEASE {
		fatal(err == os.ERROR_NONE, message, loc, err)
	} else {
		panic(err == os.ERROR_NONE, message, loc, err)
	}
	return value, err
}

confirm_os_one :: #force_inline proc(value: $T, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> (T, os.Error) {
	when VKFIELD_IS_DEBUG {
		panic(err == os.ERROR_NONE, message, loc, err)
	} else {
		error(err == os.ERROR_NONE, message, loc, err)
	}
	return value, err
}

assert_os_one :: #force_inline proc(value: $T, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> T {
	when VKFIELD_IS_DEBUG {
		panic(err == os.ERROR_NONE, message, loc, err)
	} else {
		ignore(err == os.ERROR_NONE, message, loc, err)
	}
	return value
}

check_os_one :: #force_inline proc(value: $T, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> (T, os.Error) {
	when VKFIELD_IS_RELEASE {
		ignore(err == os.ERROR_NONE, message, loc, err)
	} else {
		warn(err == os.ERROR_NONE, message, loc, err)
	}
	return value, err
}

assume_os_one :: #force_inline proc(value: $T, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> T {
	when VKFIELD_IS_DEBUG {
		warn(err == os.ERROR_NONE, message, loc, err)
	}
	return value
}

expect_os_one :: #force_inline proc(
	t: ^testing.T,
	value: $T,
	err: os.Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	T,
	bool,
) #optional_ok {
	ok := err == os.ERROR_NONE
	test(t, ok, message, loc, err)
	return value, ok
}

isOk_os_one :: #force_inline proc(value: $T, err: os.Error) -> (T, bool) {
	return value, err == os.ERROR_NONE
}

ensure_os_two :: #force_inline proc(value: $A, other: $B, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> (A, B) {
	panic(err == os.ERROR_NONE, message, loc, err)
	return value, other
}

verify_os_two :: #force_inline proc(value: $A, other: $B, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> (A, B, os.Error) {
	when VKFIELD_IS_RELEASE {
		fatal(err == os.ERROR_NONE, message, loc, err)
	} else {
		panic(err == os.ERROR_NONE, message, loc, err)
	}
	return value, other, err
}

confirm_os_two :: #force_inline proc(value: $A, other: $B, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> (A, B, os.Error) {
	when VKFIELD_IS_DEBUG {
		panic(err == os.ERROR_NONE, message, loc, err)
	} else {
		error(err == os.ERROR_NONE, message, loc, err)
	}
	return value, other, err
}

assert_os_two :: #force_inline proc(value: $A, other: $B, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> (A, B) {
	when VKFIELD_IS_DEBUG {
		panic(err == os.ERROR_NONE, message, loc, err)
	} else {
		ignore(err == os.ERROR_NONE, message, loc, err)
	}
	return value, other
}

check_os_two :: #force_inline proc(value: $A, other: $B, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> (A, B, os.Error) {
	when VKFIELD_IS_RELEASE {
		ignore(err == os.ERROR_NONE, message, loc, err)
	} else {
		warn(err == os.ERROR_NONE, message, loc, err)
	}
	return value, other, err
}

assume_os_two :: #force_inline proc(value: $A, other: $B, err: os.Error, message := #caller_expression(value), loc := #caller_location) -> (A, B) {
	when VKFIELD_IS_DEBUG {
		warn(err == os.ERROR_NONE, message, loc, err)
	}
	return value, other
}

expect_os_two :: #force_inline proc(
	t: ^testing.T,
	value: $A,
	other: $B,
	err: os.Error,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) {
	ok := err == os.ERROR_NONE
	test(t, ok, message, loc, err)
	return value, other, ok
}

isOk_os_two :: #force_inline proc(value: $A, other: $B, err: os.Error) -> (A, B, bool) {
	return value, other, err == os.ERROR_NONE
}

ensure_vkResult_one :: #force_inline proc(value: $T, result: vk.Result, message := #caller_expression(value), loc := #caller_location) -> T {
	panic(result >= .SUCCESS, message, loc, result)
	return value
}

verify_vkResult_one :: #force_inline proc(value: $T, result: vk.Result, message := #caller_expression(value), loc := #caller_location) -> (T, vk.Result) {
	when VKFIELD_IS_RELEASE {
		fatal(result >= .SUCCESS, message, loc, result)
	} else {
		panic(result >= .SUCCESS, message, loc, result)
	}
	return value, result
}

confirm_vkResult_one :: #force_inline proc(value: $T, result: vk.Result, message := #caller_expression(value), loc := #caller_location) -> (T, vk.Result) {
	when VKFIELD_IS_DEBUG {
		panic(result >= .SUCCESS, message, loc, result)
	} else {
		error(result >= .SUCCESS, message, loc, result)
	}
	return value, result
}

assert_vkResult_one :: #force_inline proc(value: $T, result: vk.Result, message := #caller_expression(value), loc := #caller_location) -> T {
	when VKFIELD_IS_DEBUG {
		panic(result >= .SUCCESS, message, loc, result)
	} else {
		ignore(result >= .SUCCESS, message, loc, result)
	}
	return value
}

check_vkResult_one :: #force_inline proc(value: $T, result: vk.Result, message := #caller_expression(value), loc := #caller_location) -> (T, vk.Result) {
	when VKFIELD_IS_RELEASE {
		ignore(result >= .SUCCESS, message, loc, result)
	} else {
		warn(result >= .SUCCESS, message, loc, result)
	}
	return value, result
}

assume_vkResult_one :: #force_inline proc(value: $T, result: vk.Result, message := #caller_expression(value), loc := #caller_location) -> T {
	when VKFIELD_IS_DEBUG {
		warn(result >= .SUCCESS, message, loc, result)
	}
	return value
}

expect_vkResult_one :: #force_inline proc(
	t: ^testing.T,
	value: $T,
	result: vk.Result,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	T,
	bool,
) #optional_ok {
	ok := result >= .SUCCESS
	test(t, ok, message, loc, result)
	return value, ok
}

isOk_vkResult_one :: #force_inline proc(value: $T, result: vk.Result) -> (T, bool) {
	return value, result >= .SUCCESS
}

ensure_vkResult_two :: #force_inline proc(value: $A, other: $B, result: vk.Result, message := #caller_expression(value), loc := #caller_location) -> (A, B) {
	panic(result >= .SUCCESS, message, loc, result)
	return value, other
}

verify_vkResult_two :: #force_inline proc(
	value: $A,
	other: $B,
	result: vk.Result,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	A,
	B,
	vk.Result,
) {
	when VKFIELD_IS_RELEASE {
		fatal(result >= .SUCCESS, message, loc, result)
	} else {
		panic(result >= .SUCCESS, message, loc, result)
	}
	return value, other, result
}

confirm_vkResult_two :: #force_inline proc(
	value: $A,
	other: $B,
	result: vk.Result,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	A,
	B,
	vk.Result,
) {
	when VKFIELD_IS_DEBUG {
		panic(result >= .SUCCESS, message, loc, result)
	} else {
		error(result >= .SUCCESS, message, loc, result)
	}
	return value, other, result
}

assert_vkResult_two :: #force_inline proc(value: $A, other: $B, result: vk.Result, message := #caller_expression(value), loc := #caller_location) -> (A, B) {
	when VKFIELD_IS_DEBUG {
		panic(result >= .SUCCESS, message, loc, result)
	} else {
		ignore(result >= .SUCCESS, message, loc, result)
	}
	return value, other
}

check_vkResult_two :: #force_inline proc(
	value: $A,
	other: $B,
	result: vk.Result,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	A,
	B,
	vk.Result,
) {
	when VKFIELD_IS_RELEASE {
		ignore(result >= .SUCCESS, message, loc, result)
	} else {
		warn(result >= .SUCCESS, message, loc, result)
	}
	return value, other, result
}

assume_vkResult_two :: #force_inline proc(value: $A, other: $B, result: vk.Result, message := #caller_expression(value), loc := #caller_location) -> (A, B) {
	when VKFIELD_IS_DEBUG {
		warn(result >= .SUCCESS, message, loc, result)
	}
	return value, other
}

expect_vkResult_two :: #force_inline proc(
	t: ^testing.T,
	value: $A,
	other: $B,
	result: vk.Result,
	message := #caller_expression(value),
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) {
	ok := result >= .SUCCESS
	test(t, ok, message, loc, result)
	return value, other, ok
}

isOk_vkResult_two :: #force_inline proc(value: $A, other: $B, result: vk.Result) -> (A, B, bool) {
	return value, other, result >= .SUCCESS
}

ensure_vkResult_zero :: #force_inline proc(result: vk.Result, message := #caller_expression(result), loc := #caller_location) {
	panic(result >= .SUCCESS, message, loc, result)
}

verify_vkResult_zero :: #force_inline proc(result: vk.Result, message := #caller_expression(result), loc := #caller_location) -> vk.Result {
	when VKFIELD_IS_RELEASE {
		fatal(result >= .SUCCESS, message, loc, result)
	} else {
		panic(result >= .SUCCESS, message, loc, result)
	}
	return result
}

confirm_vkResult_zero :: #force_inline proc(result: vk.Result, message := #caller_expression(result), loc := #caller_location) -> vk.Result {
	when VKFIELD_IS_DEBUG {
		panic(result >= .SUCCESS, message, loc, result)
	} else {
		error(result >= .SUCCESS, message, loc, result)
	}
	return result
}

assert_vkResult_zero :: #force_inline proc(result: vk.Result, message := #caller_expression(result), loc := #caller_location) {
	when VKFIELD_IS_DEBUG {
		panic(result >= .SUCCESS, message, loc, result)
	} else {
		ignore(result >= .SUCCESS, message, loc, result)
	}
}

check_vkResult_zero :: #force_inline proc(result: vk.Result, message := #caller_expression(result), loc := #caller_location) -> vk.Result {
	when VKFIELD_IS_RELEASE {
		ignore(result >= .SUCCESS, message, loc, result)
	} else {
		warn(result >= .SUCCESS, message, loc, result)
	}
	return result
}

assume_vkResult_zero :: #force_inline proc(result: vk.Result, message := #caller_expression(result), loc := #caller_location) {
	when VKFIELD_IS_DEBUG {
		warn(result >= .SUCCESS, message, loc, result)
	}
}

expect_vkResult_zero :: #force_inline proc(t: ^testing.T, result: vk.Result, message := #caller_expression(result), loc := #caller_location) -> bool {
	ok := result >= .SUCCESS
	test(t, ok, message, loc, result)
	return ok
}

isOk_vkResult_zero :: #force_inline proc(result: vk.Result) -> bool {
	return result >= .SUCCESS
}
