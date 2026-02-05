package vkfield

import rdoc "../utils/renderdoc"
import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"
import vkField_util "vkField:utility"
import vkField_vk "vkField:vulkan"

@(private = "file")
is_ok :: vkField_util.is_ok
@(private = "file")
confirm :: vkField_util.confirm
@(private = "file")
check :: vkField_util.check
@(private = "file")
assert :: vkField_util.assert
@(private = "file")
assume :: vkField_util.assume

SimulationSettings :: struct {
	samplingFrequency:    f32,
	speedOfSound:         f32,
	transmitElementCount: i32,
	receiveElementCount:  i32,
	scatterCount:         i32,
	startTime:            f32,
	sampleCount:          i32,
	headless:             b32,
	cumulative:           b32,
}
#assert(size_of(SimulationSettings) == 36)

Element :: struct #align (16) {
	aperture:     Aperture,
	apertureType: f32,
	apodization:  f32,
	delay:        f32,
	padding:      [4]byte,
}
#assert(size_of(Element) == 64)

Aperture :: struct #raw_union {
	rectangle: RectangularAperture,
}
#assert(size_of(Aperture) == 48)

RectangularAperture :: struct {
	position: [3]f32,
	padding0: [4]byte,
	normal:   [3]f32,
	padding1: [4]byte,
	size:     [2]f32,
	padding2: [8]byte,
}

Scatter :: struct {
	position:  [3]f32,
	amplitude: f32,
}
#assert(size_of(Scatter) == 16)

@(export)
simulate_c :: proc "c" (
	settings: ^SimulationSettings,
	transmitElements: [^]Element,
	receiveElements: [^]Element,
	scatters: [^]Scatter,
	pulseEcho: [^]f32,
	cLogger: cLogProc = nil,
	loggerUserData: rawptr = nil,
) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, loggerUserData)
	data := simulate_odin(
		settings,
		transmitElements[:settings.transmitElementCount],
		receiveElements[:settings.receiveElementCount],
		scatters[:settings.scatterCount],
	)
	copy(pulseEcho[:len(data)], data)
}

@(export)
planSimulation_c :: proc "c" (
	settings: ^SimulationSettings,
	transmitElements: ^Element,
	receiveElements: ^Element,
	scatters: ^Scatter,
	cLogger: cLogProc = nil,
	loggerUserData: rawptr = nil,
) {
	if !vkField_vk.VKFIELD_VULKAN_INITIALIZED {
		vkField_vk.initialize()
	}
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, loggerUserData)
	planSimulation_odin(
		settings,
		slice.from_ptr(transmitElements, int(settings.transmitElementCount)),
		slice.from_ptr(receiveElements, int(settings.receiveElementCount)),
		slice.from_ptr(scatters, int(settings.scatterCount)),
	)
}

simulate_odin :: proc(
	settings: ^SimulationSettings,
	transmitElements: []Element,
	receiveElements: []Element,
	scatters: []Scatter,
	allocator := context.allocator,
) -> (
	data: []f32,
) {
	simulator: vkSimulator
	vkCreateSimulator(settings^, &simulator)
	defer vkDestroySimulator(&simulator)

	if (settings.transmitElementCount == 0) {
		settings.transmitElementCount = i32(len(transmitElements))
	}

	if (settings.receiveElementCount == 0) {
		settings.receiveElementCount = i32(len(receiveElements))
	}

	if (settings.scatterCount == 0) {
		settings.scatterCount = i32(len(scatters))
	}

	rdoc_lib, rdoc_api, rdoc_ok := rdoc.load_api()
	if rdoc_ok {
		log.infof("loaded renderdoc %v", rdoc_api)
	} else {
		log.warn("couldnt load renderdoc")
	}
	defer if rdoc_ok { rdoc.unload_api(rdoc_lib) }

	rdoc.SetCaptureFilePathTemplate(rdoc_api, "captures/capture.rdc")

	if rdoc_ok {
		devicePointer := rdoc.DEVICEPOINTER_FROM_VKINSTANCE(simulator.instance.instance)
		rdoc.StartFrameCapture(rdoc_api, devicePointer, nil)
		// assert(rdoc.IsFrameCapturing(rdoc_api))
	}
	defer if rdoc_ok {
		devicePointer := rdoc.DEVICEPOINTER_FROM_VKINSTANCE(simulator.instance.instance)
		rdoc.EndFrameCapture(rdoc_api, devicePointer, nil)
		// LaunchOrShowRenderdocUI(rdoc_api)
	}

	data, _ = check(vkSimulate(&simulator, transmitElements, receiveElements, scatters))

	return
}

planSimulation_odin :: proc(settings: ^SimulationSettings, transmitElements: []Element, receiveElements: []Element, scatters: []Scatter) {
	minDistance, maxDistance := findDistanceLimits(transmitElements, receiveElements, scatters)
	settings.startTime = minDistance / settings.speedOfSound
	settings.sampleCount = i32(math.ceil(((maxDistance - minDistance) / settings.speedOfSound) * settings.samplingFrequency))
	sampleCountPadding :: 6
	settings.sampleCount += sampleCountPadding
	settings.startTime -= sampleCountPadding / 4 / settings.samplingFrequency
}

findDistanceLimits :: proc(transmitElements: []Element, receiveElements: []Element, scatters: []Scatter) -> (minDistance: f32, maxDistance: f32) {
	defer assert(maxDistance - minDistance >= 0)
	// Any distance range greater than 10m is likely an error, and furthermore would require an unreasonable amount of memory
	defer assert(maxDistance - minDistance < 10)

	minTransmitDistance, maxTransmitDistance: f32 = math.INF_F32, 0
	minReceiveDistance, maxReceiveDistance: f32 = math.INF_F32, 0
	for scatter in scatters {
		for transmit in transmitElements {
			delta := linalg.length(scatter.position - transmit.aperture.rectangle.position)
			elementDelta := linalg.length(transmit.aperture.rectangle.size) / 2
			minTransmitDistance = min(minTransmitDistance, delta - elementDelta)
			maxTransmitDistance = max(maxTransmitDistance, delta + elementDelta)
		}

		for receive in receiveElements {
			delta := linalg.length(scatter.position - receive.aperture.rectangle.position)
			elementDelta := linalg.length(receive.aperture.rectangle.size) / 2
			minReceiveDistance = min(minReceiveDistance, delta - elementDelta)
			maxReceiveDistance = max(maxReceiveDistance, delta + elementDelta)
		}
	}

	minDistance = minTransmitDistance + minReceiveDistance
	maxDistance = maxTransmitDistance + maxReceiveDistance
	minDistance = min(minDistance, maxDistance)
	return
}

cLogProc :: #type proc "c" (pUserData: rawptr, string: cstring)

c_logger :: proc(l: log.Logger, c: cLogProc, pUserData: rawptr) -> log.Logger {
	c_logger_data :: struct {
		wrappedLogger: log.Logger,
		cLogProc:      cLogProc,
		pUserData:     rawptr,
	}
	c_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, locations := #caller_location) {
		data := cast(^c_logger_data)data
		if (data.cLogProc != nil) {
			data.cLogProc(data.pUserData, strings.clone_to_cstring(text, context.temp_allocator))
		}
		data.wrappedLogger.procedure(data.wrappedLogger.data, level, text, options, locations)
	}

	logger_data := new(c_logger_data, context.allocator)
	logger_data.wrappedLogger = context.logger
	logger_data.cLogProc = c
	logger_data.pUserData = pUserData
	return log.Logger {
		data = logger_data,
		lowest_level = logger_data.wrappedLogger.lowest_level,
		options = logger_data.wrappedLogger.options,
		procedure = c_logger_proc,
	}
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
