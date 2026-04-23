package vkField_build

import "base:runtime"
import util "core/utility"
import "core:fmt"
import "core:log"
import "core:os"

when ODIN_DEBUG { VKFIELD_DEFAULT_BUILD_MODE :: "debug" } else { VKFIELD_DEFAULT_BUILD_MODE :: "release" }
VKFIELD_BUILD_MODE: string
VKFIELD_DEFAULT_BUILD_TYPE :: "lib"
VKFIELD_BUILD_TYPE: string

INSTALL_LOCATION :: #config(INSTALL_LOCATION, ".")

VKFIELD_BINARY_OUT_DIR := "bin"
VKFIELD_LIBRARY_OUT_DIR := "lib"
VKFIELD_RELEASE_OUT_SUBDIR := "release"
VKFIELD_DEBUG_OUT_SUBDIR := "debug"
VKFIELD_OUTPUT_SUBDIR := ""
VKFIELD_OUTPUT_LIB_NAME := "vkField"
VKFIELD_TESTS_NAME := "vkField_tests"
VKFIELD_MATLAB := #config(MATLAB, true)

LOG_DEBUG := #config(LOG_DEBUG, false)

VKFIELD_SRC_DIR := "core"
MATLAB_DIR := "matlab"
VKFIELD_TEST_DIR := "test"

VKFIELD_COLLECTIONS: []OdinCollection = {{name = "vkField", path = "core"}}
VKFIELD_ODIN_BUILD_OPTIONS: []OdinBuildOption = {}
VKFIELD_ODIN_RELEASE_OPTIONS: []OdinBuildOption = {}
VKFIELD_ODIN_DEBUG_OPTIONS: []OdinBuildOption = {{flag = "debug"}}
VKFIELD_ODIN_LIB_OPTIONS: []OdinBuildOption = {{flag = "build-mode", value = {"lib"}}}
VKFIELD_ODIN_TEST_OPTIONS: []OdinBuildOption = {{flag = "build-mode", value = {"test"}}}

VKFIELD_ODIN_DEBUG_DEFINES: []OdinDefine = {{name = "REQUIRE_RESOURCE_LABELS", value = "false"}}

@(private = "file")
is_ok :: util.is_ok
@(private = "file")
confirm :: util.confirm
@(private = "file")
check :: util.check
@(private = "file")
assert :: util.assert
@(private = "file")
assume :: util.assume

VKFIELD_GLSLANG_OPTIONS: []CliOptions = {{flag = 'V'}, {flag = 'e', value = "main"}, {flag = "target-env", value = "vulkan1.2"}, {flag = "spirv-val"}}

// odin build ./core -build-mode:lib -out:bin/debug/vkField.lib -collection:vkField=core -debug
// odin build ./scripts -out:bin/debug/oneRectSimulation.exe -debug -collection:vkField=core
// glslang -V shaders/pulse_echo.comp.hlsl -o shaders/pulse_echo.comp.spv -e main -gVS --target-env vulkan1.2 --spirv-val
// glslang -V shaders/pulse_echo_cum.comp.hlsl -o shaders/pulse_echo_cum.comp.spv -e main -gVS --target-env vulkan1.2 --spirv-val

main :: proc() {
	logger: runtime.Logger
	if LOG_DEBUG do logger = log.create_console_logger(.Debug)
	else do logger = log.create_console_logger(.Info)
	context.logger = logger

	options := make([dynamic]OdinBuildOption)
	append(&options, ..VKFIELD_ODIN_BUILD_OPTIONS)
	append(&options, ..odin_collections_to_options(VKFIELD_COLLECTIONS))
	args := os.args
	for arg in args {
		switch arg {
		case "-d":
			fallthrough
		case "-debug":
			VKFIELD_BUILD_MODE = "debug"
		case "-l":
			fallthrough
		case "-lib":
			VKFIELD_BUILD_TYPE = "lib"
		case "-t":
			fallthrough
		case "-tests":
			fallthrough
		case "-test":
			VKFIELD_BUILD_TYPE = "test"
		case "-matlab":
			VKFIELD_MATLAB = true
		case "-no-break":
			append(&options, ..odin_defines_to_options({{"MESSENGER_BREAKPOINT", "false"}}))
		}
	}

	if len(VKFIELD_BUILD_MODE) == 0 {
		VKFIELD_BUILD_MODE = VKFIELD_DEFAULT_BUILD_MODE
	}
	if len(VKFIELD_BUILD_TYPE) == 0 {
		VKFIELD_BUILD_TYPE = VKFIELD_DEFAULT_BUILD_TYPE
	}
	if len(VKFIELD_OUTPUT_SUBDIR) == 0 {
		switch VKFIELD_BUILD_MODE {
		case "release":
			VKFIELD_OUTPUT_SUBDIR = VKFIELD_RELEASE_OUT_SUBDIR
		case "debug":
			VKFIELD_OUTPUT_SUBDIR = VKFIELD_DEBUG_OUT_SUBDIR
		}
	}
	switch VKFIELD_BUILD_MODE {
	case "debug":
		append(&options, ..VKFIELD_ODIN_DEBUG_OPTIONS)
		append(&options, ..odin_defines_to_options(VKFIELD_ODIN_DEBUG_DEFINES))
	}
	append(
		&options,
		..odin_defines_to_options(
			{
				{name = "SAMPLE_GROUP_X", value = fmt.aprintf("%v", SAMPLE_GROUP_X)},
				{name = "RECEIVE_GROUP_Y", value = fmt.aprintf("%v", RECEIVE_GROUP_Y)},
				{name = "SCATTER_REDUCTION_Z", value = fmt.aprintf("%v", SCATTER_REDUCTION_Z)},
			},
		),
	)
	switch VKFIELD_BUILD_TYPE {
	case "lib":
		build_lib(&options)
	case "test":
		build_test(&options)
	}
}

build_lib :: proc(options: ^[dynamic]OdinBuildOption) -> (ok := true) {
	assert(check_cmd(ODIN_CMD), fmt.aprintf("Odin Command \"%v\" not found", ODIN_CMD))
	assert(check_cmd(SLANG_CMD), fmt.aprintf("Slang Command \"%v\" not found", SLANG_CMD))

	// Compile Shaders
	for shader in VKFIELD_PULSE_ECHO_SHADERS do confirm(compile_shader_slangc(shader, {{"SAMPLE_GROUP_X", fmt.aprintf("%v", SAMPLE_GROUP_X)}, {"RECEIVE_GROUP_Y", fmt.aprintf("%v", RECEIVE_GROUP_Y)}, {"SCATTER_REDUCTION_Z", fmt.aprintf("%v", SCATTER_REDUCTION_Z)}}))

	outputDir := assume(os.join_path({INSTALL_LOCATION, VKFIELD_LIBRARY_OUT_DIR, VKFIELD_OUTPUT_SUBDIR}, context.allocator))
	// Make Output Directory
	if !os.is_directory(outputDir) do os.make_directory_all(outputDir)

	// Odin Compilation
	when ODIN_OS == .Windows {
		libraryName := assume(os.join_filename(VKFIELD_OUTPUT_LIB_NAME, "lib", context.allocator))
	} else when ODIN_OS == .Linux {
		libraryName := assume(os.join_filename(VKFIELD_OUTPUT_LIB_NAME, "a", context.allocator))
	}
	libraryOutPath := assume(os.join_path({outputDir, libraryName}, context.allocator))
	append(options, ..VKFIELD_ODIN_LIB_OPTIONS)
	append(options, OdinBuildOption{flag = "out", value = {libraryOutPath}})

	odinCmd := make([dynamic]string)
	append(&odinCmd, ODIN_CMD, ODIN_BUILD_ARG, VKFIELD_SRC_DIR)
	append(&odinCmd, ..odin_options_to_args(options[:]))
	assert(assert(run_cmd(odinCmd[:])) == 0)

	if VKFIELD_MATLAB {
		when ODIN_OS == .Windows {
			matlabLibraryName := assume(os.join_filename(fmt.aprintf("%s_lib", VKFIELD_OUTPUT_LIB_NAME), "lib", context.allocator))
		} else when ODIN_OS == .Linux {
			matlabLibraryName := assume(os.join_filename(fmt.aprintf("%s_lib", VKFIELD_OUTPUT_LIB_NAME), "a", context.allocator))
		}
		matlabPath := assume(os.join_path({INSTALL_LOCATION, MATLAB_DIR, matlabLibraryName}, context.allocator))
		assert(os.copy_file(matlabPath, libraryOutPath))
	}

	return
}

build_test :: proc(options: ^[dynamic]OdinBuildOption) {
	assert(check_cmd(ODIN_CMD), fmt.aprintf("Odin Command \"%v\" not found", ODIN_CMD))
	assert(check_cmd(SLANG_CMD), fmt.aprintf("Slang Command \"%v\" not found", SLANG_CMD))

	// Compile Shaders
	for shader in VKFIELD_PULSE_ECHO_SHADERS do assert(compile_shader_slangc(shader, {{"SAMPLE_GROUP_X", fmt.aprintf("%v", SAMPLE_GROUP_X)}, {"RECEIVE_GROUP_Y", fmt.aprintf("%v", RECEIVE_GROUP_Y)}, {"SCATTER_REDUCTION_Z", fmt.aprintf("%v", SCATTER_REDUCTION_Z)}}))

	outputDir := assume(os.join_path({INSTALL_LOCATION, VKFIELD_BINARY_OUT_DIR, VKFIELD_OUTPUT_SUBDIR}, context.allocator))
	// Make Output Directory
	if !os.is_dir(outputDir) do os.make_directory_all(outputDir)

	// Odin Compilation
	when ODIN_OS == .Windows {
		binaryName, _ := os.join_filename(VKFIELD_TESTS_NAME, "exe", context.allocator)
	} else when ODIN_OS == .Linux {
		binaryName := VKFIELD_TESTS_NAME
	}
	binaryOutPath, _ := os.join_path({outputDir, binaryName}, context.allocator)
	append(options, ..VKFIELD_ODIN_TEST_OPTIONS)
	append(options, OdinBuildOption{flag = "out", value = {binaryOutPath}})

	odinCmd := make([dynamic]string)
	append(&odinCmd, ODIN_CMD, ODIN_BUILD_ARG, VKFIELD_TEST_DIR)
	append(&odinCmd, ..odin_options_to_args(options[:]))
	assert(assert(run_cmd(odinCmd[:])) == 0)
	return
}
