package vkField_build

ShaderType :: enum {
	Graphics,
	Compute,
}

ShaderFiles :: struct {
	path: string,
	type: ShaderType,
}

SHADER_FOLDER :: "shaders/"
PULSE_ECHO_SHADERS: []ShaderFiles = {
	{path = SHADER_FOLDER + "pulse_echo.comp.hlsl", type = .Compute},
	{path = SHADER_FOLDER + "pulse_echo_cum.comp.hlsl", type = .Compute},
}
