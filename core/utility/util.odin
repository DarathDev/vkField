package vkField_utility

import "base:intrinsics"

VERBOSE :: #config(VERBOSE, true)

SemanticVersion :: struct {
	major: u8,
	minor: u8,
	patch: u8,
	tag:   string,
}

throw_not_implemented :: proc(location := #caller_location) {
	confirm(false, "Not Implemented!", location)
}

get_union_variant_index :: #force_inline proc(variant: ^$T) -> int where intrinsics.type_is_union(T) {
	return int((cast(^intrinsics.type_union_tag_type(T))(uintptr(variant) + intrinsics.type_union_tag_offset(T)))^)
}
