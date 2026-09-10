package vkfield

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"
import rdoc "import:renderdoc"
import utility "vkField:utility"

@(private = "file")
is_ok :: utility.is_ok
@(private = "file")
confirm :: utility.confirm
@(private = "file")
check :: utility.check
@(private = "file")
assert :: utility.assert
@(private = "file")
assume :: utility.assume

Simulator :: union {
	cpuSimulator,
	vkSimulator,
}

SimulationSettings :: struct #packed {
	samplingFrequency: f32,
	speedOfSound:      f32,
	startTime:         f32,
	sampleCount:       i32,
	cumulative:        b32,
	cpuSettings:       CpuSettings,
	gpuSettings:       GpuSettings,
	metrics:           SimulationMetrics,
}

CpuSettings :: struct {
	threadCount: u32,
}

GpuSettings :: struct {
	backend:                   GpuBackend,
	dispatchWorkLimit:         i32,
	enableDriverDebugMessages: b32,
}

GpuBackend :: enum u32 {
	Vulkan,
}

SimulationMetrics :: struct {
	simulationTime: f32,
}

#assert(size_of(RectangularElement) == 40)
RectangularElement :: struct {
	position:    [3]f32,
	normal:      [3]f32,
	size:        [2]f32,
	apodization: f32,
	delay:       f32,
}

Scatter :: struct {
	position:  [3]f32,
	amplitude: f32,
}
#assert(size_of(Scatter) == 16)

Transmission :: struct {
	elements: #soa[]TransmissionElement,
}

ReceiveChannel :: distinct Transmission

TransmissionElement :: struct {
	index:       i32,
	apodization: f32,
	delay:       f32,
}

ReceiveChannelElement :: distinct TransmissionElement

DistanceRange :: struct {
	minDistance: f32,
	maxDistance: f32,
}

SampleRange :: struct {
	minSample: i32,
	maxSample: i32,
}

ImpulseResponse :: struct {
	rect:  [4]f32,
	scale: f32,
}

simulate :: proc(
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
	allocator := context.allocator,
) -> (
	data: []f32,
	ok := true,
) {
	utility.prof_scoped(#procedure)

	switch &sim in simulator {
	case cpuSimulator:
		assert(settings.cpuSettings.threadCount == 1, "CPU multi-threading is not implemented yet; set CpuSettings.ThreadCount to 1")
	case vkSimulator:
		assert(settings.gpuSettings.backend == .Vulkan, "Only the Vulkan GPU backend is implemented")
	}

	rdocLib, rdocApi, rdoc_ok := rdoc.load_api()
	if rdoc_ok do log.infof("loaded renderdoc %v", rdocApi)
	defer if rdoc_ok do rdoc.unload_api(rdocLib)

	stopwatch: time.Stopwatch
	time.stopwatch_start(&stopwatch)
	switch &sim in simulator {
	case vkSimulator:
		if rdoc_ok {
			devicePointer := rdoc.DevicePointer(auto_cast sim.instance.instance)
			rdoc.start_frame_capture(rdocApi, devicePointer, nil)
			assert(rdoc.is_frame_capturing(rdocApi))
		}
		defer if rdoc_ok {
			devicePointer := rdoc.DevicePointer(auto_cast sim.instance.instance)
			rdoc.end_frame_capture(rdocApi, devicePointer, nil)
			LaunchOrShowRenderdocUI(rdocApi)
		}

		data = is_ok(check(vkSimulate(&sim, settings^, transmissions, receiveChannels, elements, scatters))) or_return
	case cpuSimulator:
		data = check(simulate_cpu(&sim, settings^, transmissions, receiveChannels, elements, scatters)) or_return
	}
	time.stopwatch_stop(&stopwatch)
	settings.metrics.simulationTime = auto_cast time.duration_seconds(time.stopwatch_duration(stopwatch))

	return
}

plan_simulation :: proc(
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
) -> (
	ok := true,
) {
	utility.prof_scoped(#procedure)
	switch &sim in simulator {
	case cpuSimulator:
		assert(settings.cpuSettings.threadCount == 1, "CPU multi-threading is not implemented yet; set CpuSettings.ThreadCount to 1")
	case vkSimulator:
		assert(settings.gpuSettings.backend == .Vulkan, "Only the Vulkan GPU backend is implemented")
	}
	for transmission in transmissions {
		for element in transmission.elements {
			check(element.index >= 0 && element.index < i32(len(elements)))
		}
	}
	for receiveChannel in receiveChannels {
		for element in receiveChannel.elements {
			assert(element.index >= 0 && element.index < i32(len(elements)))
		}
	}

	centroid := calculate_array_centroid(elements)
	sort_scatters_by_centroid_distance(scatters, centroid)

	distanceRange, _, _ := findDistanceLimits(transmissions, receiveChannels, elements, scatters)
	settings.startTime = distanceRange.minDistance / settings.speedOfSound
	sampleRange := distance_range_to_sample_range(distanceRange, settings.speedOfSound, settings.samplingFrequency, settings.startTime)
	settings.sampleCount = sample_range_sample_count(sampleRange)
	sampleCountPadding :: 6
	settings.sampleCount += sampleCountPadding
	settings.startTime -= sampleCountPadding / 4 / settings.samplingFrequency

	// We are rounding up to the nearest multiple of 32
	// PFFFT requires this for the CPU simulator, and it avoids some potential warp divergence on the GPU
	settings.sampleCount = (settings.sampleCount + 31) & ~i32(31)

	apertureSampleCount, scattererBatchSize := plan_scatterer_batching(simulator, settings^, transmissions, receiveChannels, elements, scatters)

	switch &sim in simulator {
	case vkSimulator:
		sim.info.apertureSampleCount = apertureSampleCount
		sim.info.scattererBatchSize = scattererBatchSize
		is_ok(check(plan_vulkan_simulator(&sim, settings^, transmissions, receiveChannels, elements, scatters))) or_return
	case cpuSimulator:
		sim.info.apertureSampleCount = apertureSampleCount
		sim.info.scattererBatchSize = scattererBatchSize
		check(plan_cpu_simulation(&sim, settings)) or_return
	}
	return
}

plan_scatterer_batching :: proc(
	simulator: ^Simulator,
	settings: SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
) -> (
	apertureSampleCount, scattererBatchSize: u32,
) {
	maxSharedMemoryAllowed: u32 = 32 * runtime.Kilobyte
	if sim, isVk := simulator.(vkSimulator); isVk {
		maxSharedMemoryAllowed = sim.device.physicalDevice.properties.limits.maxComputeSharedMemorySize
	}

	scatterCount := u32(len(scatters))
	initialBatchSize: u32 = 256
	scattererBatchSize = max(u32(1), min(scatterCount, initialBatchSize))

	if scatterCount == 0 do return 0, scattererBatchSize

	for {
		maxBatchApertureSampleCount: u32 = 0
		for batchStart: u32 = 0; batchStart < scatterCount; batchStart += scattererBatchSize {
			batchEnd := min(batchStart + scattererBatchSize, scatterCount)
			batchScatters := scatters[batchStart:batchEnd]

			_, batchTransmitDistanceRange, batchReceiveDistanceRange := findDistanceLimits(transmissions, receiveChannels, elements, batchScatters)

			batchTransmitSampleRange := distance_range_to_sample_range(batchTransmitDistanceRange, settings.speedOfSound, settings.samplingFrequency, 0)
			batchReceiveSampleRange := distance_range_to_sample_range(batchReceiveDistanceRange, settings.speedOfSound, settings.samplingFrequency, 0)

			batchApertureSampleCount := u32(max(sample_range_sample_count(batchTransmitSampleRange), sample_range_sample_count(batchReceiveSampleRange))) + 1
			maxBatchApertureSampleCount = max(maxBatchApertureSampleCount, batchApertureSampleCount)
		}

		sharedMemoryNeeded := 2 * maxBatchApertureSampleCount * u32(size_of(f32))
		if sharedMemoryNeeded <= maxSharedMemoryAllowed || scattererBatchSize <= 1 {
			apertureSampleCount = maxBatchApertureSampleCount
			break
		}

		scattererBatchSize = max(u32(1), scattererBatchSize / 2)
	}

	return
}

calculate_array_centroid :: proc(elements: #soa[]RectangularElement) -> [3]f32 {
	if len(elements) == 0 do return {0, 0, 0}
	sum: [3]f32 = {0, 0, 0}
	for i in 0 ..< len(elements) {
		sum += elements[i].position
	}
	return sum / f32(len(elements))
}

sort_scatters_by_centroid_distance :: proc(scatters: []Scatter, centroid: [3]f32) {
	if len(scatters) <= 1 do return
	c := centroid
	slice.sort_by_with_data(scatters, proc(a, b: Scatter, user_data: rawptr) -> bool {
			centroid_ptr := (^[3]f32)(user_data)
			da := linalg.length2(a.position - centroid_ptr^)
			db := linalg.length2(b.position - centroid_ptr^)
			return da < db
		}, &c)
}

findDistanceLimits :: proc(
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
) -> (
	distanceRange, transmitDistanceRange, receiveDistanceRange: DistanceRange,
) {
	utility.prof_scoped(#procedure)
	defer assert(distanceRange.maxDistance - distanceRange.minDistance >= 0)
	defer assert(transmitDistanceRange.maxDistance - transmitDistanceRange.minDistance >= 0)
	defer assert(receiveDistanceRange.maxDistance - receiveDistanceRange.minDistance >= 0)
	// Any distance range greater than 10m is likely an error, and furthermore would require an unreasonable amount of memory
	defer assert(distanceRange.maxDistance - distanceRange.minDistance < 10)
	defer assert(transmitDistanceRange.maxDistance - transmitDistanceRange.minDistance < 10)
	defer assert(receiveDistanceRange.maxDistance - receiveDistanceRange.minDistance < 10)

	minTransmitDistance, maxTransmitDistance: f32 = math.INF_F32, 0
	minReceiveDistance, maxReceiveDistance: f32 = math.INF_F32, 0
	for scatter in scatters {
		for transmission in transmissions {
			for transmissionElement in transmission.elements {
				transmit := elements[transmissionElement.index]
				delta := linalg.length(scatter.position - transmit.position)
				elementDelta := linalg.length(transmit.size) / 2
				minTransmitDistance = min(minTransmitDistance, delta - elementDelta)
				maxTransmitDistance = max(maxTransmitDistance, delta + elementDelta)
			}
		}

		for receiveChannel in receiveChannels {
			for receiveChannelElement in receiveChannel.elements {
				element := TransmissionElement(receiveChannelElement)
				receive := elements[element.index]
				delta := linalg.length(scatter.position - receive.position)
				elementDelta := linalg.length(receive.size) / 2
				minReceiveDistance = min(minReceiveDistance, delta - elementDelta)
				maxReceiveDistance = max(maxReceiveDistance, delta + elementDelta)
			}
		}
	}

	transmitDistanceRange = {minTransmitDistance, maxTransmitDistance}
	receiveDistanceRange = {minReceiveDistance, maxReceiveDistance}
	distanceRange = {minTransmitDistance + minReceiveDistance, maxTransmitDistance + maxReceiveDistance}
	return
}

LaunchOrShowRenderdocUI :: proc(rdoc_api: rdoc.Api) {
	num_captures, num_ok := rdoc.get_num_captures(rdoc_api)
	if !num_ok || num_captures == 0 do return
	latest_capture_index := num_captures - 1

	abs_capture_path, timestamp, cap_ok := rdoc.get_capture_info(rdoc_api, latest_capture_index, context.temp_allocator)
	if cap_ok {
		log.infof("loading latest capture (%v): %v", timestamp, abs_capture_path)
		pid, ok := rdoc.launch_or_show_replay_ui(rdoc_api, abs_capture_path)
		if !ok {
			log.error("couldn't launch or show Renderdoc UI")
			return
		}
		if pid != 0 {
			log.infof("launched Renderdoc UI pid(%v)", pid)
		}
	} else {
		log.warnf("no valid capture exists to load")
	}
}

sample_range_sample_count :: proc(range: SampleRange) -> i32 {
	return range.maxSample - range.minSample + 1
}

distance_range_to_sample_range :: proc(range: DistanceRange, speedOfSound, samplingFrequency, startTime: f32) -> SampleRange {
	return {
		cast(i32)math.floor(((range.minDistance / speedOfSound) - startTime) * samplingFrequency),
		cast(i32)math.ceil(((range.maxDistance / speedOfSound) - startTime) * samplingFrequency),
	}
}

sample_range_from_impulse :: #force_no_inline proc(impulse: ImpulseResponse) -> SampleRange {
	return impulse.scale == 0 ? {0, 0} : {i32(linalg.floor(impulse.rect.x - 0.5)), i32(linalg.ceil(impulse.rect.w + 0.5))}
}
