package vkfield

import rdoc "../utils/renderdoc"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:time"
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

SimulationSettings :: struct {
	samplingFrequency:    f32,
	speedOfSound:         f32,
	transmitElementCount: i32,
	receiveElementCount:  i32,
	scatterCount:         i32,
	startTime:            f32,
	sampleCount:          i32,
	cumulative:           b32,
	simulationTime:       f32,
	dispatchWorkLimit:    i32,
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

simulate :: proc(
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmitElements: #soa[]RectangularElement,
	receiveElements: #soa[]RectangularElement,
	scatters: []Scatter,
	allocator := context.allocator,
) -> (
	data: []f32,
	ok := true,
) {
	utility.prof_scoped(#procedure)
	assert(settings.transmitElementCount != 0)
	assert(settings.receiveElementCount != 0)
	assert(settings.scatterCount != 0)

	rdoc_lib, rdoc_api, rdoc_ok := rdoc.load_api()
	if rdoc_ok do log.infof("loaded renderdoc %v", rdoc_api)
	defer if rdoc_ok do rdoc.unload_api(rdoc_lib)

	stopwatch: time.Stopwatch
	time.stopwatch_start(&stopwatch)
	switch &sim in simulator {
	case vkSimulator:
		if rdoc_ok {
			devicePointer := rdoc.DEVICEPOINTER_FROM_VKINSTANCE(sim.instance.instance)
			rdoc.StartFrameCapture(rdoc_api, devicePointer, nil)
			// assert(rdoc.IsFrameCapturing(rdoc_api))
		}
		defer if rdoc_ok {
			devicePointer := rdoc.DEVICEPOINTER_FROM_VKINSTANCE(sim.instance.instance)
			rdoc.EndFrameCapture(rdoc_api, devicePointer, nil)
			// LaunchOrShowRenderdocUI(rdoc_api)
		}

		data = is_ok(check(vkSimulate(&sim, settings^, transmitElements, receiveElements, scatters))) or_return
	case cpuSimulator:
		data = check(simulate_cpu(&sim, settings^, transmitElements, receiveElements, scatters)) or_return
	}
	time.stopwatch_stop(&stopwatch)
	settings.simulationTime = auto_cast time.duration_seconds(time.stopwatch_duration(stopwatch))

	return
}

plan_simulation :: proc(
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmitElements: #soa[]RectangularElement,
	receiveElements: #soa[]RectangularElement,
	scatters: []Scatter,
) -> (
	ok := true,
) {
	utility.prof_scoped(#procedure)
	minDistance, maxDistance := findDistanceLimits(transmitElements, receiveElements, scatters)
	settings.startTime = minDistance / settings.speedOfSound
	settings.sampleCount = i32(math.ceil(((maxDistance - minDistance) / settings.speedOfSound) * settings.samplingFrequency))
	sampleCountPadding :: 6
	settings.sampleCount += sampleCountPadding
	settings.startTime -= sampleCountPadding / 4 / settings.samplingFrequency
	if (settings.transmitElementCount == 0) do settings.transmitElementCount = i32(len(transmitElements))
	if (settings.receiveElementCount == 0) do settings.receiveElementCount = i32(len(receiveElements))
	if (settings.scatterCount == 0) do settings.scatterCount = i32(len(scatters))
	assert(settings.transmitElementCount <= auto_cast len(transmitElements))
	assert(settings.receiveElementCount <= auto_cast len(receiveElements))
	assert(settings.scatterCount <= auto_cast len(scatters))

	switch &sim in simulator {
	case vkSimulator:
		is_ok(check(plan_vulkan_simulator(&sim, settings^))) or_return
	case cpuSimulator:
	}
	return
}

findDistanceLimits :: proc(
	transmitElements: #soa[]RectangularElement,
	receiveElements: #soa[]RectangularElement,
	scatters: []Scatter,
) -> (
	minDistance: f32,
	maxDistance: f32,
) {
	utility.prof_scoped(#procedure)
	defer assert(maxDistance - minDistance >= 0)
	// Any distance range greater than 10m is likely an error, and furthermore would require an unreasonable amount of memory
	defer assert(maxDistance - minDistance < 10)

	minTransmitDistance, maxTransmitDistance: f32 = math.INF_F32, 0
	minReceiveDistance, maxReceiveDistance: f32 = math.INF_F32, 0
	for scatter in scatters {
		for transmit in transmitElements {
			delta := linalg.length(scatter.position - transmit.position)
			elementDelta := linalg.length(transmit.size) / 2
			minTransmitDistance = min(minTransmitDistance, delta - elementDelta)
			maxTransmitDistance = max(maxTransmitDistance, delta + elementDelta)
		}

		for receive in receiveElements {
			delta := linalg.length(scatter.position - receive.position)
			elementDelta := linalg.length(receive.size) / 2
			minReceiveDistance = min(minReceiveDistance, delta - elementDelta)
			maxReceiveDistance = max(maxReceiveDistance, delta + elementDelta)
		}
	}

	minDistance = minTransmitDistance + minReceiveDistance
	maxDistance = maxTransmitDistance + maxReceiveDistance
	minDistance = min(minDistance, maxDistance)
	return
}

initRenderDoc :: proc() {

	// uncomment if you want to disable default behaviour of renderdoc capture keys
	// rdoc.SetCaptureKeys(rdoc_api, nil, 0)
}

LaunchOrShowRenderdocUI :: proc(rdoc_api: rawptr) {
	latest_capture_index := rdoc.GetNumCaptures(rdoc_api) - 1

	if latest_capture_index < 0 {
		return
	}

	timestamp: u64
	capture_file_path := make([]u8, 512, context.temp_allocator)
	defer delete(capture_file_path, context.temp_allocator)
	capture_file_path_len: u32

	if rdoc.GetCapture(rdoc_api, latest_capture_index, auto_cast raw_data(capture_file_path), &capture_file_path_len, &timestamp) != 0 {
		assert(capture_file_path_len < 512, "too long capture path!!")
		current_directory := assume(os.get_working_directory(context.temp_allocator))
		abs_capture_path := assume(filepath.join([]string{current_directory, transmute(string)capture_file_path}, context.temp_allocator))

		log.infof("loading latest capture: %v", abs_capture_path)

		if rdoc.IsTargetControlConnected(rdoc_api) {
			rdoc.ShowReplayUI(rdoc_api)
		} else {
			pid := rdoc.LaunchReplayUI(rdoc_api, 1, auto_cast raw_data(abs_capture_path))
			if pid == 0 {
				log.error("couldn't launch Renderdoc UI")
				return
			}
			log.infof("launched Renderdoc UI pid(%v)", pid)
		}
	} else {
		log.warnf("no valid capture exists to load")
	}
}
