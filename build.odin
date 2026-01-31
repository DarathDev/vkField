package vulkan_build

import "core:fmt"
import "core:os/os2"
import "core:strings"

OdinBuildOption :: struct {
	flag:  string,
	value: []string,
}

OdinCollection :: struct {
	name: string,
	path: string,
}

ShaderFiles :: struct {
	input:  string,
	output: string,
}

COMMON_ODIN_BUILD_OPTIONS: []OdinBuildOption = {{flag = "build-mode", value = {"lib"}}}

COLLECTIONS: []OdinCollection = {{name = "vkField", path = "core"}}

OUTPUT_LIB_NAME := "vkField"

ODIN_CMD := "odin"

ODIN_BUILD_CMD := "build"

ODIN_SRC_CMD := "core"

SHADER_FOLDER := "shaders"

SHADER_COMPILER_CMD := "glslang"

SOURCE_SHADER_EXT := "hlsl"

COMPILED_SHADER_EXT := "spv"

main :: proc() {

	os2.process_start()
}

build_shaders :: proc() {
	cmdBuilder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&cmdBuilder, "%s", SHADER_COMPILER_CMD)
	for option in COMMON_ODIN_BUILD_OPTIONS {
		fmt.sbprintf(&cmdBuilder, " %s:%s", option.flag, option.value)
	}
	shaderCompileCmd: os2.Process_Desc = {
		command = SHADER_COMPILER_CMD,
	}
}

build_odin :: proc() {
	cmdBuilder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&cmdBuilder, "%s %s", ODIN_CMD, ODIN_BUILD_CMD)
	for option in COMMON_ODIN_BUILD_OPTIONS {
		fmt.sbprintf(&cmdBuilder, " %s:%s", option.flag, option.value)
	}
}
