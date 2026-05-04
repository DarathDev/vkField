package vkField_build

when ODIN_OS == .Windows {
	SLANG_BINARIES: []string = {"slang.dll", "slang-compiler.dll", "slang-rt.dll", "slang-glsl-module.dll", "slang-glslang.dll", "slang-llvm.dll"}
}

SLANG_LIBRARIES: []string = {"slang", "slang-compiler", "slang-rt", "gfx"}

SHADER_FOLDER :: "core/shaders/"

VKFIELD_PULSE_ECHO_SHADERS: []SlangShaderFile = {
	{
		path       = SHADER_FOLDER + "packSpatialImpulseResponse.slang",
		outputName = "packSpatialImpulseResponse",
		type       = .Compute,
	},
	{
		path       = SHADER_FOLDER + "pulseEcho.slang",
		outputName = "pulseEcho",
		type       = .Compute,
	},
}
VKFIELD_DEBUG_PRECOMPILED_SHADERS: []SlangShaderFile = {}
