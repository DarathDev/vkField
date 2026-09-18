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
RUN_SIMULATION :: bool(#config(TEST_RUN_SIMULATION, true))
RUN_ONE_RECT :: bool(#config(TEST_RUN_ONE_RECT, true))
RUN_LINEAR :: bool(#config(TEST_RUN_LINEAR, true))
RUN_MATRIX :: bool(#config(TEST_RUN_MATRIX, true))
MIN_CORRELATION :: 0.95
MAX_RMS_ERROR_PERCENT :: 1
MAX_RELATIVE_DIFFERENCE_PERCENT :: 5

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	if RUN_ONE_RECT do oneRectSimulation()
	if RUN_LINEAR do linearArraySimulation()
	if RUN_MATRIX do matrixArraySimulation()
}

@(test)
oneRectSimulationTest :: proc(t: ^testing.T) {
	if !RUN_ONE_RECT do return
	_ = utility.expect(t, oneRectSimulation())
}

@(test)
linearArraySimulationTest :: proc(t: ^testing.T) {
	if !RUN_LINEAR do return
	_ = utility.expect(t, linearArraySimulation())
}

@(test)
matrixArraySimulationTest :: proc(t: ^testing.T) {
	if !RUN_MATRIX do return
	_ = utility.expect(t, matrixArraySimulation())
}

@(test)
temporalResponseTest :: proc(t: ^testing.T) {
	input := []f32{1, 2, 3, 0, 0, 0, 0, 0}
	impulses := []vkField.TransducerImpulse{{1, 2}, {1, -1}}
	excitations := []vkField.Excitation{{0.5, 1}}
	transmissions := []vkField.Transmission{{impulse = 1, excitation = 1}}
	receiveChannels := []vkField.ReceiveChannel{{impulse = 2}}

	vkField.apply_temporal_responses(input, i32(len(input)), 1, transmissions, receiveChannels, impulses, excitations)
	expected := []f32{0.5, 2.5, 4.5, 2.5, -4.0, -6.0, 0.0, 0.0}
	passed := true
	for actual, index in input {
		expectedValue := expected[index]
		if math.abs(actual - expectedValue) > f32(1e-6) {
			passed = false
		}
	}
	_ = utility.expect(t, passed)
}

compare_simulators :: proc(
	settings: vkField.SimulationSettings,
	transmissions: []vkField.Transmission,
	receiveChannels: []vkField.ReceiveChannel,
	elements: #soa[]vkField.RectangularElement,
	scatters: []vkField.Scatter,
	impulses: []vkField.TransducerImpulse,
	excitations: []vkField.Excitation,
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

	if !vkField.plan_simulation(&cpuSim, &cpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations) do return false
	if !vkField.plan_simulation(&gpuSim, &gpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations) do return false
	if !RUN_SIMULATION do return true

	cpuData, cpuSimulationOk := vkField.simulate(&cpuSim, &cpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
	if !cpuSimulationOk do return false
	defer delete(cpuData)
	gpuData, gpuSimulationOk := vkField.simulate(&gpuSim, &gpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
	if !gpuSimulationOk do return false
	defer delete(gpuData)

	if len(cpuData) != len(gpuData) {
		log.errorf("CPU/GPU output length mismatch: %d != %d", len(cpuData), len(gpuData))
		return false
	}

	maxDifference: f32
	sumSquaredDifference: f64
	sumSquaredCpu: f64
	sumSquaredGpu: f64
	dotProduct: f64
	cpuPeak: f32
	gpuPeak: f32

	for i in 0 ..< len(cpuData) {
		cpuValue := cpuData[i]
		gpuValue := gpuData[i]
		cpuAbs := math.abs(cpuValue)
		gpuAbs := math.abs(gpuValue)
		if cpuAbs > cpuPeak do cpuPeak = cpuAbs
		if gpuAbs > gpuPeak do gpuPeak = gpuAbs

		difference := cpuValue - gpuValue
		sumSquaredDifference += f64(difference) * f64(difference)
		sumSquaredCpu += f64(cpuValue) * f64(cpuValue)
		sumSquaredGpu += f64(gpuValue) * f64(gpuValue)
		dotProduct += f64(cpuValue) * f64(gpuValue)

		absoluteDifference := math.abs(difference)
		if absoluteDifference > maxDifference {
			maxDifference = absoluteDifference
		}
	}

	normCpu := math.sqrt(sumSquaredCpu)
	normGpu := math.sqrt(sumSquaredGpu)
	normDiff := math.sqrt(sumSquaredDifference)

	correlation := (normCpu > 0 && normGpu > 0) ? f32(dotProduct / (normCpu * normGpu)) : 0.0
	energyRatio := sumSquaredCpu > 0 ? f32(sumSquaredDifference / sumSquaredCpu) : 0.0
	peakRatio := cpuPeak > 0 ? gpuPeak / cpuPeak : (gpuPeak == 0 ? 1.0 : 0.0)
	rmsErrorPercent := sumSquaredCpu > 0 ? f32((normDiff / normCpu) * 100.0) : 0.0
	maxRelativeDiffPercent := cpuPeak > 0 ? (maxDifference / cpuPeak) * 100.0 : 0.0

	log.infof(
		"CPU/GPU signal metrics: samples=%d maxRelDiff=%.2f%% RMS=%.2f%% corr=%.6f peakRatio=%.4f energyRatio=%.4e",
		len(cpuData),
		maxRelativeDiffPercent,
		rmsErrorPercent,
		correlation,
		peakRatio,
		energyRatio,
	)

	return correlation >= MIN_CORRELATION && rmsErrorPercent <= MAX_RMS_ERROR_PERCENT && maxRelativeDiffPercent <= MAX_RELATIVE_DIFFERENCE_PERCENT
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
		gpuSettings = {enableDriverDebugMessages = auto_cast (utility.PROF_MODE == .None)},
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
		position  = {-6.164e-3, 7.192e-3, 50.492e-3},
		amplitude = 1,
	}

	elements := make(#soa[]vkField.RectangularElement, 1, context.allocator)
	defer delete(elements)
	elements[0] = transmitElement
	elements[0].apodization = receiveElement.apodization

	transmissionElements := make(#soa[]vkField.ElementSetMember, 1, context.allocator)
	defer delete(transmissionElements)
	transmissionElements[0] = {
		index       = 0,
		apodization = 1,
		delay       = 0,
	}
	receiveChannelElements := make(#soa[]vkField.ElementSetMember, 1, context.allocator)
	defer delete(receiveChannelElements)
	receiveChannelElements[0] = vkField.ElementSetMember {
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

	impulses := []vkField.TransducerImpulse{{1, 2}, {1, -1}}
	excitations := []vkField.Excitation{{0.5, 1}}
	transmissions[0].impulse = 1
	transmissions[0].excitation = 1
	receiveChannels[0].impulse = 2
	return compare_simulators(settings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
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
		gpuSettings = {enableDriverDebugMessages = auto_cast (utility.PROF_MODE == .None)},
	}

	elements := make_transmit_and_receive_grid_elements(columnCount, rowCount, elementPitch, elementWidth, 0)
	defer delete(elements)
	transmissions := make_full_aperture_transmissions(columnCount * rowCount)
	receiveChannels := make_column_receive_channels(columnCount, rowCount, len(transmissions[0].elements))
	defer {
		for receiveChannel in receiveChannels do delete(receiveChannel.elements)
		delete(receiveChannels)
		delete(transmissions[0].elements)
		delete(transmissions)
	}
	scatters := make_random_scatters(scatterCount, {-8e-3, 8e-3}, {-8e-3, 8e-3}, {10e-3, 100e-3})
	defer delete(scatters)

	return compare_simulators(settings, transmissions, receiveChannels, elements, scatters, nil, nil)
}

matrixArraySimulation :: proc() -> (ok := true) {

	utility.prof_init("matrixArraySimulation")
	utility.prof_thread_init()
	utility.prof_scoped(#procedure)

	scatterCount :: 64
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
		gpuSettings = {enableDriverDebugMessages = auto_cast (utility.PROF_MODE == .None)},
	}

	elements := make_transmit_and_receive_grid_elements(columnCount, rowCount, elementPitch * [2]f32{1, 1}, elementWidth * [2]f32{1, 1}, 0)
	defer delete(elements)
	transmissions := make_full_aperture_transmissions(columnCount * rowCount)
	receiveChannels := make_single_element_receive_channels(columnCount * rowCount, len(transmissions[0].elements))
	defer {
		for receiveChannel in receiveChannels do delete(receiveChannel.elements)
		delete(receiveChannels)
		delete(transmissions[0].elements)
		delete(transmissions)
	}
	scatters := make_random_scatters(scatterCount, {-8e-3, 8e-3}, {-8e-3, 8e-3}, {0, 100e-3})
	defer delete(scatters)

	return compare_simulators(settings, transmissions, receiveChannels, elements, scatters, nil, nil)
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
	transmissionElements := make(#soa[]vkField.ElementSetMember, elementCount, context.allocator)
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
		elements := make(#soa[]vkField.ElementSetMember, 1, context.allocator)
		elements[0] = vkField.ElementSetMember {
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
		elements := make(#soa[]vkField.ElementSetMember, rowCount, context.allocator)
		for row in 0 ..< rowCount {
			elementIndex := elementIndexOffset + column * rowCount + row
			elements[row] = vkField.ElementSetMember {
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
