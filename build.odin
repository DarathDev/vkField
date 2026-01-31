package vkField_build

import "core:fmt"
import "core:log"
import os "core:os/os2"
import "core:slice"
import "core:strings"

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

VKFIELD_SRC_DIR := "core"
MATLAB_DIR := "matlab"
VKFIELD_TEST_DIR := "test"

/* ----- ODIN ----- */
ODIN_CMD := "odin"
ODIN_BUILD_ARG := "build"
ODIN_TEST_ARG := "test"

OdinBuildOption :: struct {
	flag:  string,
	value: []string,
}

OdinCollection :: struct {
	name: string,
	path: string,
}

VKFIELD_COLLECTIONS: []OdinCollection = {{name = "vkField", path = "core"}}
VKFIELD_ODIN_BUILD_OPTIONS: []OdinBuildOption = {}
VKFIELD_ODIN_RELEASE_OPTIONS: []OdinBuildOption = {}
VKFIELD_ODIN_DEBUG_OPTIONS: []OdinBuildOption = {{flag = "debug"}}
VKFIELD_ODIN_LIB_OPTIONS: []OdinBuildOption = {{flag = "build-mode", value = {"lib"}}}
VKFIELD_ODIN_TEST_OPTIONS: []OdinBuildOption = {{flag = "build-mode", value = {"test"}}}

/* ----- GLSLANG ----- */
GLSLANG_CMD := "glslang"

GlslangConfigurationOption :: struct {
	flag:  GlslangFlag,
	value: string,
}

GlslangFlag :: union {
	rune,
	string,
}

SHADER_COMPILER_CMD := "glslang"
SOURCE_SHADER_EXT := "hlsl"
COMPILED_SHADER_EXT := "spv"

VKFIELD_GLSLANG_OPTIONS: []GlslangConfigurationOption = {
	{flag = 'V'},
	{flag = 'e', value = "main"},
	{flag = "target-env", value = "vulkan1.2"},
	{flag = "spirv-val"},
}

// odin build ./core -build-mode:lib -out:bin/debug/vkField.lib -collection:vkField=core -debug
// odin build ./scripts -out:bin/debug/oneRectSimulation.exe -debug -collection:vkField=core
// glslang -V shaders/pulse_echo.comp.hlsl -o shaders/pulse_echo.comp.spv -e main -gVS --target-env vulkan1.2 --spirv-val
// glslang -V shaders/pulse_echo_cum.comp.hlsl -o shaders/pulse_echo_cum.comp.spv -e main -gVS --target-env vulkan1.2 --spirv-val

main :: proc() {
	context.logger = log.create_console_logger(.Info)

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
		}
	}

	if len(VKFIELD_BUILD_MODE) == 0 do VKFIELD_BUILD_MODE = VKFIELD_DEFAULT_BUILD_MODE
	if len(VKFIELD_BUILD_TYPE) == 0 do VKFIELD_BUILD_TYPE = VKFIELD_DEFAULT_BUILD_TYPE
	if len(VKFIELD_OUTPUT_SUBDIR) == 0 {
		switch VKFIELD_BUILD_MODE {
		case "release":
			VKFIELD_OUTPUT_SUBDIR = VKFIELD_RELEASE_OUT_SUBDIR
		case "debug":
			VKFIELD_OUTPUT_SUBDIR = VKFIELD_DEBUG_OUT_SUBDIR
		}
	}

	switch VKFIELD_BUILD_TYPE {
	case "lib":
		log.assert(build_lib())
	case "test":
		log.assert(build_test())
	}
}

build_lib :: proc() -> (ok := true) {
	outputDir, _ := os.join_path({INSTALL_LOCATION, VKFIELD_LIBRARY_OUT_DIR, VKFIELD_OUTPUT_SUBDIR}, context.allocator)
	// Make Output Directory
	if !os.is_dir(outputDir) do os.make_directory_all(outputDir)

	// Compile Shaders
	for shader in PULSE_ECHO_SHADERS {
		compileShaderGlsl(shader) or_return
	}

	// Odin Compilation
	when ODIN_OS == .Windows {
		libraryName, _ := os.join_filename(VKFIELD_OUTPUT_LIB_NAME, "lib", context.allocator)
		libraryOutPath, _ := os.join_path({outputDir, libraryName}, context.allocator)
	}
	options := make([dynamic]OdinBuildOption)
	collect_odin_build_options(&options)
	append(&options, ..VKFIELD_ODIN_LIB_OPTIONS)
	append(&options, OdinBuildOption{flag = "out", value = {libraryOutPath}})

	odinCmd := make([dynamic]string)
	append(&odinCmd, ODIN_CMD, ODIN_BUILD_ARG, VKFIELD_SRC_DIR)
	append(&odinCmd, ..odin_options_to_args(options[:]))
	run_cmd(odinCmd[:]) or_return

	if VKFIELD_MATLAB {
		matlabLibraryName, _ := os.join_filename(fmt.aprintf("%s_lib", VKFIELD_OUTPUT_LIB_NAME), "lib", context.allocator)
		matlabPath, _ := os.join_path({INSTALL_LOCATION, MATLAB_DIR, matlabLibraryName}, context.allocator)
		os.copy_file(matlabPath, libraryOutPath)
	}

	return
}

build_test :: proc() -> (ok := true) {
	outputDir, _ := os.join_path({INSTALL_LOCATION, VKFIELD_BINARY_OUT_DIR, VKFIELD_OUTPUT_SUBDIR}, context.allocator)
	// Make Output Directory
	if !os.is_dir(outputDir) do os.make_directory_all(outputDir)

	// Compile Shaders
	for shader in PULSE_ECHO_SHADERS {
		compileShaderGlsl(shader) or_return
	}

	// Odin Compilation
	when ODIN_OS == .Windows {
		binaryName, _ := os.join_filename(VKFIELD_TESTS_NAME, "exe", context.allocator)
		binaryOutPath, _ := os.join_path({outputDir, binaryName}, context.allocator)
	}
	options := make([dynamic]OdinBuildOption)
	collect_odin_build_options(&options)
	append(&options, ..VKFIELD_ODIN_TEST_OPTIONS)
	append(&options, OdinBuildOption{flag = "out", value = {binaryOutPath}})

	odinCmd := make([dynamic]string)
	append(&odinCmd, ODIN_CMD, ODIN_BUILD_ARG, VKFIELD_TEST_DIR)
	append(&odinCmd, ..odin_options_to_args(options[:]))
	run_cmd(odinCmd[:]) or_return
	return
}

collect_odin_build_options :: proc(options: ^[dynamic]OdinBuildOption) {
	append(options, ..collections_to_options(VKFIELD_COLLECTIONS))
	append(options, ..VKFIELD_ODIN_BUILD_OPTIONS)
	switch VKFIELD_BUILD_MODE {
	case "debug":
		append(options, ..VKFIELD_ODIN_DEBUG_OPTIONS)
	}
}

run_cmd :: proc(cmd: []string, working_dir: string = "", loc := #caller_location) -> (ok: bool) {
	processDesc: os.Process_Desc = {
		command     = cmd,
		working_dir = working_dir,
	}
	log.infof("Executing: %s", strings.join(cmd, " "))
	_, stdout, stderr, err := os.process_exec(processDesc, context.allocator)
	stdoutText, _ := strings.clone_from_bytes(stdout)
	stderrText, _ := strings.clone_from_bytes(stderr)
	if len(stdoutText) > 0 do log.info(stdoutText, loc)
	if len(stderrText) > 0 do log.error(stderrText, loc)
	return err == os.General_Error.None
}

collections_to_options :: proc(collections: []OdinCollection) -> (options: []OdinBuildOption) {
	options = make([]OdinBuildOption, len(collections))
	for collection, index in collections {
		value := fmt.aprintf("%v=%v", collection.name, collection.path)
		options[index] = {
			flag  = "collection",
			value = slice.from_ptr(new_clone(value), 1),
		}
	}
	return
}

odin_options_to_args :: proc(options: []OdinBuildOption) -> (args: []string) {
	args = make([]string, len(options))
	for option, index in options {
		if len(option.value) == 0 {
			args[index] = fmt.tprintf("-%s", option.flag)
		} else {
			args[index] = fmt.tprintf("-%s:%s", option.flag, strings.join(option.value, ","))
		}
	}
	return
}

glslang_options_to_args :: proc(options: []GlslangConfigurationOption) -> (args: []string) {
	dArgs := make([dynamic]string, len(options))
	for option in options {
		switch var in option.flag {
		case rune:
			append(&dArgs, fmt.tprintf("-%c", var))
		case string:
			append(&dArgs, fmt.tprintf("--%s", var))
		}
		if len(option.value) > 0 {
			append(&dArgs, option.value)
		}
	}
	args = dArgs[:]
	return
}

compileShaderGlsl :: proc(shader: ShaderFiles) -> (ok := true) {
	dir, filename := os.split_path(shader.path)
	moduleName, _ := os.split_filename(filename)
	outputFilename, _ := os.join_filename(moduleName, COMPILED_SHADER_EXT, context.allocator)
	outputPath, _ := os.join_path({dir, outputFilename}, context.allocator)

	glslangCmd := make([dynamic]string)
	append(&glslangCmd, GLSLANG_CMD)
	append(&glslangCmd, shader.path)
	append(&glslangCmd, "-gVS")
	append(&glslangCmd, ..glslang_options_to_args({{flag = 'o', value = outputPath}}))
	append(&glslangCmd, ..glslang_options_to_args(VKFIELD_GLSLANG_OPTIONS))

	run_cmd(glslangCmd[:]) or_return
	return
}
