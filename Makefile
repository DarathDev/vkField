bin/release/vkField.lib: core/simulation.odin core/vulkan.odin shaders
	odin build ./core -build-mode:lib -out:bin/release/vkField.lib -collection:vkField=core

bin/debug/vkField.lib: core/simulation.odin core/vulkan.odin shaders
	odin build ./core -build-mode:lib -out:bin/debug/vkField.lib -collection:vkField=core -debug

bin/debug/oneRectSimulation.odin: scripts/oneRectSimulation.odin core/simulation.odin core/vulkan.odin shaders
	odin build ./scripts -out:bin/debug/oneRectSimulation.exe -debug -collection:vkField=core

shaders: shaders/pulse_echo.comp.spv shaders/pulse_echo_cum.comp.spv

shaders/pulse_echo.comp.spv: shaders/pulse_echo.comp.hlsl
	glslang -V shaders/pulse_echo.comp.hlsl -o shaders/pulse_echo.comp.spv -e main -gVS --target-env vulkan1.2 --spirv-val

shaders/pulse_echo_cum.comp.spv: shaders/pulse_echo_cum.comp.hlsl
	glslang -V shaders/pulse_echo_cum.comp.hlsl -o shaders/pulse_echo_cum.comp.spv -e main -gVS --target-env vulkan1.2 --spirv-val

clean:
	rm -f shaders/pulse_echo.comp.spv
	rm -f shaders/pulse_echo_cum.comp.spv
	rm -f bin/release/vkField.dll
	rm -f bin/release/vkField.exp
	rm -f bin/release/vkField.lib
	rm -f bin/debug/vkField.dll
	rm -f bin/debug/vkField.exp
	rm -f bin/debug/vkField.lib
	rm -f bin/debug/vkField.pdb
