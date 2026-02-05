package vkField_build

import util "core/utility"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

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

run_cmd :: proc(cmd: []string, working_dir: string = "") -> (exit_code: int, ok := true) {
	processDesc: os.Process_Desc = {
		command     = cmd,
		working_dir = working_dir,
		stdin       = os.stdin,
		stdout      = os.stdout,
		stderr      = os.stderr,
	}
	log.debugf("Executing: %s", strings.join(cmd, " "))
	process := is_ok(check(os.process_start(processDesc))) or_return
	state := is_ok(check(os.process_wait(process))) or_return
	exit_code = state.exit_code
	return
}

when ODIN_OS == .Windows {
	CheckCommand: []string = {"powershell", "-Command", "Get-Command", "cmd", "-ErrorAction", "SilentlyContinue", "|", "Out-Null"}
	CheckCommandPlaceholderIndex: int = 3
} else when ODIN_OS == .Linux {
	CheckCommand: []string = {"where", "cmd"}
	CheckCommandPlaceholderIndex: int = 1
}

check_cmd :: proc(cmd: string) -> (ok: bool) {
	checkCmd := slice.clone(CheckCommand)
	checkCmd[CheckCommandPlaceholderIndex] = cmd
	exit_code := confirm(run_cmd(checkCmd)) or_return
	return exit_code == 0
}

when ODIN_OS == .Windows {
	UnZipCommand: []string = {"powershell", "-Command", "Expand-Archive", "-Path", "filepath", "-DestinationPath", "destinationpath", "-Force"}
	UnZipPlaceholderIndices: [2]int = {4, 6}
} else when ODIN_OS == .Linux {
	UnZipCommand: []string = {"unzip", "-o", "filepath", "-d", "destinationpath"}
	UnZipPlaceholderIndices: [2]int = {2, 4}
}

unzip_to_folder :: proc(zip_path, dest_folder: string) -> (ok := true) {
	unzipCmd := slice.clone(UnZipCommand)
	unzipCmd[UnZipPlaceholderIndices[0]] = zip_path
	unzipCmd[UnZipPlaceholderIndices[1]] = dest_folder
	confirm(run_cmd(unzipCmd)) or_return
	return
}

/* ----- GH ----- */

GH_CMD := "gh"

download_release_from_github :: proc(repo, filename: string) -> (ok := true) {
	gh_args: []CliOptions = {
		{flag = "repo", value = repo},
		{flag = "output", value = filename},
		{flag = "pattern", value = "slang-*-windows-x86_64.zip"},
		{flag = "clobber"},
	}

	gh_cmd := make([dynamic]string)
	append(&gh_cmd, ..[]string{GH_CMD, "release", "download"})
	append(&gh_cmd, ..cli_options_to_args(gh_args[:]))
	exit_code := confirm(run_cmd(gh_cmd[:])) or_return
	return exit_code == 0
}

rebuild_needed :: proc(artifact_path: string, source_files: []string) -> (ok: bool) {
	if !os.is_file(artifact_path) {
		return true
	}

	artifact_info := is_ok(os.stat(artifact_path, context.allocator)) or_return
	for src in source_files {
		src_info := is_ok(os.stat(src, context.allocator)) or_return
		if src_info.modification_time._nsec > artifact_info.modification_time._nsec {
			log.debugf("Source %s is newer than artifact, rebuild required", src)
			return true
		}
	}

	log.debugf("Artifact is up to date")
	return false
}

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

OdinDefine :: struct {
	name:  string,
	value: string,
}

odin_defines_to_options :: proc(defines: []OdinDefine) -> (options: []OdinBuildOption) {
	options = make([]OdinBuildOption, len(defines))
	for define, index in defines {
		value := fmt.aprintf("%v=%v", define.name, define.value)
		options[index] = {
			flag  = "define",
			value = slice.from_ptr(new_clone(value), 1),
		}
	}
	return
}

odin_collections_to_options :: proc(collections: []OdinCollection) -> (options: []OdinBuildOption) {
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
			args[index] = fmt.aprintf("-%s", option.flag)
		} else {
			args[index] = fmt.aprintf("-%s:%s", option.flag, strings.join(option.value, ","))
		}
	}
	return
}

/* ----- CLI ----- */

CliDefine :: struct {
	define: string,
	value:  string,
}

CliOptions :: struct {
	flag:  CliFlag,
	value: string,
}

CliFlag :: union {
	rune,
	string,
}

cli_options_to_args :: proc(options: []CliOptions) -> (args: []string) {
	dArgs := make([dynamic]string)
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

cli_defines_to_args :: proc(defines: []CliDefine) -> (args: []string) {
	args = make([]string, len(defines))
	for define, index in defines {
		if len(define.value) == 0 {
			args[index] = fmt.tprintf("-D%s", define.define)
		} else {
			args[index] = fmt.tprintf("-D%s=%s", define.define, define.value)
		}
	}
	return
}

/* ----- C++ ----- */

CPP_COMPILER_KIND: CompilerKind = .GCC

CompilerKind :: enum {
	MSVC,
	Clang,
	GCC,
}

CppDefine :: distinct CliDefine
CppOptions :: struct {
	flag:  string,
	value: string,
}

CppCompileParameters :: struct {
	compiler_path:         string,
	source_path:           string,
	output_path:           string,
	build_type:            string,
	language_standard:     string,
	include_paths:         []string,
	defines:               []CppDefine,
	optional_debug_db_dir: string,
}

CppArchiveParameters :: struct {
	archiver_path: string,
	output_path:   string,
	object_files:  []string,
	ar_mode:       string,
}

detect_cpp_compiler :: proc() -> (compiler_path: string, kind: CompilerKind, ok := true) {
	compile := ""
	compiler_env := os.get_env("CXX", context.allocator)
	if len(compiler_env) == 0 {
		compiler_env = os.get_env("CC", context.allocator)
	}
	if len(compiler_env) > 0 {
		compile = compiler_env
	}

	if len(compile) == 0 {
		when ODIN_OS == .Windows {
			if check_cmd("cl.exe") {
				compile = "cl.exe"
			} else if check_cmd("clang-cl.exe") {
				compile = "clang-cl.exe"
			} else if check_cmd("clang++") {
				compile = "clang++"
			} else if check_cmd("g++") {
				compile = "g++"
			}
		} else {
			if check_cmd("g++") {
				compile = "g++"
			} else if check_cmd("clang++") {
				compile = "clang++"
			}
		}
	}

	if len(compile) == 0 {
		log.errorf("No C++ compiler found. Set CXX or CC to a valid compiler executable.")
		ok = false
		return
	}

	compiler_lower := strings.to_lower(compile)
	switch {
	case strings.contains(compiler_lower, "clang-cl"):
		kind = .MSVC
	case strings.contains(compiler_lower, "cl.exe") || compiler_lower == "cl":
		kind = .MSVC
	case strings.contains(compiler_lower, "clang"):
		kind = .Clang
	case strings.contains(compiler_lower, "g++") || strings.contains(compiler_lower, "gcc"):
		kind = .GCC
	case ODIN_OS == .Windows:
		kind = .MSVC
	case ODIN_OS == .Linux:
		kind = .GCC
	}
	CPP_COMPILER_KIND = kind
	compiler_path = compile
	return
}

get_cpp_object_extension :: proc(kind: CompilerKind) -> string {
	switch kind {
	case .MSVC:
		return "obj"
	case .Clang:
		fallthrough
	case .GCC:
		return "o"
	}
	return "o"
}

get_cpp_static_linker :: proc(kind: CompilerKind) -> string {
	switch kind {
	case .MSVC:
		return "lib.exe"
	case .Clang:
		fallthrough
	case .GCC:
		return "ar"
	}
	return "ar"
}

build_cpp_compile_command :: proc(compilerKind: CompilerKind, parameters: CppCompileParameters) -> (args: []string) {
	d_args := make([dynamic]string)
	append(&d_args, parameters.compiler_path)

	cpp_options := make([dynamic]CppOptions)
	append(&cpp_options, CppOptions{flag = "c"})

	if len(parameters.language_standard) > 0 {
		if compilerKind == .MSVC {
			append(&cpp_options, CppOptions{flag = fmt.tprintf("std:%s", parameters.language_standard)})
		} else {
			append(&cpp_options, CppOptions{flag = fmt.tprintf("std=%s", parameters.language_standard)})
		}
	}

	if compilerKind == .MSVC {
		append(&cpp_options, CppOptions{flag = "W3"})
	} else {
		append(&cpp_options, CppOptions{flag = "Wall"})
	}

	is_debug_build := strings.equal_fold(parameters.build_type, "debug")
	if is_debug_build {
		if compilerKind == .MSVC {
			append(&cpp_options, CppOptions{flag = "Zi"})
			append(&cpp_options, CppOptions{flag = "Od"})
		} else {
			append(&cpp_options, CppOptions{flag = "g"})
			append(&cpp_options, CppOptions{flag = "O0"})
		}
	} else {
		append(&cpp_options, CppOptions{flag = "O2"})
		if compilerKind == .MSVC {
			append(&cpp_options, CppOptions{flag = "Zi"})
		} else {
			append(&cpp_options, CppOptions{flag = "g"})
		}
	}

	for include_path in parameters.include_paths {
		if len(include_path) > 0 {
			append(&cpp_options, CppOptions{flag = "I", value = include_path})
		}
	}

	if compilerKind == .MSVC && len(parameters.optional_debug_db_dir) > 0 {
		append(&cpp_options, CppOptions{flag = "Fd", value = parameters.optional_debug_db_dir})
	}

	if compilerKind == .MSVC {
		append(&cpp_options, CppOptions{flag = "Fo", value = parameters.output_path})
	} else {
		append(&cpp_options, CppOptions{flag = "o", value = parameters.output_path})
	}

	append(&d_args, ..cpp_options_to_args(compilerKind, cpp_options[:]))
	append(&d_args, ..cpp_defines_to_args(compilerKind, parameters.defines))
	append(&d_args, parameters.source_path)

	args = d_args[:]
	return
}

build_cpp_archive_command :: proc(compilerKind: CompilerKind, parameters: CppArchiveParameters) -> (args: []string) {
	d_args := make([dynamic]string)
	append(&d_args, parameters.archiver_path)

	if compilerKind == .MSVC {
		append(&d_args, fmt.tprintf("/OUT:%s", parameters.output_path))
	} else {
		mode := parameters.ar_mode
		if len(mode) == 0 do mode = "rcs"
		append(&d_args, mode)
		append(&d_args, parameters.output_path)
	}

	for object_file in parameters.object_files {
		if len(object_file) > 0 {
			append(&d_args, object_file)
		}
	}

	args = d_args[:]
	return
}

cpp_defines_to_args :: proc(compilerKind: CompilerKind, defines: []CppDefine) -> (args: []string) {
	args = make([]string, len(defines))
	prefix := "-D"
	if compilerKind == .MSVC {
		prefix = "/D"
	}
	for define, index in defines {
		if len(define.value) == 0 {
			args[index] = fmt.tprintf("%s%s", prefix, define.define)
		} else {
			args[index] = fmt.tprintf("%s%s=%s", prefix, define.define, define.value)
		}
	}
	return
}

cpp_options_to_args :: proc(compilerKind: CompilerKind, options: []CppOptions) -> (args: []string) {
	dArgs := make([dynamic]string)
	prefix := "-"
	if compilerKind == .MSVC {
		prefix = "/"
	}
	for option in options {
		flag := option.flag
		if strings.has_prefix(flag, "-") || strings.has_prefix(flag, "/") {
			flag = flag[1:]
		}
		arg := fmt.tprintf("%s%s", prefix, flag)
		if len(option.value) == 0 {
			append(&dArgs, arg)
		} else if compilerKind == .MSVC {
			append(&dArgs, fmt.tprintf("%s%s", arg, option.value))
		} else {
			append(&dArgs, arg, option.value)
		}
	}
	args = dArgs[:]
	return
}

/* ----- SLANGC ----- */
SLANG_CMD := "slangc"

SLANG_INPUT_EXT := "slang"
SLANG_TARGET := "spirv"
SLANG_PROFILE := "spirv_1_4"
SLANG_TARGET_EXT := "spv"
SLANG_SOURCE_SHADER_EXT := "slang"
SLANG_COMPILED_SHADER_EXT := "spv"

SlangShaderType :: enum {
	Graphics,
	Compute,
}

SlangShaderFile :: struct {
	path:         string,
	type:         SlangShaderType,
	capabilities: []string,
}

compile_shader_slangc :: proc(shader: SlangShaderFile) -> (ok := true) {
	dir, filename := os.split_path(shader.path)
	moduleName, ext := os.split_filename(filename)
	assert(strings.compare(ext, SLANG_INPUT_EXT) == 0)
	outputPath := assume(os.join_path({dir, assume(os.join_filename(moduleName, SLANG_TARGET_EXT, context.allocator))}, context.allocator))

	slangCmd := make([dynamic]string)
	append(&slangCmd, SLANG_CMD)
	append(&slangCmd, shader.path)
	append(&slangCmd, "-target", SLANG_TARGET)
	append(&slangCmd, "-o", outputPath)
	append(&slangCmd, "-profile", SLANG_PROFILE)
	for capability in shader.capabilities {
		append(&slangCmd, "-capability", capability)
	}

	confirm(run_cmd(slangCmd[:])) or_return
	return
}

/* ----- GLSLANG ----- */
GLSLANG_CMD := "glslang"

SHADER_COMPILER_CMD := "glslang"
GLSLANG_SOURCE_SHADER_EXT := "hlsl"
GLSLANG_COMPILED_SHADER_EXT := "spv"

GlslangShaderType :: enum {
	Graphics,
	Compute,
}

GlslangShaderFile :: struct {
	path:       string,
	type:       GlslangShaderType,
	entryPoint: string,
}

compile_shader_glslang :: proc(shader: GlslangShaderFile, options: []CliOptions = {}) -> (ok := true) {
	dir, filename := os.split_path(shader.path)
	moduleName, _ := os.split_filename(filename)
	outputFilename := assume(os.join_filename(moduleName, GLSLANG_COMPILED_SHADER_EXT, context.allocator))
	outputPath := assume(os.join_path({dir, outputFilename}, context.allocator))

	glslangCmd := make([dynamic]string)
	append(&glslangCmd, GLSLANG_CMD)
	append(&glslangCmd, shader.path)
	append(&glslangCmd, "-gVS")
	append(&glslangCmd, ..cli_options_to_args({{flag = 'o', value = outputPath}}))
	append(&glslangCmd, ..cli_options_to_args(options))

	run_cmd(glslangCmd[:]) or_return
	return
}
