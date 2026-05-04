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

oneRectSimulation :: proc() -> (ok := true) {
	settings := vkField.SimulationSettings {
		samplingFrequency    = 100e6,
		speedOfSound         = 1540,
		transmitElementCount = 1,
		receiveElementCount  = 1,
		scatterCount         = 1,
		cumulative           = true,
		dispatchWorkLimit    = 1 << 24,
	}

	simulator: vkField.Simulator
	simulator = is_ok(check(vkField.create_vulkan_simulator())) or_return
	defer vkField.destroy_vulkan_simulator(&simulator.(vkField.vkSimulator))

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

	vkField.plan_simulation(&simulator, &settings, transmitElements, receiveElements, scatters)

	data : []f32
	data, ok = vkField.simulate(simulator, &settings, transmitElements, receiveElements, scatters)
	defer delete(data)
	fmt.println(data)
	return
}

linearArraySimulation :: proc() -> (ok := true) {
	scatterCount :: 16
	elementCount :: 128
	elementWidth: f32 : 2.2e-4
	elementKerf: f32 : 3e-5
	elementPitch :: elementWidth + elementKerf

	simulator: vkField.Simulator
	simulator = is_ok(check(vkField.create_vulkan_simulator())) or_return
	defer vkField.destroy_vulkan_simulator(&simulator.(vkField.vkSimulator))

	settings := vkField.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound      = 1540,
		scatterCount      = scatterCount,
		cumulative        = true,
		dispatchWorkLimit = 1 << 24,
	}

	transmitElements := make_grid_elements(elementCount, 1, elementPitch, elementWidth, 0)
	defer delete(transmitElements)
	receiveElements := make_grid_elements(elementCount, 1, elementPitch, elementWidth, 0)
	defer delete(receiveElements)
	scatters := make_random_scatters(scatterCount)
	defer delete(scatters)

	vkField.plan_simulation(&simulator, &settings, transmitElements, receiveElements, scatters)
	_, ok = vkField.simulate(simulator, &settings, transmitElements, receiveElements, scatters)
	return
}

matrixArraySimulation :: proc() -> (ok := true) {
	scatterCount :: 16
	elementCount :: 128
	elementWidth: f32 : 2.2e-4
	elementKerf: f32 : 3e-5
	elementPitch :: elementWidth + elementKerf

	simulator: vkField.Simulator
	simulator = is_ok(check(vkField.create_vulkan_simulator())) or_return
	defer vkField.destroy_vulkan_simulator(&simulator.(vkField.vkSimulator))

	settings := vkField.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound      = 1540,
		scatterCount      = scatterCount,
		cumulative        = true,
		dispatchWorkLimit = 1 << 24,
	}

	transmitElements := make_grid_elements(elementCount, elementCount, elementPitch * [2]f32{1, 1}, elementWidth * [2]f32{1, 1}, 0)
	defer delete(transmitElements)
	receiveElements := make_grid_elements(elementCount, elementCount, elementPitch * [2]f32{1, 1}, elementWidth * [2]f32{1, 1}, 0)
	defer delete(receiveElements)
	scatters := make_random_scatters(scatterCount)
	defer delete(scatters)

	vkField.plan_simulation(&simulator, &settings, transmitElements, receiveElements, scatters)
	_, ok = vkField.simulate(simulator, &settings, transmitElements, receiveElements, scatters)
	return
}

@(test)
oneRectSimulationTest :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)
	_ = utility.expect(t, oneRectSimulation())
}

@(test)
linearArraySimulationTest :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)
	_ = utility.expect(t, linearArraySimulation())
}

@(test)
matrixArraySimulationTest :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)
	_ = utility.expect(t, matrixArraySimulation())
}

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	//oneRectSimulation()
	linearArraySimulation()
	//matrixArraySimulation()
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

make_grid_elements :: proc(columnCount, rowCount: int, pitch, size: [2]f32, z: f32) -> []vkField.Element {
	elements := make([]vkField.Element, columnCount * rowCount, context.allocator)
	index := 0
	for row in 0 ..< rowCount {
		for column in 0 ..< columnCount {
			x := (f32(column) - f32(columnCount - 1) * 0.5) * pitch[0]
			y := (f32(row) - f32(rowCount - 1) * 0.5) * pitch[1]
			elements[index] = {
				aperture = {rectangle = {position = {x, y, z}, normal = {0, 0, 1}, size = size}},
				apodization = 1,
			}
			index += 1
		}
	}
	return elements
}
