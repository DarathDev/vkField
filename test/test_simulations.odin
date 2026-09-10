package vkfield_scripts

import "core:log"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:testing"
import vkField "vkField:."
import utility "vkField:utility"

check :: utility.check
is_ok :: utility.is_ok

CUMULATIVE :: bool(#config(TEST_CUMULATIVE, true))

OUTPUT_ABSOLUTE_TOLERANCE :: 1e-3
OUTPUT_RELATIVE_TOLERANCE :: 5e-2

compare_simulators :: proc(
	settings: vkField.SimulationSettings,
	transmissions: []vkField.Transmission,
	receiveChannels: []vkField.ReceiveChannel,
	elements: #soa[]vkField.RectangularElement,
	scatters: []vkField.Scatter,
) -> (
	ok := true,
) {
	cpuSettings := settings
	gpuSettings := settings

	cpuSimulator, cpuOk := vkField.create_cpu_simulator()
	if !cpuOk do return false
	defer vkField.destroy_cpu_simulator(&cpuSimulator)

	gpuSimulator, gpuResult := vkField.create_vulkan_simulator(gpuSettings)
	if gpuResult != .SUCCESS do return false

	cpuSim: vkField.Simulator = cpuSimulator
	gpuSim: vkField.Simulator = gpuSimulator
	defer vkField.destroy_vulkan_simulator(&gpuSim.(vkField.vkSimulator))

	if !vkField.plan_simulation(&cpuSim, &cpuSettings, transmissions, receiveChannels, elements, scatters) do return false
	if !vkField.plan_simulation(&gpuSim, &gpuSettings, transmissions, receiveChannels, elements, scatters) do return false

	cpuData, cpuSimulationOk := vkField.simulate(&cpuSim, &cpuSettings, transmissions, receiveChannels, elements, scatters)
	if !cpuSimulationOk do return false
	defer delete(cpuData)
	gpuData, gpuSimulationOk := vkField.simulate(&gpuSim, &gpuSettings, transmissions, receiveChannels, elements, scatters)
	if !gpuSimulationOk do return false
	defer delete(gpuData)

	if len(cpuData) != len(gpuData) {
		log.errorf("CPU/GPU output length mismatch: %d != %d", len(cpuData), len(gpuData))
		return false
	}

	anyMismatch: uint
	for i in 0 ..< len(cpuData) {
		cpuValue := cpuData[i]
		gpuValue := gpuData[i]
		difference := math.abs(cpuValue - gpuValue)
		tolerance := OUTPUT_ABSOLUTE_TOLERANCE + OUTPUT_RELATIVE_TOLERANCE * max(math.abs(cpuValue), math.abs(gpuValue))
		if difference > tolerance {
			log.errorf("CPU/GPU output mismatch at %d: %e != %e (difference %e, tolerance %e)", i, cpuValue, gpuValue, difference, tolerance)
			anyMismatch += 1
			if anyMismatch > 10 {
				break
			}
		}
	}

	return anyMismatch == 0
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

	return compare_simulators(settings, transmissions, receiveChannels, elements, scatters)
}

linearArraySimulation :: proc() -> (ok := true) {

	utility.prof_init("linearArraySimulation")
	utility.prof_thread_init()
	utility.prof_scoped(#procedure)

	scatterCount :: 16
	rowCount :: 1
	columnCount :: 128
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

	elements := make_transmit_and_receive_grid_elements(columnCount, rowCount, elementPitch, elementWidth, 0)
	defer delete(elements)
	transmissions := make_full_aperture_transmissions(columnCount * rowCount)
	defer delete(transmissions[0].elements)
	defer delete(transmissions)
	receiveChannels := make_column_receive_channels(columnCount, rowCount, len(transmissions[0].elements))
	defer for receiveChannel in receiveChannels do delete(receiveChannel.elements)
	defer delete(receiveChannels)
	scatters := make_random_scatters(scatterCount, {-8e-3, 8e-3}, {-8e-3, 8e-3}, {10e-3, 100e-3})
	defer delete(scatters)

	return compare_simulators(settings, transmissions, receiveChannels, elements, scatters)
}

matrixArraySimulation :: proc() -> (ok := true) {

	utility.prof_init("matrixArraySimulation")
	utility.prof_thread_init()
	utility.prof_scoped(#procedure)

	scatterCount :: 1024
	rowCount :: 128
	columnCount :: 128
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

	elements := make_transmit_and_receive_grid_elements(columnCount, rowCount, elementPitch * [2]f32{1, 1}, elementWidth * [2]f32{1, 1}, 0)
	defer delete(elements)
	transmissions := make_full_aperture_transmissions(columnCount * rowCount)
	defer delete(transmissions[0].elements)
	defer delete(transmissions)
	receiveChannels := make_single_element_receive_channels(columnCount * rowCount, len(transmissions[0].elements))
	defer for receiveChannel in receiveChannels do delete(receiveChannel.elements)
	defer delete(receiveChannels)
	scatters := make_random_scatters(scatterCount, {-8e-3, 8e-3}, {-8e-3, 8e-3}, {0, 100e-3})
	defer delete(scatters)

	return compare_simulators(settings, transmissions, receiveChannels, elements, scatters)
}

@(test)
oneRectSimulationTest :: proc(t: ^testing.T) {
	_ = utility.expect(t, oneRectSimulation())
}

@(test)
linearArraySimulationTest :: proc(t: ^testing.T) {
	_ = utility.expect(t, linearArraySimulation())
}

@(test)
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

make_random_scatters :: proc(count: int, xRange, yRange, zRange: [2]f32) -> []vkField.Scatter {
	scatters := make([]vkField.Scatter, count, context.allocator)
	for i in 0 ..< count {
		x := rand.float32_range(xRange[0], xRange[1])
		y := rand.float32_range(yRange[0], yRange[1])
		z := rand.float32_range(zRange[0], zRange[1])
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

make_transmit_and_receive_grid_elements :: proc(columnCount, rowCount: int, pitch, size: [2]f32, z: f32) -> #soa[]vkField.RectangularElement {
	transmitElements := make_grid_elements(columnCount, rowCount, pitch, size, z)
	receiveElements := make_grid_elements(columnCount, rowCount, pitch, size, z)
	elements := make(#soa[]vkField.RectangularElement, len(transmitElements) + len(receiveElements), context.allocator)
	for i in 0 ..< len(transmitElements) {
		elements[i] = transmitElements[i]
	}
	for i in 0 ..< len(receiveElements) {
		elements[len(transmitElements) + i] = receiveElements[i]
	}
	defer delete(transmitElements)
	defer delete(receiveElements)
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

make_single_element_receive_channels :: proc(elementCount, elementIndexOffset: int) -> []vkField.ReceiveChannel {
	receiveChannels := make([]vkField.ReceiveChannel, elementCount, context.allocator)
	for i in 0 ..< elementCount {
		elements := make(#soa[]vkField.TransmissionElement, 1, context.allocator)
		elements[0] = vkField.TransmissionElement {
			index       = i32(elementIndexOffset + i),
			apodization = 1,
			delay       = 0,
		}
		receiveChannels[i] = {
			elements = elements,
		}
	}
	return receiveChannels
}

make_column_receive_channels :: proc(columnCount, rowCount, elementIndexOffset: int) -> []vkField.ReceiveChannel {
	receiveChannels := make([]vkField.ReceiveChannel, columnCount, context.allocator)
	for column in 0 ..< columnCount {
		elements := make(#soa[]vkField.TransmissionElement, rowCount, context.allocator)
		for row in 0 ..< rowCount {
			elementIndex := elementIndexOffset + column * rowCount + row
			elements[row] = vkField.TransmissionElement {
				index       = i32(elementIndex),
				apodization = 1,
				delay       = 0,
			}
		}
		receiveChannels[column] = {
			elements = elements,
		}
	}
	return receiveChannels
}
