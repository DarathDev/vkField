package vkField_build

import "base:runtime"
import util "core/utility"
import "core:fmt"
import "core:log"
import "core:os"
import si "core:sys/info"

when ODIN_DEBUG { VKFIELD_DEFAULT_BUILD_MODE :: "debug" } else { VKFIELD_DEFAULT_BUILD_MODE :: "release" }
VKFIELD_BUILD_MODE: string
VKFIELD_DEFAULT_BUILD_TYPE :: "lib"
VKFIELD_BUILD_TYPE: string

INSTALL_LOCATION :: #config(INSTALL_LOCATION, ".")

TMP_DIRECTORY :: #config(TMP_DIRECTORY, "tmp/")
EXTERN_DIRECTORY :: #config(EXTERN_DIRECTORY, "extern/")
IMPORT_DIRECTORY :: #config(IMPORT_DIRECTORY, "import/")

VKFIELD_BINARY_OUT_DIR := "bin"
VKFIELD_LIBRARY_OUT_DIR := "lib"
VKFIELD_RELEASE_OUT_SUBDIR := "release"
VKFIELD_DEBUG_OUT_SUBDIR := "debug"
VKFIELD_OUTPUT_SUBDIR := ""
VKFIELD_OUTPUT_LIB_NAME := "vkField"
VKFIELD_TESTS_NAME := "vkField_tests"
VKFIELD_MATLAB := #config(MATLAB, true)
VKFIELD_ADDRESS_SANITIZER := #config(ADDRESS_SANITIZER, true)

LOG_DEBUG := #config(LOG_DEBUG, false)

VKFIELD_SRC_DIR := "core"
MATLAB_DIR := "matlab"
VKFIELD_TEST_DIR := "test"
VKFIELD_TEST_EXE_TYPE := #config(TEST_EXE_TYPE, "test") // "test" or "exe"

VKFIELD_COLLECTIONS: []OdinCollection = {{name = "vkField", path = "core"}, {name = "import", path = IMPORT_DIRECTORY}}
VKFIELD_ODIN_BUILD_OPTIONS: []OdinBuildOption = {}
VKFIELD_ODIN_RELEASE_OPTIONS: []OdinBuildOption = {{flag = "o", value = {"speed"}}}
VKFIELD_ODIN_DEBUG_OPTIONS: []OdinBuildOption = {{flag = "debug"}}
VKFIELD_ODIN_TEST_OPTIONS: []OdinBuildOption = {{flag = "build-mode", value = {VKFIELD_TEST_EXE_TYPE}}}
VKFIELD_ODIN_LIB_OPTIONS: []OdinBuildOption = {{flag = "build-mode", value = {"lib"}}, {flag = "reloc-mode", value = {"pic"}}}

VKFIELD_ODIN_TEST_DEFINES: []OdinDefine = {{name = "ODIN_TEST_THREADS", value = "1"}, {name = "ODIN_TEST_RANDOM_SEED", value = "0xcafebabe"}}
VKFIELD_ODIN_PROFILE_DEFINES: []OdinDefine = {{name = "PROF_MODE", value = "1"}, {name = "ENABLE_RENDERDOC", value = "false"}}

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

main :: proc() {
	logger: runtime.Logger
	if LOG_DEBUG do logger = log.create_console_logger(.Debug)
	else do logger = log.create_console_logger(.Info)
	logger.options -= {.Level, .Date, .Time, .Line, .Procedure, .Short_File_Path}
	log.create_console_logger()
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
		case "-r":
			fallthrough
		case "-release":
			VKFIELD_BUILD_MODE = "release"
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
		case "-profile":
			append(&options, ..odin_defines_to_options(VKFIELD_ODIN_PROFILE_DEFINES))
		case "-asan":
			VKFIELD_ADDRESS_SANITIZER = true
		case "-no-break":
			append(&options, ..odin_defines_to_options({{"MESSENGER_BREAKPOINT", "false"}}))
		}
	}

	features := si.cpu_features()
	append(&options, OdinBuildOption{flag = "microarch", value = {"native"}})
	if .avx512f in features && .avx512bw in features && .avx512dq in features {
		append(&options, OdinBuildOption{flag = "target-features", value = {"avx512f,avx512bw,avx512dq"}})
	} else if .avx2 in features {
		append(&options, OdinBuildOption{flag = "target-features", value = {"avx2"}})
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
	case "release":
		append(&options, ..VKFIELD_ODIN_RELEASE_OPTIONS)
	case "debug":
		append(&options, ..VKFIELD_ODIN_DEBUG_OPTIONS)
		if VKFIELD_ADDRESS_SANITIZER {
			append(&options, OdinBuildOption{flag = "sanitize", value = {"address"}})
		}
		append(&options, ..odin_defines_to_options(VKFIELD_ODIN_DEBUG_DEFINES))
	}
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
	for shader in VKFIELD_PULSE_ECHO_SHADERS do confirm(compile_shader_slangc(shader))

	// Compile PFFFT
	build_pffft() or_return

	outputDir := assume(os.join_path({INSTALL_LOCATION, VKFIELD_LIBRARY_OUT_DIR, VKFIELD_OUTPUT_SUBDIR}, context.allocator))
	// Make Output Directory
	if !os.is_directory(outputDir) {
		build_log(os.stdout, .Info, fmt.tprintf("Making Directory %s", outputDir))
		os.make_directory_all(outputDir)
	}

	// Odin Compilation
	when ODIN_OS == .Windows {
		libraryName := assume(os.join_filename(VKFIELD_OUTPUT_LIB_NAME, "lib", context.allocator))
		_, cppCompilerKind, _ := detect_cpp_compiler()
		if cppCompilerKind == .MSVC do append(options, OdinBuildOption{flag = "extra-linker-flags", value = {"/IGNORE:4006"}})
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
		build_log(os.stdout, .Info, fmt.tprintf("Copying %s to %s", libraryOutPath, matlabPath))
		assert(os.copy_file(matlabPath, libraryOutPath))
	}

	return
}

build_test :: proc(options: ^[dynamic]OdinBuildOption) -> (ok := true) {
	assert(check_cmd(ODIN_CMD), fmt.aprintf("Odin Command \"%v\" not found", ODIN_CMD))
	assert(check_cmd(SLANG_CMD), fmt.aprintf("Slang Command \"%v\" not found", SLANG_CMD))

	// Compile Shaders
	for shader in VKFIELD_PULSE_ECHO_SHADERS do assert(compile_shader_slangc(shader))

	// Compile PFFFT
	build_pffft() or_return

	outputDir := assume(os.join_path({INSTALL_LOCATION, VKFIELD_BINARY_OUT_DIR, VKFIELD_OUTPUT_SUBDIR}, context.allocator))
	// Make Output Directory
	if !os.is_directory(outputDir) {
		build_log(os.stdout, .Info, fmt.tprintf("Making Directory %s", outputDir))
		os.make_directory_all(outputDir)
	}

	// Odin Compilation
	when ODIN_OS == .Windows {
		binaryName, _ := os.join_filename(VKFIELD_TESTS_NAME, "exe", context.allocator)
	} else when ODIN_OS == .Linux {
		binaryName := VKFIELD_TESTS_NAME
	}
	binaryOutPath, _ := os.join_path({outputDir, binaryName}, context.allocator)
	append(options, ..VKFIELD_ODIN_TEST_OPTIONS)
	append(options, ..odin_defines_to_options(VKFIELD_ODIN_TEST_DEFINES))
	append(options, OdinBuildOption{flag = "out", value = {binaryOutPath}})

	odinCmd := make([dynamic]string)
	append(&odinCmd, ODIN_CMD, ODIN_BUILD_ARG, VKFIELD_TEST_DIR)
	append(&odinCmd, ..odin_options_to_args(options[:]))
	assert(assert(run_cmd(odinCmd[:])) == 0)
	return
}

PFFFT_DIRECTORY :: EXTERN_DIRECTORY + "pffft/"
PFFFT_SOURCE :: PFFFT_DIRECTORY + "pffft.c"

build_pffft :: proc() -> (ok := true) {
	build_log(os.stdout, .Info, "Building PFFFT")
	compilerPath, compilerKind := detect_cpp_compiler() or_return
	tmpDirectory := TMP_DIRECTORY + "pffft/"
	compileParameters: CppCompileParameters = {
		compilerPath      = compilerPath,
		outputType        = .ObjectFiles,
		sourcePaths       = {PFFFT_SOURCE},
		outputPath        = tmpDirectory,
		optimizationLevel = .Debug,
		fastMath          = false,
		debug             = VKFIELD_BUILD_MODE == "debug",
	}
	compileCmd := build_cpp_compile_command(compilerKind, compileParameters) or_return
	assert(assert(run_cmd(compileCmd)) == 0)
	objectPath := assume(
		os.join_path(
			{tmpDirectory, assume(os.join_filename("pffft", get_cpp_object_extension(compilerKind), context.temp_allocator))},
			context.temp_allocator,
		),
	)
	importDirectory :: IMPORT_DIRECTORY + "pffft/"
	libraryPath := assume(
		os.join_path({importDirectory, assume(os.join_filename("pffft", get_static_library_extensions(ODIN_OS), context.allocator))}, context.allocator),
	)
	archiveParameters: CppArchiveParameters = {
		archiverPath = get_cpp_static_archiver(compilerKind),
		objectFiles  = {objectPath},
		outputPath   = libraryPath,
	}
	archiveCmd := build_cpp_archive_command(compilerKind, archiveParameters) or_return
	assert(assert(run_cmd(archiveCmd)) == 0)
	return
}
