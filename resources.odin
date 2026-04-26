package vkField_build

when ODIN_OS == .Windows {
	SLANG_BINARIES: []string = {"slang.dll", "slang-compiler.dll", "slang-rt.dll", "slang-glsl-module.dll", "slang-glslang.dll", "slang-llvm.dll"}
}

SLANG_LIBRARIES: []string = {"slang", "slang-compiler", "slang-rt", "gfx"}

SHADER_FOLDER :: "core/shaders/"
SAMPLE_GROUP_X :: 128
RECEIVE_GROUP_Y :: 1
SCATTER_REDUCTION_Z :: 1

VKFIELD_PULSE_ECHO_SHADERS: []SlangShaderFile = {
	{
		path = SHADER_FOLDER + "pack_scatter_rects.slang",
		outputName = "pack_scatter_rects",
		type = .Compute
	},
	{
		path = SHADER_FOLDER + "pulse_echo.slang",
		outputName = "pulse_echo",
		type = .Compute
	},
	{
		path       = SHADER_FOLDER + "pulse_echo.slang",
		outputName = "pulse_echo_cumulative",
		type       = .Compute,
		defines    = {{"PULSE_ECHO_CUMULATIVE", "1"}},
	},
}
VKFIELD_DEBUG_PRECOMPILED_SHADERS: []SlangShaderFile = {}
