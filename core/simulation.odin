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

SimulationSettings :: struct {
	samplingFrequency:    f32,
	speedOfSound:         f32,
	transmitElementCount: i32,
	receiveElementCount:  i32,
	scatterCount:         i32,
	startTime:            f32,
	sampleCount:          i32,
	headless:             b32,
}
#assert(size_of(SimulationSettings) == 32)

Element :: struct #align (16) {
	aperture:    Aperture,
	apodization: f32,
	delay:       f32,
	active:      b32,
	padding:     [4]byte,
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
	transmitElements: ^Element,
	receiveElements: ^Element,
	scatters: ^Scatter,
	pulseEcho: ^f32,
	cLogger: cLogProc = nil,
) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger)

	data := simulate_odin(
		settings,
		slice.from_ptr(transmitElements, int(settings.transmitElementCount)),
		slice.from_ptr(receiveElements, int(settings.receiveElementCount)),
		slice.from_ptr(scatters, int(settings.scatterCount)),
	)
	copy(slice.from_ptr(pulseEcho, len(data)), data)
}

@(export)
planSimulation_c :: proc "c" (
	settings: ^SimulationSettings,
	transmitElements: ^Element,
	receiveElements: ^Element,
	scatters: ^Scatter,
	cLogger: cLogProc = nil,
) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger)
	planSimulation_odin(
		settings,
		slice.from_ptr(transmitElements, int(settings.transmitElementCount)),
		slice.from_ptr(receiveElements, int(settings.receiveElementCount)),
		slice.from_ptr(scatters, int(settings.scatterCount)),
	)
}

simulate_odin :: proc(settings: ^SimulationSettings, transmitElements: []Element, receiveElements: []Element, scatters: []Scatter) -> (data: []f32) {
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
		devicePointer := rdoc.DEVICEPOINTER_FROM_VKINSTANCE(simulator.instance)
		rdoc.StartFrameCapture(rdoc_api, devicePointer, nil)
		// assert(rdoc.IsFrameCapturing(rdoc_api))
	}
	defer if rdoc_ok {
		devicePointer := rdoc.DEVICEPOINTER_FROM_VKINSTANCE(simulator.instance)
		rdoc.EndFrameCapture(rdoc_api, devicePointer, nil)
		// LaunchOrShowRenderdocUI(rdoc_api)
	}

	data = vkSimulate(&simulator, transmitElements, receiveElements, scatters)
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
	minTransmitDistance: f32 = math.INF_F32
	maxTransmitDistance: f32 = 0
	minReceiveDistance: f32 = math.INF_F32
	maxReceiveDistance: f32 = 0
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
	return
}

vkSimulate :: proc(simulator: ^vkSimulator, transmitElements: []Element, receiveElements: []Element, scatters: []Scatter) -> []f32 {
	device := simulator.device
	computeFence := simulator.computeFence
	commandBuffer := simulator.computeCommandPool.commandBuffers[0]
	settings := simulator.settings
	resources := &simulator.simulationResources

	// Make Buffers
	transmitBufferInfo: vk.BufferCreateInfo = {
		sType                 = .BUFFER_CREATE_INFO,
		flags                 = {},
		usage                 = {.STORAGE_BUFFER, .TRANSFER_DST},
		size                  = vk.DeviceSize(size_of(Element) * simulator.settings.transmitElementCount),
		sharingMode           = .EXCLUSIVE,
		queueFamilyIndexCount = 1,
		pQueueFamilyIndices   = &simulator.queueIndices.compute,
	}
	receiveBufferInfo: vk.BufferCreateInfo = transmitBufferInfo
	receiveBufferInfo.size = vk.DeviceSize(size_of(Element) * simulator.settings.receiveElementCount)
	scatterBufferInfo: vk.BufferCreateInfo = transmitBufferInfo
	scatterBufferInfo.size = vk.DeviceSize(size_of(Scatter) * simulator.settings.scatterCount)

	pulseEchoBufferInfo: vk.BufferCreateInfo = {
		sType                 = .BUFFER_CREATE_INFO,
		flags                 = {},
		usage                 = {.STORAGE_TEXEL_BUFFER, .TRANSFER_SRC},
		size                  = vk.DeviceSize(size_of(f32) * simulator.settings.receiveElementCount * simulator.settings.sampleCount),
		sharingMode           = .EXCLUSIVE,
		queueFamilyIndexCount = 1,
		pQueueFamilyIndices   = &simulator.queueIndices.compute,
	}

	must(vkCreateBuffer(simulator.vkDevice, &transmitBufferInfo, {.DEVICE_LOCAL}, &simulator.simulationResources.transmitElements))
	must(vkCreateBuffer(simulator.vkDevice, &receiveBufferInfo, {.DEVICE_LOCAL}, &simulator.simulationResources.receiveElements))
	must(vkCreateBuffer(simulator.vkDevice, &scatterBufferInfo, {.DEVICE_LOCAL}, &simulator.simulationResources.scatters))
	must(vkCreateBuffer(simulator.vkDevice, &pulseEchoBufferInfo, {.DEVICE_LOCAL}, &simulator.simulationResources.pulseEcho))
	defer vkDestroyBuffer(simulator.vkDevice, simulator.simulationResources.transmitElements)
	defer vkDestroyBuffer(simulator.vkDevice, simulator.simulationResources.receiveElements)
	defer vkDestroyBuffer(simulator.vkDevice, simulator.simulationResources.scatters)
	defer vkDestroyBuffer(simulator.vkDevice, simulator.simulationResources.pulseEcho)

	// Reset
	must(vk.ResetCommandPool(device, simulator.computeCommandPool.commandPool, {}))

	commandBeginInfo: vk.CommandBufferBeginInfo = {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	must(vk.BeginCommandBuffer(commandBuffer, &commandBeginInfo))

	// Upload data
	vkUploadBuffer(simulator.vkDevice, commandBuffer, &resources.transmitElements, slice.to_bytes(transmitElements), &resources.stagingBuffers)
	vkUploadBuffer(simulator.vkDevice, commandBuffer, &resources.receiveElements, slice.to_bytes(receiveElements), &resources.stagingBuffers)
	vkUploadBuffer(simulator.vkDevice, commandBuffer, &resources.scatters, slice.to_bytes(scatters), &resources.stagingBuffers)

	vk.CmdBindPipeline(commandBuffer, .COMPUTE, simulator.computePipeline.pipeline)

	uploadBufferBarriers: [3]vk.BufferMemoryBarrier2
	for &barrier in uploadBufferBarriers {
		barrier.sType = .BUFFER_MEMORY_BARRIER_2
		barrier.srcStageMask = {.TRANSFER, .HOST}
		barrier.srcAccessMask = {.TRANSFER_WRITE}
		barrier.dstStageMask = {.COMPUTE_SHADER}
		barrier.dstAccessMask = {.SHADER_READ}
	}
	uploadBufferBarriers[0].buffer = resources.transmitElements.buffer
	uploadBufferBarriers[0].size = resources.transmitElements.size
	uploadBufferBarriers[0].offset = 0
	uploadBufferBarriers[1].buffer = resources.receiveElements.buffer
	uploadBufferBarriers[1].size = resources.receiveElements.size
	uploadBufferBarriers[1].offset = 0
	uploadBufferBarriers[2].buffer = resources.scatters.buffer
	uploadBufferBarriers[2].size = resources.scatters.size
	uploadBufferBarriers[2].offset = 0

	uploadDepInfo: vk.DependencyInfo = {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = len(uploadBufferBarriers),
		pBufferMemoryBarriers    = &uploadBufferBarriers[0],
	}

	vk.CmdPipelineBarrier2KHR(commandBuffer, &uploadDepInfo)

	transmitElementsDescriptor: vk.DescriptorBufferInfo = {
		buffer = resources.transmitElements.buffer,
		range  = resources.transmitElements.size,
		offset = 0,
	}
	receiveElementsDescriptor: vk.DescriptorBufferInfo = {
		buffer = resources.receiveElements.buffer,
		range  = resources.receiveElements.size,
		offset = 0,
	}
	scattersDescriptor: vk.DescriptorBufferInfo = {
		buffer = resources.scatters.buffer,
		range  = resources.scatters.size,
		offset = 0,
	}
	pulseEchoBufferView: vk.BufferView
	must(vkCreateBufferView(simulator.vkDevice, resources.pulseEcho, .R32_SFLOAT, &pulseEchoBufferView))
	defer vk.DestroyBufferView(device, pulseEchoBufferView, nil)

	descriptorWrites: []vk.WriteDescriptorSet = {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = simulator.computeDescriptorPool.sets[0],
			dstBinding = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo = &transmitElementsDescriptor,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = simulator.computeDescriptorPool.sets[0],
			dstBinding = 1,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo = &receiveElementsDescriptor,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = simulator.computeDescriptorPool.sets[0],
			dstBinding = 2,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo = &scattersDescriptor,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = simulator.computeDescriptorPool.sets[0],
			dstBinding = 3,
			descriptorType = .STORAGE_TEXEL_BUFFER,
			descriptorCount = 1,
			pTexelBufferView = &pulseEchoBufferView,
		},
	}

	vk.UpdateDescriptorSets(device, auto_cast len(descriptorWrites), raw_data(descriptorWrites), 0, nil)

	vk.CmdBindDescriptorSets(
		commandBuffer,
		vk.PipelineBindPoint.COMPUTE,
		simulator.computePipeline.pipelineLayout,
		0,
		1,
		&simulator.computeDescriptorPool.sets[0],
		0,
		nil,
	)

	simSettings := vkSimulationSettings {
		samplingFrequency = settings.samplingFrequency,
		speedOfSound      = settings.speedOfSound,
		startingTime      = settings.startTime,
		sampleCount       = settings.sampleCount,
		receiveIndex      = 0,
	}
	vk.CmdPushConstants(commandBuffer, simulator.computePipeline.pipelineLayout, {.COMPUTE}, 0, size_of((vkSimulationSettings)), &simSettings)

	// dispatch
	vk.CmdDispatch(commandBuffer, u32(math.ceil(f32(simulator.settings.sampleCount) / 128)), u32(settings.transmitElementCount), u32(settings.scatterCount))

	downloadBufferBarriers: [1]vk.BufferMemoryBarrier2 = {
		{
			sType = .BUFFER_MEMORY_BARRIER_2,
			buffer = resources.pulseEcho.buffer,
			size = resources.pulseEcho.size,
			offset = 0,
			srcStageMask = {.COMPUTE_SHADER},
			srcAccessMask = {.SHADER_WRITE},
			dstStageMask = {.TRANSFER, .HOST},
			dstAccessMask = {.TRANSFER_READ},
		},
	}

	downloadDepInfo: vk.DependencyInfo = {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = len(downloadBufferBarriers),
		pBufferMemoryBarriers    = &downloadBufferBarriers[0],
	}

	vk.CmdPipelineBarrier2KHR(commandBuffer, &downloadDepInfo)

	vkDeviceDownload(simulator.vkDevice, commandBuffer, &resources.pulseEcho, &resources.stagingBuffers)

	must(vk.EndCommandBuffer(commandBuffer))

	commandSubmitInfo: vk.CommandBufferSubmitInfo = {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = commandBuffer,
		deviceMask    = 0,
	}

	submitInfo: vk.SubmitInfo2 = {
		sType                  = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos    = &commandSubmitInfo,
	}

	must(vk.QueueSubmit2KHR(simulator.computeQueue, 1, &submitInfo, computeFence))

	must(vk.WaitForFences(device, 1, &computeFence, true, 10 * 1e9))

	// Download
	pulseEcho := vkHostDownload(simulator.vkDevice, &resources.pulseEcho)

	for stagingBuffer in simulator.simulationResources.stagingBuffers {
		vkDestroyBuffer(simulator.vkDevice, stagingBuffer)
	}

	return slice.reinterpret([]f32, pulseEcho)
}

cLogProc :: #type proc "c" (string: cstring)

c_logger :: proc(l: log.Logger, c: cLogProc) -> log.Logger {
	c_logger_data :: struct {
		wrappedLogger: log.Logger,
		cLogProc:      cLogProc,
	}
	c_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, locations := #caller_location) {
		data := cast(^c_logger_data)data
		if (data.cLogProc != nil) {
			data.cLogProc(strings.clone_to_cstring(text, context.temp_allocator))
		}
		data.wrappedLogger.procedure(data.wrappedLogger.data, level, text, options, locations)
	}

	logger_data := new(c_logger_data, context.allocator)
	logger_data.wrappedLogger = context.logger
	logger_data.cLogProc = c
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
		current_directory := os.get_current_directory(context.temp_allocator)
		defer delete(current_directory, context.temp_allocator)

		abs_capture_path := filepath.join([]string{current_directory, transmute(string)capture_file_path}, context.temp_allocator)
		defer delete(abs_capture_path, context.temp_allocator)

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
