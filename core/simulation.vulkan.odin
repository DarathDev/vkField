package vkfield

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
import "core:time"

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

MAX_FRAMES_IN_FLIGHT :: 2

DISPATCH_TIMEOUT :: 1000 * time.Second

SHADER_COMPUTE_CALCULATE_APERTURE :: #load("shaders/calculateAperture.spv")
SHADER_COMPUTE_MEASURE_APERTURE :: #load("shaders/measureAperture.spv")
SHADER_COMPUTE_COALESCE_APERTURE :: #load("shaders/coalesceAperture.spv")
SHADER_COMPUTE_PULSE_ECHO_CONVOLVE :: #load("shaders/pulseEchoConvolution.spv")

@(private = "file")
debugLogger: log.Logger

when ODIN_OS != .Darwin {
	DEVICE_EXTENSIONS := []cstring{vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME, vk.KHR_SHADER_NON_SEMANTIC_INFO_EXTENSION_NAME}
} else {
	DEVICE_EXTENSIONS := []cstring {
		vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
		vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
		vk.KHR_SHADER_NON_SEMANTIC_INFO_EXTENSION_NAME,
	}
}

vkSimulator :: struct {
	info:                vkSimulationInfo,
	instance:            vkField_vk.Instance,
	debugUserData:       ^vkField_vk.DebugUserData,
	debugMessenger:      vkField_vk.DebugMessenger,
	physicalDevices:     #soa[]vkField_vk.PhysicalDevice,
	device:              vkField_vk.Device,
	queue:               vkField_vk.Queue,
	pipelineLayout:      vk.PipelineLayout,
	simulationResources: vkSimulationResources,
	computeCommandPool:  vkField_vk.CommandPool,
	computeFence:        vk.Fence,
}

vkSimulationInfo :: struct {
	apertureSampleCount: u32,
	scattererBatchSize:  u32,
}

vkSimulationResources :: union {
	vkPulseEchoSimulationResources,
}

vkPulseEchoSimulationResources :: struct {
	dataBuffer:        vkStagableBuffer,
	dataBufferHeader:  vkDataBufferHeader,
	responseBuffer:    vkStagableBuffer,
	calcAperShader:    vk.ShaderEXT,
	measAperShaderTx:  vk.ShaderEXT,
	measAperShaderRcv: vk.ShaderEXT,
	coalAperShaderTx:  vk.ShaderEXT,
	coalAperShaderRcv: vk.ShaderEXT,
	pulseConvShader:   vk.ShaderEXT,
	calcAperSpec:      vkCalcAperSpecConstants,
	measAperSpecTx:    vkMeasAperSpecConstants,
	measAperSpecRcv:   vkMeasAperSpecConstants,
	coalAperSpecTx:    vkCoalAperSpecConstants,
	coalAperSpecRcv:   vkCoalAperSpecConstants,
	pulseConvSpec:     vkPulseConvSpecConstants,
}

vkGeneralSpecContants :: struct {
	ResponseSampleCount: u32,
	ElementCount:        u32,
	ScattererCount:      u32,
	ScattererBatchCount: u32,
	TransmissionCount:   u32,
	ReceiveChannelCount: u32,
	ApertureSampleCount: u32,
	SamplingFrequency:   f32,
	SpeedOfSound:        f32,
	StartTime:           f32,
}

vkCalcAperSpecConstants :: struct {
	using general:          vkGeneralSpecContants,
	ElementWorkgroupSize:   u32,
	ScattererWorkgroupSize: u32,
}

vkCoalesceSpecConstants :: struct {
	using general:         vkGeneralSpecContants,
	CoalesceTransmissions: b32,
	Cumulative:            b32,
}

vkMeasAperSpecConstants :: struct {
	using coalese:           vkCoalesceSpecConstants,
	ElementSetWorkgroupSize: u32,
	ScattererWorkgroupSize:  u32,
}

vkCoalAperSpecConstants :: struct {
	using coalese:           vkCoalesceSpecConstants,
	SampleWorkgroupSize:     u32,
	ElementSetWorkgroupSize: u32,
	ScattererWorkgroupSize:  u32,
}

vkPulseConvSpecConstants :: struct {
	using general:       vkGeneralSpecContants,
	SampleWorkgroupSize: u32,
}

vkCalcAperPushData :: struct {
	elementPositions:      vk.DeviceAddress,
	apertureResponseRects: vk.DeviceAddress,
	elementOffset:         u32,
	scattererOffset:       u32,
}

vkCoalescePushData :: struct {
	apertureResponseRects:     vk.DeviceAddress,
	transmissionInfos:         vk.DeviceAddress,
	transmissionResponses:     vk.DeviceAddress,
	transmissionElementCounts: vk.DeviceAddress,
	elementSetMembers:         vk.DeviceAddress,
	elementSetOffset:          u32,
	scattererOffset:           u32,
}

vkPulseConvPushData :: struct {
	transmissionInfos:     vk.DeviceAddress,
	transmissionResponses: vk.DeviceAddress,
	response:              vk.DeviceAddress,
	transmissionIndex:     u32,
	receiveChannelIndex:   u32,
	scattererOffset:       u32,
}

vkStagableBuffer :: struct {
	main:    vkField_vk.Buffer,
	staging: Maybe(vkField_vk.Buffer),
}

vkDataBufferHeader :: struct {
	elementPositions:            u32,
	elementNormals:              u32,
	elementSizes:                u32,
	elementApodizations:         u32,
	elementDelays:               u32,
	scatterers:                  u32,
	apertureResponseRects:       u32,
	apertureResponseScales:      u32,
	transmissionInfos:           u32,
	receiveChannelInfos:         u32,
	transmissionResponses:       u32,
	receiveChannelResponses:     u32,
	transmissionElementCounts:   u32,
	transmissionBaseOffsets:     u32,
	receiveChannelElementCounts: u32,
	receiveChannelBaseOffsets:   u32,
	elementSetMembers:           u32,
	totalSize:                   u32,
}

create_vulkan_simulator :: proc(settings: SimulationSettings) -> (simulator: vkSimulator, ok := vk.Result.SUCCESS) {
	simulator.debugUserData = new(vkField_vk.DebugUserData)
	simulator.debugUserData.logger = context.logger

	instanceCapabilities: vkField_vk.InstanceCapabilities = {}
	if settings.gpuSettings.enableDriverDebugMessages do instanceCapabilities = {.Validation, .DebugUtils}

	simulator.instance = confirm(
		vkField_vk.create_instance(
			{appName = "vkField", vulkanVersion = vk.API_VERSION_1_3, optionalCapabilities = instanceCapabilities},
			debugUserData = simulator.debugUserData,
		),
	) or_return

	if .DebugUtils in simulator.instance.enabledCapabilities {
		simulator.debugMessenger = confirm(vkField_vk.create_debug_messenger(simulator.instance, simulator.debugUserData)) or_return
	}

	simulator.physicalDevices = vkField_vk.get_physical_devices(simulator.instance) or_return
	requiredCapabilities: vkField_vk.DeviceCapabilities = {
		.Synchronization2,
		.Maintenance4,
		.BufferDeviceAddress,
		.ShaderObject,
		.ScalarBlockLayout,
		.ShaderInt64,
	}
	physicalDevice, physicalDeviceAvailable := vkField_vk.pick_physical_device(
		simulator.instance.instance,
		simulator.physicalDevices,
		{requiredCapabilities = requiredCapabilities},
	)
	if !physicalDeviceAvailable do return simulator, vk.Result.ERROR_DEVICE_LOST
	queues: [][]vkField_vk.Queue
	simulator.device, queues = check(
		vkField_vk.create_device(
			simulator.instance,
			physicalDevice,
			{requiredCapabilities = requiredCapabilities},
			{{requiredProperties = {.Compute, .Transfer}, count = 1}},
			"Main Device",
			context.temp_allocator,
		),
	) or_return

	pushConstantSize := max(size_of(vkCalcAperPushData), size_of(vkCoalescePushData), size_of(vkPulseConvPushData))
	simulator.pipelineLayout = check(
		vkField_vk.create_pipeline_layout(simulator.device, {}, {{stageFlags = {.COMPUTE}, size = auto_cast pushConstantSize, offset = 0}}),
	) or_return
	simulator.queue = queues[0][0]

	simulator.computeCommandPool = check(vkField_vk.create_command_pool(simulator.device, simulator.queue, true)) or_return
	simulator.computeFence = check(vkField_vk.create_fence(simulator.device, label = "Compute")) or_return

	return
}

destroy_vulkan_simulator :: proc(simulator: ^vkSimulator) {
	destroy_vulkan_simulator_resources(simulator)

	vkField_vk.destroy_fence(simulator.device, simulator.computeFence)
	vkField_vk.destroy_command_pool(simulator.device, simulator.computeCommandPool)

	vkField_vk.destroy_pipeline_layout(simulator.device, simulator.pipelineLayout)

	vkField_vk.destroy_device(&simulator.device)
	vkField_vk.free_physical_devices(&simulator.physicalDevices)
	if .DebugUtils in simulator.instance.enabledCapabilities {
		vkField_vk.destroy_debug_messenger(simulator.instance.instance, &simulator.debugMessenger)
	}
	vkField_vk.destroy_instance(&simulator.instance)
	free(simulator.debugUserData)
	simulator^ = {}
}

plan_vulkan_simulator :: proc(
	simulator: ^vkSimulator,
	settings: SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
) -> (
	result: vk.Result,
) {
	destroy_vulkan_simulator_resources(simulator)

	limits := simulator.device.physicalDevice.properties.limits
	maxComputeSharedMemorySize := limits.maxComputeSharedMemorySize
	pulseEchoSharedMemory := 2 * simulator.info.apertureSampleCount * size_of(f32)
	assert(pulseEchoSharedMemory <= maxComputeSharedMemorySize, "Pulse echo convolution shared memory exceeds device maxComputeSharedMemorySize")

	maxStorageBufferRange := u32(limits.maxStorageBufferRange)
	maxBufferLimit: u32 = maxStorageBufferRange
	if settings.gpuSettings.dispatchWorkLimit > 0 {
		maxBufferLimit = min(maxBufferLimit, u32(settings.gpuSettings.dispatchWorkLimit))
	}

	elementCount := u32(len(elements))
	transmissionCount := u32(len(transmissions))
	receiveChannelCount := u32(len(receiveChannels))
	apertureSampleCount := simulator.info.apertureSampleCount
	scatterCount := u32(len(scatters))

	memberCount: u32 = 0
	for transmission in transmissions do memberCount += auto_cast len(transmission.elements)
	for receiveChannel in receiveChannels do memberCount += auto_cast len(receiveChannel.elements)

	fixedHeaderBytes :=
		u32(size_of(vkDataBufferHeader)) +
		elementCount * u32(size_of([3]f32) * 2 + size_of([2]f32) + size_of(f32) * 2) +
		(transmissionCount + receiveChannelCount) * u32(size_of(u32) * 2) +
		memberCount * u32(3 * size_of(u32))

	bytesPerScatterer :=
		u32(size_of(Scatter)) +
		elementCount * u32(size_of([4]f32) + size_of(f32)) +
		(transmissionCount + receiveChannelCount) * u32(size_of(SampleRange)) +
		(transmissionCount + receiveChannelCount) * apertureSampleCount * u32(size_of(f32))

	targetBatchSize := max(u32(1), min(scatterCount, 256))
	if fixedHeaderBytes < maxBufferLimit && bytesPerScatterer > 0 {
		maxBatchFromBuffer := (maxBufferLimit - fixedHeaderBytes) / bytesPerScatterer
		simulator.info.scattererBatchSize = max(u32(1), min(targetBatchSize, maxBatchFromBuffer))
	} else {
		simulator.info.scattererBatchSize = targetBatchSize
	}

	dataBuffer, dataBufferHeader := vkBuildDataBuffer(simulator, settings, transmissions, receiveChannels, elements, scatters, context.temp_allocator)

	device := simulator.device

	vkDataBuffer := check(prepare_stream(device, auto_cast len(dataBuffer))) or_return
	responseBuffer := check(
		prepare_readback(device, auto_cast (len(transmissions) * len(receiveChannels) * int(settings.sampleCount)) * size_of(f32)),
	) or_return

	commandBuffer := check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return
	defer vkField_vk.reset_command_buffer(device, &simulator.computeCommandPool, commandBuffer)
	vkField_vk.cmd_begin(commandBuffer, true) or_return
	vkField_vk.cmd_upload(commandBuffer, dataBuffer, vkDataBuffer.main, vkDataBuffer.staging.? or_else {})
	vkField_vk.cmd_end(commandBuffer) or_return

	vkField_vk.queue_submit(simulator.queue, {commandBuffer}, {}, {}, simulator.computeFence) or_return
	check(vk.WaitForFences(device.device, 1, &simulator.computeFence, true, auto_cast time.duration_nanoseconds(auto_cast DISPATCH_TIMEOUT))) or_return
	vk.ResetFences(device.device, 1, &simulator.computeFence) or_return

	generalSpec: vkGeneralSpecContants = {
		ResponseSampleCount = auto_cast settings.sampleCount,
		ElementCount        = auto_cast len(elements),
		ScattererCount      = auto_cast len(scatters),
		ScattererBatchCount = auto_cast simulator.info.scattererBatchSize,
		TransmissionCount   = auto_cast len(transmissions),
		ReceiveChannelCount = auto_cast len(receiveChannels),
		ApertureSampleCount = auto_cast simulator.info.apertureSampleCount,
		SamplingFrequency   = settings.samplingFrequency,
		SpeedOfSound        = settings.speedOfSound,
		StartTime           = settings.startTime,
	}

	maxComputeWorkgroupInvocations := simulator.device.physicalDevice.properties.limits.maxComputeWorkGroupInvocations

	calcAperSpec: vkCalcAperSpecConstants = {
		general                = generalSpec,
		ElementWorkgroupSize   = 64,
		ScattererWorkgroupSize = 1,
	}
	assert(calcAperSpec.ElementWorkgroupSize * calcAperSpec.ScattererWorkgroupSize <= maxComputeWorkgroupInvocations)

	coalesceSpecTx: vkCoalesceSpecConstants = {
		general               = generalSpec,
		CoalesceTransmissions = true,
		Cumulative            = settings.cumulative,
	}

	measAperWorkgroupSize: [2]u32 = {64, 1}
	assert(measAperWorkgroupSize.x * measAperWorkgroupSize.y <= maxComputeWorkgroupInvocations)

	measAperSpecTx: vkMeasAperSpecConstants = {
		coalese                 = coalesceSpecTx,
		ElementSetWorkgroupSize = measAperWorkgroupSize.x,
		ScattererWorkgroupSize  = measAperWorkgroupSize.y,
	}
	measAperSpecRcv := measAperSpecTx
	measAperSpecRcv.CoalesceTransmissions = false

	coalAperWorkgroupSize: [3]u32 = {64, 1, 1}
	assert(coalAperWorkgroupSize.x * coalAperWorkgroupSize.y * coalAperWorkgroupSize.z <= maxComputeWorkgroupInvocations)
	coalAperSpecTx: vkCoalAperSpecConstants = {
		coalese                 = coalesceSpecTx,
		SampleWorkgroupSize     = coalAperWorkgroupSize.x,
		ElementSetWorkgroupSize = coalAperWorkgroupSize.y,
		ScattererWorkgroupSize  = coalAperWorkgroupSize.z,
	}
	coalAperSpecRcv := coalAperSpecTx
	coalAperSpecRcv.CoalesceTransmissions = false

	pulseConvSpec: vkPulseConvSpecConstants = {
		general             = generalSpec,
		SampleWorkgroupSize = 64,
	}
	assert(pulseConvSpec.SampleWorkgroupSize <= maxComputeWorkgroupInvocations)

	calcAperShaders, _ := vkField_vk.create_shaders(
		device,
		{
			code = SHADER_COMPUTE_CALCULATE_APERTURE,
			entryPoints = {{name = "main", stage = .COMPUTE}},
			specializationInfo = {vkField_vk.create_specialization_info(calcAperSpec)},
		},
		{},
		{{stageFlags = {.COMPUTE}, size = size_of(vkCoalescePushData)}},
		false,
		"Calculate Aperture",
		context.temp_allocator,
	) or_return

	measAperShaders, _ := vkField_vk.create_shaders(
		device,
		{
			code = SHADER_COMPUTE_MEASURE_APERTURE,
			entryPoints = {{name = "main", stage = .COMPUTE}, {name = "main", stage = .COMPUTE}},
			specializationInfo = {vkField_vk.create_specialization_info(measAperSpecTx), vkField_vk.create_specialization_info(measAperSpecRcv)},
		},
		{},
		{{stageFlags = {.COMPUTE}, size = size_of(vkCoalescePushData)}},
		false,
		"Measure Aperture",
		context.temp_allocator,
	) or_return

	coalAperShaders, _ := vkField_vk.create_shaders(
		device,
		{
			code = SHADER_COMPUTE_COALESCE_APERTURE,
			entryPoints = {{name = "main", stage = .COMPUTE}, {name = "main", stage = .COMPUTE}},
			specializationInfo = {vkField_vk.create_specialization_info(coalAperSpecTx), vkField_vk.create_specialization_info(coalAperSpecRcv)},
		},
		{},
		{{stageFlags = {.COMPUTE}, size = size_of(vkCoalescePushData)}},
		false,
		"Coalesce Aperture",
		context.temp_allocator,
	) or_return

	pulseConvShaders, _ := vkField_vk.create_shaders(
		device,
		{
			code = SHADER_COMPUTE_PULSE_ECHO_CONVOLVE,
			entryPoints = {{name = "main", stage = .COMPUTE}},
			specializationInfo = {vkField_vk.create_specialization_info(pulseConvSpec)},
		},
		{},
		{{stageFlags = {.COMPUTE}, size = size_of(vkPulseConvPushData)}},
		false,
		"Pulse Echo Convolution",
		context.temp_allocator,
	) or_return

	simulator.simulationResources = vkPulseEchoSimulationResources {
		dataBuffer        = vkDataBuffer,
		dataBufferHeader  = dataBufferHeader,
		responseBuffer    = responseBuffer,
		calcAperShader    = calcAperShaders[0],
		measAperShaderTx  = measAperShaders[0],
		measAperShaderRcv = measAperShaders[1],
		coalAperShaderTx  = coalAperShaders[0],
		coalAperShaderRcv = coalAperShaders[1],
		pulseConvShader   = pulseConvShaders[0],
		calcAperSpec      = calcAperSpec,
		measAperSpecTx    = measAperSpecTx,
		measAperSpecRcv   = measAperSpecRcv,
		coalAperSpecTx    = coalAperSpecTx,
		coalAperSpecRcv   = coalAperSpecRcv,
		pulseConvSpec     = pulseConvSpec,
	}
	return
}

destroy_vulkan_simulator_resources :: proc(simulator: ^vkSimulator) {
	device := simulator.device

	switch resources in simulator.simulationResources {
	case vkPulseEchoSimulationResources:
		vkField_vk.destroy_shader(device, resources.calcAperShader)
		vkField_vk.destroy_shader(device, resources.measAperShaderTx)
		vkField_vk.destroy_shader(device, resources.measAperShaderRcv)
		vkField_vk.destroy_shader(device, resources.coalAperShaderTx)
		vkField_vk.destroy_shader(device, resources.coalAperShaderRcv)
		vkField_vk.destroy_shader(device, resources.pulseConvShader)
		release_staged_buffer(device, resources.dataBuffer)
		release_staged_buffer(device, resources.responseBuffer)
		simulator.simulationResources = {}
	}

	release_staged_buffer :: proc(device: vkField_vk.Device, buffer: vkStagableBuffer) {
		vkField_vk.release_buffer(device, buffer.main)
		if buffer, bufferOk := buffer.staging.?; bufferOk {
			vkField_vk.release_buffer(device, buffer)
		}
	}
}

vkSimulate :: proc(
	simulator: ^vkSimulator,
	settings: SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
	allocator := context.allocator,
) -> (
	response: []f32,
	result: vk.Result,
) {
	resources, pulseEchoResourcesOk := simulator.simulationResources.(vkPulseEchoSimulationResources)
	if !check(pulseEchoResourcesOk) do return {}, .ERROR_INITIALIZATION_FAILED

	device := simulator.device

	response = make([]f32, resources.responseBuffer.main.size / size_of(f32), allocator)

	commandBuffer := check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return
	defer vkField_vk.reset_command_buffer(device, &simulator.computeCommandPool, commandBuffer)

	vkField_vk.cmd_begin(commandBuffer, true) or_return

	vkField_vk.cmd_clear_buffer(commandBuffer, resources.responseBuffer.main)

	vkField_vk.cmd_pipeline_barrier(
		commandBuffer,
		{},
		{
			{
				buffer = resources.responseBuffer.main.buffer,
				size = resources.responseBuffer.main.size,
				offset = 0,
				srcStageMask = {.TRANSFER},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
			},
		},
		{},
	)

	shaderStage: vk.ShaderStageFlags = {.COMPUTE}

	scatterBatchSize := simulator.info.scattererBatchSize
	dataBufferAddress := vkField_vk.get_buffer_address(device, resources.dataBuffer.main)
	header := resources.dataBufferHeader
	for scatterOffset := 0; scatterOffset < len(scatters); scatterOffset += auto_cast scatterBatchSize {
		vkField_vk.cmd_push_constants(
			commandBuffer,
			simulator.pipelineLayout,
			shaderStage,
			vkCalcAperPushData {
				elementPositions = dataBufferAddress + auto_cast header.elementPositions,
				apertureResponseRects = dataBufferAddress + auto_cast header.apertureResponseRects,
				elementOffset = 0,
				scattererOffset = auto_cast scatterOffset,
			},
		)

		vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.calcAperShader)
		vk.CmdDispatch(
			commandBuffer.commandBuffer,
			u32(math.ceil(f32(len(elements)) / f32(resources.calcAperSpec.ElementWorkgroupSize))),
			u32(math.ceil(f32(scatterBatchSize) / f32(resources.calcAperSpec.ScattererWorkgroupSize))),
			1,
		)

		vkField_vk.cmd_pipeline_barrier(
			commandBuffer,
			{},
			{
				{
					buffer = resources.dataBuffer.main.buffer,
					size = resources.dataBuffer.main.size,
					offset = 0,
					srcStageMask = {.COMPUTE_SHADER},
					srcAccessMask = {.SHADER_WRITE},
					dstStageMask = {.COMPUTE_SHADER},
					dstAccessMask = {.SHADER_READ},
				},
			},
			{},
		)

		vkField_vk.cmd_push_constants(
			commandBuffer,
			simulator.pipelineLayout,
			shaderStage,
			vkCoalescePushData {
				apertureResponseRects = dataBufferAddress + auto_cast header.apertureResponseRects,
				transmissionInfos = dataBufferAddress + auto_cast header.transmissionInfos,
				transmissionResponses = dataBufferAddress + auto_cast header.transmissionResponses,
				transmissionElementCounts = dataBufferAddress + auto_cast header.transmissionElementCounts,
				elementSetMembers = dataBufferAddress + auto_cast header.elementSetMembers,
				elementSetOffset = 0,
				scattererOffset = auto_cast scatterOffset,
			},
		)

		vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.measAperShaderTx)
		vk.CmdDispatch(
			commandBuffer.commandBuffer,
			u32(math.ceil(f32(len(transmissions)) / f32(resources.measAperSpecTx.ElementSetWorkgroupSize))),
			u32(math.ceil(f32(scatterBatchSize) / f32(resources.measAperSpecTx.ScattererWorkgroupSize))),
			1,
		)
		vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.measAperShaderRcv)
		vk.CmdDispatch(
			commandBuffer.commandBuffer,
			u32(math.ceil(f32(len(receiveChannels)) / f32(resources.measAperSpecRcv.ElementSetWorkgroupSize))),
			u32(math.ceil(f32(scatterBatchSize) / f32(resources.measAperSpecRcv.ScattererWorkgroupSize))),
			1,
		)

		vkField_vk.cmd_pipeline_barrier(
			commandBuffer,
			{},
			{
				{
					buffer = resources.dataBuffer.main.buffer,
					size = resources.dataBuffer.main.size,
					offset = 0,
					srcStageMask = {.COMPUTE_SHADER},
					srcAccessMask = {.SHADER_WRITE},
					dstStageMask = {.COMPUTE_SHADER},
					dstAccessMask = {.SHADER_READ},
				},
			},
			{},
		)

		vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.coalAperShaderTx)
		vk.CmdDispatch(
			commandBuffer.commandBuffer,
			u32(math.ceil(f32(simulator.info.apertureSampleCount) / f32(resources.coalAperSpecTx.SampleWorkgroupSize))),
			u32(math.ceil(f32(len(transmissions)) / f32(resources.coalAperSpecTx.ElementSetWorkgroupSize))),
			u32(math.ceil(f32(scatterBatchSize) / f32(resources.coalAperSpecTx.ScattererWorkgroupSize))),
		)
		vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.coalAperShaderRcv)
		vk.CmdDispatch(
			commandBuffer.commandBuffer,
			u32(math.ceil(f32(simulator.info.apertureSampleCount) / f32(resources.coalAperSpecTx.SampleWorkgroupSize))),
			u32(math.ceil(f32(len(receiveChannels)) / f32(resources.coalAperSpecRcv.ElementSetWorkgroupSize))),
			u32(math.ceil(f32(scatterBatchSize) / f32(resources.coalAperSpecRcv.ScattererWorkgroupSize))),
		)

		vkField_vk.cmd_pipeline_barrier(
			commandBuffer,
			{},
			{
				{
					buffer = resources.dataBuffer.main.buffer,
					size = resources.dataBuffer.main.size,
					offset = 0,
					srcStageMask = {.COMPUTE_SHADER},
					srcAccessMask = {.SHADER_WRITE},
					dstStageMask = {.COMPUTE_SHADER},
					dstAccessMask = {.SHADER_READ},
				},
			},
			{},
		)

		vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.pulseConvShader)
		for transmissionIndex in 0 ..< len(transmissions) {
			for receiveChannelIndex in 0 ..< len(receiveChannels) {
				vkField_vk.cmd_push_constants(
					commandBuffer,
					simulator.pipelineLayout,
					shaderStage,
					vkPulseConvPushData {
						transmissionInfos = dataBufferAddress + auto_cast header.transmissionInfos,
						transmissionResponses = dataBufferAddress + auto_cast header.transmissionResponses,
						response = vkField_vk.get_buffer_address(device, resources.responseBuffer.main),
						transmissionIndex = auto_cast transmissionIndex,
						receiveChannelIndex = auto_cast receiveChannelIndex,
						scattererOffset = auto_cast scatterOffset,
					},
				)

				vk.CmdDispatch(commandBuffer.commandBuffer, u32(math.ceil(f32(settings.sampleCount) / f32(resources.pulseConvSpec.SampleWorkgroupSize))), 1, 1)
			}
		}
	}

	vkField_vk.cmd_pipeline_barrier(
		commandBuffer,
		{},
		{
			{
				buffer = resources.responseBuffer.main.buffer,
				size = resources.responseBuffer.main.size,
				offset = 0,
				srcStageMask = {.COMPUTE_SHADER},
				srcAccessMask = {.SHADER_WRITE},
				dstStageMask = {.TRANSFER, .HOST},
				dstAccessMask = {.TRANSFER_READ},
			},
		},
		{},
	)

	downloadBuffer: vkField_vk.Buffer
	if buffer, bufferOk := resources.responseBuffer.staging.(vkField_vk.Buffer); bufferOk {
		vkField_vk.cmd_download_from_buffer(commandBuffer, resources.responseBuffer.main, buffer)
		downloadBuffer = buffer
	} else {
		downloadBuffer = resources.responseBuffer.main
	}

	vkField_vk.cmd_end(commandBuffer) or_return

	vkField_vk.queue_submit(simulator.queue, {commandBuffer}, {}, {}, simulator.computeFence) or_return

	check(vk.WaitForFences(device.device, 1, &simulator.computeFence, true, auto_cast time.duration_nanoseconds(auto_cast DISPATCH_TIMEOUT))) or_return
	vkField_vk.read_from_buffer(downloadBuffer, slice.to_bytes(response))
	vk.DeviceWaitIdle(device.device) or_return
	return
}

device_buffer :: proc(device: vkField_vk.Device, size: vk.DeviceSize) -> (buffer: vkField_vk.Buffer, result: vk.Result) {
	buffer = vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER}) or_return
	memoryType, memoryTypeOk := vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer))
	if !memoryTypeOk {
		vkField_vk.destroy_buffer(device, buffer)
		buffer = vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer));
		   !memoryTypeOk {
			return {}, .ERROR_OUT_OF_HOST_MEMORY
		}
	}
	vkField_vk.bind_buffer_to_dedicated_memory(device, &buffer, memoryType) or_return
	return
}

device_buffers :: proc(
	device: vkField_vk.Device,
	sizes: []vk.DeviceSize,
	alignment: vk.DeviceSize = 1,
) -> (
	memory: vkField_vk.Memory,
	buffers: []vkField_vk.Buffer,
	result: vk.Result,
) {
	totalSize: vk.DeviceSize
	offsets := make([]vk.DeviceSize, len(sizes), context.temp_allocator)
	for index in 0 ..< len(sizes) {
		offsets[index] = auto_cast runtime.align_forward(cast(uint)totalSize, cast(uint)alignment)
		totalSize = offsets[index] + sizes[index]
	}
	{
		buffer := vkField_vk.create_buffer(device, totalSize, {.STORAGE_BUFFER}) or_return
		memoryType, memoryTypeOk := vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer))
		if !memoryTypeOk {
			vkField_vk.destroy_buffer(device, buffer)
			buffer = vkField_vk.create_buffer(device, totalSize, {.STORAGE_BUFFER}) or_return
			if memoryType, memoryTypeOk = vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer));
			   !memoryTypeOk {
				return {}, {}, .ERROR_OUT_OF_HOST_MEMORY
			}
		}
		vkField_vk.destroy_buffer(device, buffer)
		memory = vkField_vk.allocate_memory(device, memoryType, totalSize) or_return
	}
	buffers = make([]vkField_vk.Buffer, len(sizes))
	for &buffer, index in buffers {
		buffer = vkField_vk.create_buffer(device, sizes[index], {.STORAGE_BUFFER}) or_return
		vkField_vk.bind(device, &buffer, memory, offsets[index]) or_return
	}
	return
}

prepare_stream :: proc(device: vkField_vk.Device, size: vk.DeviceSize) -> (buffer: vkStagableBuffer, result: vk.Result) {
	buffer.main = vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER}) or_return
	memoryType, memoryTypeOk := vkField_vk.find_streaming_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer.main))
	if !memoryTypeOk {
		vkField_vk.destroy_buffer(device, buffer.main)
		buffer.main = vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER, .TRANSFER_DST}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer.main));
		   !memoryTypeOk {
			return {}, .ERROR_OUT_OF_HOST_MEMORY
		}
	}
	vkField_vk.bind_buffer_to_dedicated_memory(device, &buffer.main, memoryType) or_return

	if !vkField_vk.is_mapped(buffer.main) {
		stagingBuffer := vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_staging_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, stagingBuffer));
		   !memoryTypeOk {
			return {}, .ERROR_OUT_OF_HOST_MEMORY
		}
		vkField_vk.bind_buffer_to_dedicated_memory(device, &stagingBuffer, memoryType) or_return
		buffer.staging = stagingBuffer
	}
	return
}

prepare_readback :: proc(device: vkField_vk.Device, size: vk.DeviceSize) -> (buffer: vkStagableBuffer, result: vk.Result) {
	buffer.main = vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER, .TRANSFER_DST}) or_return
	memoryType, memoryTypeOk := vkField_vk.find_streaming_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer.main))
	if !memoryTypeOk {
		vkField_vk.destroy_buffer(device, buffer.main)
		buffer.main = vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer.main));
		   !memoryTypeOk {
			return {}, .ERROR_OUT_OF_HOST_MEMORY
		}
	}
	vkField_vk.bind_buffer_to_dedicated_memory(device, &buffer.main, memoryType) or_return

	if !vkField_vk.is_mapped(buffer.main) {
		readbackBuffer := vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_readback_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, readbackBuffer));
		   !memoryTypeOk {
			return {}, .ERROR_OUT_OF_HOST_MEMORY
		}
		vkField_vk.bind_buffer_to_dedicated_memory(device, &readbackBuffer, memoryType) or_return
		buffer.staging = readbackBuffer
	}
	return
}

vkPackElementBuffer :: proc(transmitElements: #soa[]RectangularElement, receiveElements: #soa[]RectangularElement) -> []byte {
	elementTotalSize := vkElementBufferSize(len(transmitElements), len(receiveElements))
	elementCount: int = len(transmitElements) + len(receiveElements)
	rectangularElements := make([]byte, elementTotalSize)
	elementBuffer := rectangularElements
	positions: [][3]f32; normals: [][3]f32; sizes: [][2]f32; apodizations: []f32; delays: []f32
	elementBuffer, positions = seperateSoaBuffer(elementBuffer, elementCount, [3]f32)
	elementBuffer, normals = seperateSoaBuffer(elementBuffer, elementCount, [3]f32)
	elementBuffer, sizes = seperateSoaBuffer(elementBuffer, elementCount, [2]f32)
	elementBuffer, apodizations = seperateSoaBuffer(elementBuffer, elementCount, f32)
	elementBuffer, delays = seperateSoaBuffer(elementBuffer, elementCount, f32)
	assert(len(elementBuffer) == 0)

	seperateSoaBuffer :: proc(buffer: []byte, elementCount: int, $T: typeid) -> (mainBuffer: []byte, splitBuffer: []T) {
		tempSplitBuffer: []byte
		tempSplitBuffer, mainBuffer = slice.split_at(buffer, size_of(T) * elementCount)
		splitBuffer = slice.reinterpret([]T, tempSplitBuffer)
		return
	}

	mem.copy_non_overlapping(raw_data(positions), transmitElements.position, slice.size(positions))
	mem.copy_non_overlapping(raw_data(positions[len(transmitElements):]), receiveElements.position, slice.size(positions[len(transmitElements):]))
	mem.copy_non_overlapping(raw_data(normals), transmitElements.normal, slice.size(normals))
	mem.copy_non_overlapping(raw_data(normals[len(transmitElements):]), receiveElements.normal, slice.size(normals[len(transmitElements):]))
	mem.copy_non_overlapping(raw_data(sizes), transmitElements.size, slice.size(sizes))
	mem.copy_non_overlapping(raw_data(sizes[len(transmitElements):]), receiveElements.size, slice.size(sizes[len(transmitElements):]))
	mem.copy_non_overlapping(raw_data(apodizations), transmitElements.apodization, slice.size(apodizations))
	mem.copy_non_overlapping(raw_data(apodizations[len(transmitElements):]), receiveElements.apodization, slice.size(apodizations[len(transmitElements):]))
	mem.copy_non_overlapping(raw_data(delays), transmitElements.delay, slice.size(delays))
	mem.copy_non_overlapping(raw_data(delays[len(transmitElements):]), receiveElements.delay, slice.size(delays[len(transmitElements):]))

	return rectangularElements
}

vkElementBufferSize :: proc(transmitCount, receiveCount: int) -> vk.DeviceSize {
	elementTotalSize: vk.DeviceSize
	elementTotalSize += size_of([3]f32) // Position
	elementTotalSize += size_of([3]f32) // Normals
	elementTotalSize += size_of([2]f32) // Sizes
	elementTotalSize += size_of(f32) // Apodizations
	elementTotalSize += size_of(f32) // Delays
	elementTotalSize *= auto_cast (transmitCount + receiveCount)
	return elementTotalSize
}

calculate_vk_data_buffer_offsets :: proc(
	elementCount, scattererCount, transmissionCount, receiveChannelCount, apertureSampleCount: u32,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
) -> (
	header: vkDataBufferHeader,
) {
	header.totalSize = size_of(vkDataBufferHeader)
	header.elementPositions = header.totalSize
	header.totalSize += elementCount * size_of([3]f32)
	header.elementNormals = header.totalSize
	header.totalSize += elementCount * size_of([3]f32)
	header.elementSizes = header.totalSize
	header.totalSize += elementCount * size_of([2]f32)
	header.elementApodizations = header.totalSize
	header.totalSize += elementCount * size_of(f32)
	header.elementDelays = header.totalSize
	header.totalSize += elementCount * size_of(f32)
	header.scatterers = header.totalSize
	header.totalSize += scattererCount * size_of(Scatter)
	header.apertureResponseRects = header.totalSize
	header.totalSize += elementCount * scattererCount * size_of([4]f32)
	header.apertureResponseScales = header.totalSize
	header.totalSize += elementCount * scattererCount * size_of(f32)
	header.transmissionInfos = header.totalSize
	header.totalSize += transmissionCount * scattererCount * size_of(SampleRange)
	header.receiveChannelInfos = header.totalSize
	header.totalSize += receiveChannelCount * scattererCount * size_of(SampleRange)
	header.transmissionResponses = header.totalSize
	header.totalSize += transmissionCount * scattererCount * apertureSampleCount * size_of(f32)
	header.receiveChannelResponses = header.totalSize
	header.totalSize += receiveChannelCount * scattererCount * apertureSampleCount * size_of(f32)
	header.transmissionElementCounts = header.totalSize
	header.totalSize += transmissionCount * size_of(u32)
	header.transmissionBaseOffsets = header.totalSize
	header.totalSize += transmissionCount * size_of(u32)
	header.receiveChannelElementCounts = header.totalSize
	header.totalSize += receiveChannelCount * size_of(u32)
	header.receiveChannelBaseOffsets = header.totalSize
	header.totalSize += receiveChannelCount * size_of(u32)

	memberCount: u32 = 0
	for transmission in transmissions do memberCount += auto_cast len(transmission.elements)
	for receiveChannel in receiveChannels do memberCount += auto_cast len(receiveChannel.elements)
	header.elementSetMembers = header.totalSize
	header.totalSize += memberCount * 3 * size_of(u32)
	return
}

vkBuildDataBuffer :: proc(
	simulator: ^vkSimulator,
	settings: SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatterers: []Scatter,
	allocator := context.allocator,
) -> (
	dataBuffer: []byte,
	header: vkDataBufferHeader,
) {
	elementCount: u32 = auto_cast len(elements)
	scattererCount := simulator.info.scattererBatchSize
	transmissionCount: u32 = auto_cast len(transmissions)
	receiveChannelCount: u32 = auto_cast len(receiveChannels)
	apertureSampleCount: u32 = simulator.info.apertureSampleCount

	header = calculate_vk_data_buffer_offsets(
		elementCount,
		scattererCount,
		transmissionCount,
		receiveChannelCount,
		apertureSampleCount,
		transmissions,
		receiveChannels,
	)
	dataBuffer = make([]byte, header.totalSize, allocator)

	(cast(^vkDataBufferHeader)raw_data(dataBuffer))^ = header

	copy(slice.from_ptr(cast(^[3]f32)raw_data(dataBuffer[header.elementPositions:]), len(elements)), slice.from_ptr(elements.position, len(elements)))
	copy(slice.from_ptr(cast(^[3]f32)raw_data(dataBuffer[header.elementNormals:]), len(elements)), slice.from_ptr(elements.normal, len(elements)))
	copy(slice.from_ptr(cast(^[2]f32)raw_data(dataBuffer[header.elementSizes:]), len(elements)), slice.from_ptr(elements.size, len(elements)))
	copy(slice.from_ptr(cast(^f32)raw_data(dataBuffer[header.elementApodizations:]), len(elements)), slice.from_ptr(elements.apodization, len(elements)))
	copy(slice.from_ptr(cast(^f32)raw_data(dataBuffer[header.elementDelays:]), len(elements)), slice.from_ptr(elements.delay, len(elements)))
	copy(slice.from_ptr(cast(^Scatter)raw_data(dataBuffer[header.scatterers:]), len(scatterers)), scatterers)
	memberSetBaseOffset: u32 = 0

	transmissionsElementCounts := slice.from_ptr(cast(^u32)raw_data(dataBuffer[header.transmissionElementCounts:]), auto_cast transmissionCount)
	transmissionsBaseOffsets := slice.from_ptr(cast(^u32)raw_data(dataBuffer[header.transmissionBaseOffsets:]), auto_cast transmissionCount)

	totalWordCount := int((header.totalSize - header.elementSetMembers) / size_of(u32))
	elementSetMemberWords := slice.from_ptr(cast(^u32)raw_data(dataBuffer[header.elementSetMembers:]), totalWordCount)
	wordIndex := 0

	for transmission, index in transmissions {
		memberCount := len(transmission.elements)
		transmissionsElementCounts[index] = auto_cast memberCount
		transmissionsBaseOffsets[index] = memberSetBaseOffset

		copy(slice.reinterpret([]i32, elementSetMemberWords[wordIndex:]), slice.from_ptr(transmission.elements.index, memberCount))
		wordIndex += memberCount

		copy(slice.reinterpret([]f32, elementSetMemberWords[wordIndex:]), slice.from_ptr(transmission.elements.apodization, memberCount))
		wordIndex += memberCount

		copy(slice.reinterpret([]f32, elementSetMemberWords[wordIndex:]), slice.from_ptr(transmission.elements.delay, memberCount))
		wordIndex += memberCount

		memberSetBaseOffset += auto_cast (3 * memberCount)
	}

	receiveChannelsElementCounts := slice.from_ptr(cast(^u32)raw_data(dataBuffer[header.receiveChannelElementCounts:]), auto_cast receiveChannelCount)
	receiveChannelsBaseOffsets := slice.from_ptr(cast(^u32)raw_data(dataBuffer[header.receiveChannelBaseOffsets:]), auto_cast receiveChannelCount)

	for receiveChannel, index in receiveChannels {
		memberCount := len(receiveChannel.elements)
		receiveChannelsElementCounts[index] = auto_cast memberCount
		receiveChannelsBaseOffsets[index] = memberSetBaseOffset

		copy(slice.reinterpret([]i32, elementSetMemberWords[wordIndex:]), slice.from_ptr(receiveChannel.elements.index, memberCount))
		wordIndex += memberCount

		copy(slice.reinterpret([]f32, elementSetMemberWords[wordIndex:]), slice.from_ptr(receiveChannel.elements.apodization, memberCount))
		wordIndex += memberCount

		copy(slice.reinterpret([]f32, elementSetMemberWords[wordIndex:]), slice.from_ptr(receiveChannel.elements.delay, memberCount))
		wordIndex += memberCount

		memberSetBaseOffset += auto_cast (3 * memberCount)
	}

	return
}
