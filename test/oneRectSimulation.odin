package vkfield_scripts

import "core:fmt"
import "core:log"
import "core:slice"
import "core:testing"
import vkField "vkField:."
import utility "vkField:utility"

@(test)
oneRectSimulation :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	simulator, _ := utility.expect(t, vkField.create_vulkan_simulator())
	defer vkField.destroy_vulkan_simulator(&simulator)

	settings := vkField.SimulationSettings {
		samplingFrequency    = 100e6,
		speedOfSound         = 1540,
		transmitElementCount = 1,
		receiveElementCount  = 1,
		scatterCount         = 1,
		cumulative           = true,
	}

	transmitElement: vkField.Element = {
		aperture = {rectangle = {position = {0, 0, 0}, normal = {0, 0, 1}, size = {2.2e-4, 2.2e-4}}},
		apodization = 1,
	}

	receiveElement: vkField.Element = {
		aperture = {rectangle = {position = {0, 0, 0}, normal = {0, 0, 1}, size = {2.2e-4, 2.2e-4}}},
		apodization = 1,
	}

	scatter: vkField.Scatter = {
		position  = {10e-3, 5e-3, 20e-3},
		amplitude = 1,
	}

	transmitElements := slice.from_ptr(&transmitElement, 1)
	receiveElements := slice.from_ptr(&receiveElement, 1)
	scatters := slice.from_ptr(&scatter, 1)

	vkField.plan_simulation(&settings, transmitElements, receiveElements, scatters)

	data, _ := utility.expect(t, vkField.simulate(simulator, &settings, transmitElements, receiveElements, scatters))
	defer delete(data)
	fmt.println(data)
}
