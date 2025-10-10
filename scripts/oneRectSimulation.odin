package vkfield_scripts

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import vkField "vkField:."

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)
	}

	context.logger = log.create_console_logger()

	settings := vkField.SimulationSettings {
		samplingFrequency    = 100e6,
		speedOfSound         = 1540,
		transmitElementCount = 1,
		receiveElementCount  = 1,
		scatterCount         = 1,
		headless             = true,
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

	vkField.planSimulation_odin(&settings, transmitElements, receiveElements, scatters)

	data := vkField.simulate_odin(&settings, transmitElements, receiveElements, scatters)

	fmt.println(data)

	when ODIN_DEBUG {
		for _, leak in track.allocation_map {
			fmt.printfln("%v leaked %m", leak.location, leak.size)
		}
	}
}
