package vkField_build

when ODIN_OS == .Windows {
	SLANG_BINARIES: []string = {"slang.dll", "slang-compiler.dll", "slang-rt.dll", "slang-glsl-module.dll", "slang-glslang.dll", "slang-llvm.dll"}
}

SLANG_LIBRARIES: []string = {"slang", "slang-compiler", "slang-rt", "gfx"}

SHADER_FOLDER :: "src/shaders/"

VKFIELD_PULSE_ECHO_SHADERS: []SlangShaderFile = {
	{path = SHADER_FOLDER + "calculateAperture.slang", outputName = "calculateAperture", type = .Compute},
	{path = SHADER_FOLDER + "measureAperture.slang", outputName = "measureAperture", type = .Compute},
	{path = SHADER_FOLDER + "coalesceAperture.slang", outputName = "coalesceAperture", type = .Compute},
	{path = SHADER_FOLDER + "pulseEchoConvolution.slang", outputName = "pulseEchoConvolution", type = .Compute},
	{path = SHADER_FOLDER + "temporalResponse.slang", outputName = "temporalResponse", type = .Compute},
}
VKFIELD_DEBUG_PRECOMPILED_SHADERS: []SlangShaderFile = {}
