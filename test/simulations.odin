package vkfield_scripts

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:testing"
import vkField "vkField:."
import utility "vkField:utility"

check :: utility.check
is_ok :: utility.is_ok

SIMULATOR_TYPE :: #config(TEST_SIMULATOR_TYPE, "CPU")
CUMULATIVE :: bool(#config(TEST_CUMULATIVE, true))

create_simulator :: proc(settings: vkField.SimulationSettings) -> (simulator: vkField.Simulator, ok: bool) {
	switch SIMULATOR_TYPE {
	case "CPU":
		cpuSimulator, cpuOk := vkField.create_cpu_simulator()
		return cpuSimulator, cpuOk
	case "VULKAN", "VK", "GPU":
		vkSimulator, vkOk := vkField.create_vulkan_simulator(settings)
		return vkSimulator, vkOk == .SUCCESS
	case:
		panic(fmt.tprintf("Unsupported simulator type %q", SIMULATOR_TYPE))
	}
}

destroy_simulator :: proc(simulator: ^vkField.Simulator) {
	switch &sim in simulator^ {
	case vkField.cpuSimulator:
		vkField.destroy_cpu_simulator(&sim)
	case vkField.vkSimulator:
		vkField.destroy_vulkan_simulator(&sim)
	}
}

oneRectSimulation :: proc() -> (ok := true) {

	utility.prof_init("oneRectSimulation")
	utility.prof_thread_init()
	utility.prof_scoped(#procedure)

	settings := vkField.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound = 1540,
		cumulative = auto_cast CUMULATIVE,
		cpuSettings = {threadCount = 1},
		gpuSettings = {dispatchWorkLimit = 1 << 24, enableDriverDebugMessages = true},
	}

	simulator := create_simulator(settings) or_return
	defer destroy_simulator(&simulator)

	transmitElement: vkField.RectangularElement = {
		position    = {0, 0, 0},
		normal      = {0, 0, 1},
		size        = {2.2e-4, 2.2e-4},
		apodization = 1,
	}

	receiveElement: vkField.RectangularElement = {
		position    = {0, 0, 0},
		normal      = {0, 0, 1},
		size        = {2.2e-4, 2.2e-4},
		apodization = 1,
	}

	scatter: vkField.Scatter = {
		position  = {10e-3, 5e-3, 20e-3},
		amplitude = 1,
	}

	elements := make(#soa[]vkField.RectangularElement, 1, context.allocator)
	defer delete(elements)
	elements[0] = transmitElement
	elements[0].apodization = receiveElement.apodization

	transmissionElements := make(#soa[]vkField.TransmissionElement, 1, context.allocator)
	defer delete(transmissionElements)
	transmissionElements[0] = {
		index       = 0,
		apodization = 1,
		delay       = 0,
	}
	receiveChannelElements := make(#soa[]vkField.TransmissionElement, 1, context.allocator)
	defer delete(receiveChannelElements)
	receiveChannelElements[0] = vkField.TransmissionElement {
		index       = 0,
		apodization = 1,
		delay       = 0,
	}

	transmissions := make([]vkField.Transmission, 1, context.allocator)
	defer delete(transmissions)
	transmissions[0] = {
		elements = transmissionElements,
	}
	receiveChannels := make([]vkField.ReceiveChannel, 1, context.allocator)
	defer delete(receiveChannels)
	receiveChannels[0] = {
		elements = receiveChannelElements,
	}
	scatters := slice.from_ptr(&scatter, 1)

	vkField.plan_simulation(&simulator, &settings, transmissions, receiveChannels, elements, scatters)

	data: []f32
	data, ok = vkField.simulate(&simulator, &settings, transmissions, receiveChannels, elements, scatters)
	defer delete(data)
	fmt.println(data)
	nonZeroData: bool
	for datum in data {
		if datum != 0 {
			nonZeroData = true
			break
		}
	}
	return nonZeroData
}

linearArraySimulation :: proc() -> (ok := true) {

	utility.prof_init("linearArraySimulation")
	utility.prof_thread_init()
	utility.prof_scoped(#procedure)

	scatterCount :: 16
	elementCount :: 128
	elementWidth: f32 : 2.2e-4
	elementKerf: f32 : 3e-5
	elementPitch :: elementWidth + elementKerf

	settings := vkField.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound = 1540,
		cumulative = auto_cast CUMULATIVE,
		cpuSettings = {threadCount = 1},
		gpuSettings = {dispatchWorkLimit = 1 << 24, enableDriverDebugMessages = true},
	}

	simulator := create_simulator(settings) or_return
	defer destroy_simulator(&simulator)

	elements := make_grid_elements(elementCount, 1, elementPitch, elementWidth, 0)
	defer delete(elements)
	transmissions := make_full_aperture_transmissions(elementCount)
	defer delete(transmissions[0].elements)
	defer delete(transmissions)
	receiveChannels := make_single_element_receive_channels(elementCount)
	defer for receiveChannel in receiveChannels do delete(receiveChannel.elements)
	defer delete(receiveChannels)
	scatters := make_random_scatters(scatterCount)
	defer delete(scatters)

	vkField.plan_simulation(&simulator, &settings, transmissions, receiveChannels, elements, scatters)
	data: []f32
	data, ok = vkField.simulate(&simulator, &settings, transmissions, receiveChannels, elements, scatters)
	defer delete(data)
	return
}

matrixArraySimulation :: proc() -> (ok := true) {

	utility.prof_init("matrixArraySimulation")
	utility.prof_thread_init()
	utility.prof_scoped(#procedure)

	scatterCount :: 128
	elementCount :: 128
	elementWidth: f32 : 2.2e-4
	elementKerf: f32 : 3e-5
	elementPitch :: elementWidth + elementKerf

	settings := vkField.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound = 1540,
		cumulative = auto_cast CUMULATIVE,
		cpuSettings = {threadCount = 1},
		gpuSettings = {dispatchWorkLimit = 1 << 24, enableDriverDebugMessages = true},
	}

	simulator := create_simulator(settings) or_return
	defer destroy_simulator(&simulator)

	elements := make_grid_elements(elementCount, elementCount, elementPitch * [2]f32{1, 1}, elementWidth * [2]f32{1, 1}, 0)
	defer delete(elements)
	transmissions := make_full_aperture_transmissions(elementCount * elementCount)
	defer delete(transmissions[0].elements)
	defer delete(transmissions)
	receiveChannels := make_single_element_receive_channels(elementCount * elementCount)
	defer for receiveChannel in receiveChannels do delete(receiveChannel.elements)
	defer delete(receiveChannels)
	scatters := make_random_scatters(scatterCount)
	defer delete(scatters)

	vkField.plan_simulation(&simulator, &settings, transmissions, receiveChannels, elements, scatters)
	data: []f32
	data, ok = vkField.simulate(&simulator, &settings, transmissions, receiveChannels, elements, scatters)
	defer delete(data)
	return
}

// @(test)
oneRectSimulationTest :: proc(t: ^testing.T) {
	_ = utility.expect(t, oneRectSimulation())
}

@(test)
linearArraySimulationTest :: proc(t: ^testing.T) {
	_ = utility.expect(t, linearArraySimulation())
}

// @(test)
matrixArraySimulationTest :: proc(t: ^testing.T) {
	_ = utility.expect(t, matrixArraySimulation())
}

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	oneRectSimulation()
	linearArraySimulation()
	matrixArraySimulation()
}

make_random_scatters :: proc(count: int) -> []vkField.Scatter {
	scatters := make([]vkField.Scatter, count, context.allocator)
	for i in 0 ..< count {
		x := rand.float32_range(-8e-3, 8e-3)
		y := rand.float32_range(-8e-3, 8e-3)
		z := rand.float32_range(0, 100e-3)
		scatters[i] = {
			position  = {x, y, z},
			amplitude = 1,
		}
	}
	return scatters
}

make_grid_elements :: proc(columnCount, rowCount: int, pitch, size: [2]f32, z: f32) -> #soa[]vkField.RectangularElement {
	elements := make(#soa[]vkField.RectangularElement, columnCount * rowCount, context.allocator)
	index := 0
	for row in 0 ..< rowCount {
		for column in 0 ..< columnCount {
			x := (f32(column) - f32(columnCount - 1) * 0.5) * pitch[0]
			y := (f32(row) - f32(rowCount - 1) * 0.5) * pitch[1]
			elements[index] = {
				position    = {x, y, z},
				normal      = {0, 0, 1},
				size        = size,
				apodization = 1,
			}
			index += 1
		}
	}
	return elements
}

make_full_aperture_transmissions :: proc(elementCount: int) -> []vkField.Transmission {
	transmissionElements := make(#soa[]vkField.TransmissionElement, elementCount, context.allocator)
	for i in 0 ..< elementCount {
		transmissionElements[i] = {
			index       = i32(i),
			apodization = 1,
			delay       = 0,
		}
	}
	transmissions := make([]vkField.Transmission, 1, context.allocator)
	transmissions[0] = {
		elements = transmissionElements,
	}
	return transmissions
}

make_single_element_receive_channels :: proc(elementCount: int) -> []vkField.ReceiveChannel {
	receiveChannels := make([]vkField.ReceiveChannel, elementCount, context.allocator)
	for i in 0 ..< elementCount {
		elements := make(#soa[]vkField.TransmissionElement, 1, context.allocator)
		elements[0] = vkField.TransmissionElement {
			index       = i32(i),
			apodization = 1,
			delay       = 0,
		}
		receiveChannels[i] = {
			elements = elements,
		}
	}
	return receiveChannels
}
