package vkfield

import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
import "core:time"
import rdoc "import:renderdoc"
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
SCATTER_UPLOAD_WINDOW_SIZE :: 16 * runtime.Megabyte
SCATTER_BATCHES_PER_COMMAND_BUFFER :: 2
GPU_CALC_ELEMENT_CHUNK_SIZE :: 256
GPU_ELEMENT_SET_CHUNK_SIZE :: 1024
GPU_APERTURE_SAMPLE_CHUNK_SIZE :: 65536
GPU_CONVOLUTION_SAMPLE_CHUNK_SIZE :: 1024
VULKAN_PROGRESS_LOG_DELAY_THRESHOLD :: 20.0 * time.Second
VULKAN_PROGRESS_LOG_INTERVAL :: 20.0 * time.Second

DISPATCH_TIMEOUT :: 1000 * time.Second

SHADER_COMPUTE_CALCULATE_APERTURE :: #load("shaders/calculateAperture.spv")
SHADER_COMPUTE_MEASURE_APERTURE :: #load("shaders/measureAperture.spv")
SHADER_COMPUTE_COALESCE_APERTURE :: #load("shaders/coalesceAperture.spv")
SHADER_COMPUTE_PULSE_ECHO_CONVOLVE :: #load("shaders/pulseEchoConvolution.spv")
SHADER_COMPUTE_TEMPORAL_RESPONSE :: #load("shaders/temporalResponse.spv")

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
	rdocLib:               dynlib.Library,
	rdocApi:               rdoc.Api,
	info:                  vkSimulationInfo,
	instance:              vkField_vk.Instance,
	debugUserData:         ^vkField_vk.DebugUserData,
	debugMessenger:        vkField_vk.DebugMessenger,
	physicalDevices:       #soa[]vkField_vk.PhysicalDevice,
	device:                vkField_vk.Device,
	queue:                 vkField_vk.Queue,
	transferQueue:         Maybe(vkField_vk.Queue),
	pipelineLayout:        vk.PipelineLayout,
	simulationResources:   vkSimulationResources,
	computeCommandPool:    vkField_vk.CommandPool,
	transferCommandPool:   vkField_vk.CommandPool,
	computeTimeline:       vkField_vk.TimelineSemaphore,
	transferTimeline:      vkField_vk.TimelineSemaphore,
	computeTimelineValue:  u64,
	transferTimelineValue: u64,
}

vkSimulationInfo :: struct {
	apertureSampleCount: u32,
	scattererBatchSize:  u32,
}

vkSimulationResources :: union {
	vkPulseEchoSimulationResources,
}

vkPulseEchoSimulationResources :: struct {
	dataBuffer:           vkStagableBuffer,
	scatterBuffers:       [dynamic; MAX_FRAMES_IN_FLIGHT]vkField_vk.Buffer,
	dataBufferHeader:     vkDataBufferHeader,
	responseBuffer:       vkStagableBuffer,
	temporalBuffer:       vkStagableBuffer,
	temporalOutputBuffer: vkField_vk.Buffer,
	calcAperShader:       vk.ShaderEXT,
	measAperShaderTx:     vk.ShaderEXT,
	measAperShaderRcv:    vk.ShaderEXT,
	coalAperShaderTx:     vk.ShaderEXT,
	coalAperShaderRcv:    vk.ShaderEXT,
	pulseConvShader:      vk.ShaderEXT,
	temporalShader:       vk.ShaderEXT,
	calcAperSpec:         vkCalcAperSpecConstants,
	measAperSpecTx:       vkMeasAperSpecConstants,
	measAperSpecRcv:      vkMeasAperSpecConstants,
	coalAperSpecTx:       vkCoalAperSpecConstants,
	coalAperSpecRcv:      vkCoalAperSpecConstants,
	pulseConvSpec:        vkPulseConvSpecConstants,
	temporalSpec:         vkTemporalSpecConstants,
	maxImpulseLength:     u32,
	maxExcitationLength:  u32,
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
	ConvolutionTileSize: u32,
}

vkTemporalSpecConstants :: struct {
	using general:       vkGeneralSpecContants,
	SampleWorkgroupSize: u32,
	MaxImpulseLength:    u32,
	MaxExcitationLength: u32,
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
	sampleOffset:               u32,
	scattererOffset:           u32,
}

vkPulseConvPushData :: struct {
	transmissionInfos:     vk.DeviceAddress,
	transmissionResponses: vk.DeviceAddress,
	response:              vk.DeviceAddress,
	transmissionIndex:     u32,
	receiveChannelIndex:   u32,
	sampleOffset:          u32,
	scattererOffset:       u32,
}

vkTemporalPushData :: struct {
	response:            vk.DeviceAddress,
	temporalOutput:      vk.DeviceAddress,
	temporalResponses:   vk.DeviceAddress,
	lineIndex:           u32,
	impulseIndex:        u32,
	excitationIndex:     u32,
	receiveImpulseIndex: u32,
	impulseLibraryCount: u32,
	impulseCount:        u32,
	excitationCount:     u32,
	receiveImpulseCount: u32,
	sampleOffset:       u32,
	sampleInterval:      f32,
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
	when ENABLE_RENDERDOC {
		simulator.rdocLib, simulator.rdocApi, _ = rdoc.load_api()
		if simulator.rdocApi != nil do log.infof("loaded renderdoc %v", simulator.rdocApi)
	}

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
		.TimelineSemaphore,
	}
	physicalDevice, physicalDeviceAvailable := vkField_vk.pick_physical_device(
		simulator.instance.instance,
		simulator.physicalDevices,
		{requiredCapabilities = requiredCapabilities},
	)
	if !physicalDeviceAvailable do return simulator, vk.Result.ERROR_DEVICE_LOST
	hasDedicatedTransferQueue := false
	for queueFamily in physicalDevice.queueFamilies {
		if .Transfer in queueFamily.properties && .Compute not_in queueFamily.properties {
			hasDedicatedTransferQueue = true
			break
		}
	}
	queueRequests := make([dynamic]vkField_vk.QueueRequest, context.temp_allocator)
	append(
		&queueRequests,
		vkField_vk.QueueRequest{count = 1, requiredProperties = {.Compute}, preferredProperties = {.Compute}, unpreferredProperties = {.Transfer}},
	)
	if hasDedicatedTransferQueue {
		append(
			&queueRequests,
			vkField_vk.QueueRequest{count = 1, requiredProperties = {.Transfer}, preferredProperties = {.Transfer}, unpreferredProperties = {.Compute}},
		)
	}
	queues: [][]vkField_vk.Queue
	simulator.device, queues = check(
		vkField_vk.create_device(
			simulator.instance,
			physicalDevice,
			{requiredCapabilities = requiredCapabilities},
			queueRequests[:],
			"Main Device",
			context.temp_allocator,
		),
	) or_return

	pushConstantSize := max(size_of(vkCalcAperPushData), size_of(vkCoalescePushData), size_of(vkPulseConvPushData), size_of(vkTemporalPushData))
	simulator.pipelineLayout = check(
		vkField_vk.create_pipeline_layout(simulator.device, {}, {{stageFlags = {.COMPUTE}, size = auto_cast pushConstantSize, offset = 0}}),
	) or_return
	simulator.queue = queues[0][0]
	if hasDedicatedTransferQueue {
		transferQueue := queues[1][0]
		if simulator.queue.familyIndex != transferQueue.familyIndex {
			simulator.transferQueue = transferQueue
		}
	}

	simulator.computeCommandPool = check(vkField_vk.create_command_pool(simulator.device, simulator.queue, true)) or_return
	if transferQueue, transferQueueOk := simulator.transferQueue.?; transferQueueOk {
		simulator.transferCommandPool = check(vkField_vk.create_command_pool(simulator.device, transferQueue, true)) or_return
	}
	simulator.computeTimeline = check(vkField_vk.create_timeline_semaphore(simulator.device, label = "Compute Timeline")) or_return
	if _, transferQueueOk := simulator.transferQueue.?; transferQueueOk {
		simulator.transferTimeline = check(vkField_vk.create_timeline_semaphore(simulator.device, label = "Transfer Timeline")) or_return
	}

	return
}

destroy_vulkan_simulator :: proc(simulator: ^vkSimulator) {
	when ENABLE_RENDERDOC {
		if simulator.rdocApi != nil {
			if rdoc.is_frame_capturing(simulator.rdocApi) {
				captureOk := rdoc.end_frame_capture(simulator.rdocApi, nil, nil)
				if !captureOk do log.error("renderdoc: EndFrameCapture failed during simulator destruction")
			}
			vk.DeviceWaitIdle(simulator.device.device)
			rdoc.unload_api(simulator.rdocLib)
		}
	}

	destroy_vulkan_simulator_resources(simulator)

	vkField_vk.destroy_timeline_semaphore(simulator.device, simulator.computeTimeline)
	if _, transferQueueOk := simulator.transferQueue.?; transferQueueOk {
		vkField_vk.destroy_timeline_semaphore(simulator.device, simulator.transferTimeline)
		vkField_vk.destroy_command_pool(simulator.device, simulator.transferCommandPool)
	}
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
	impulses: []TransducerImpulse,
	excitations: []Excitation,
) -> (
	result: vk.Result,
) {
	destroy_vulkan_simulator_resources(simulator)

	limits := simulator.device.physicalDevice.properties.limits
	maxComputeSharedMemorySize := limits.maxComputeSharedMemorySize
	pulseConvSampleWorkgroupSize: u32 = PULSE_CONV_SAMPLE_WORKGROUP_SIZE
	pulseConvTileSize: u32 = PULSE_CONVOLUTION_TILE_SIZE
	pulseEchoSharedMemory := (pulseConvTileSize + pulseConvTileSize + pulseConvSampleWorkgroupSize - 1) * size_of(f32)
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
	maxBatchFromBuffer: u32 = targetBatchSize
	if fixedHeaderBytes < maxBufferLimit && bytesPerScatterer > 0 {
		maxBatchFromBuffer = (maxBufferLimit - fixedHeaderBytes) / bytesPerScatterer
		simulator.info.scattererBatchSize = max(u32(1), min(targetBatchSize, maxBatchFromBuffer))
	} else {
		simulator.info.scattererBatchSize = targetBatchSize
	}

	log.infof(
		"Vulkan scatter batch plan: scatters=%d, elements=%d, transmissions=%d, receiveChannels=%d, apertureSamples=%d, " +
			"sharedMemory=%d/%d bytes, fixedBuffer=%d bytes, bytesPerScatterer=%d, bufferLimit=%d bytes, " +
			"physicalStorageLimit=%d bytes, dispatchWorkLimit=%d bytes, bufferBatchLimit=%d, targetBatch=%d, finalBatch=%d",
		scatterCount,
		elementCount,
		transmissionCount,
		receiveChannelCount,
		apertureSampleCount,
		pulseEchoSharedMemory,
		maxComputeSharedMemorySize,
		fixedHeaderBytes,
		bytesPerScatterer,
		maxBufferLimit,
		maxStorageBufferRange,
		settings.gpuSettings.dispatchWorkLimit,
		maxBatchFromBuffer,
		targetBatchSize,
		simulator.info.scattererBatchSize,
	)

	dataBufferHeader := calculate_vk_data_buffer_offsets(
		elementCount,
		simulator.info.scattererBatchSize,
		transmissionCount,
		receiveChannelCount,
		apertureSampleCount,
		transmissions,
		receiveChannels,
	)

	device := simulator.device
	transferQueue, hasTransferQueue := simulator.transferQueue.?
	sharedQueueFamilyIndices: []u32
	if hasTransferQueue {
		sharedQueueFamilyIndices = {simulator.queue.familyIndex, transferQueue.familyIndex}
	}

	vkDataBuffer := check(prepare_stream(device, auto_cast dataBufferHeader.totalSize, sharedQueueFamilyIndices)) or_return
	scatterBufferSize := max(size_of(Scatter), min(int(SCATTER_UPLOAD_WINDOW_SIZE), max(1, len(scatters) * size_of(Scatter))))
	scatterUploadCapacity := max(1, scatterBufferSize / size_of(Scatter))
	scatterBufferCount := min(MAX_FRAMES_IN_FLIGHT, max(1, (len(scatters) + scatterUploadCapacity - 1) / scatterUploadCapacity))
	scatterBuffers: [dynamic; MAX_FRAMES_IN_FLIGHT]vkField_vk.Buffer
	for _ in 0 ..< scatterBufferCount {
		scatterBuffer := check(prepare_scatter_buffer(device, auto_cast scatterBufferSize)) or_return
		append(&scatterBuffers, scatterBuffer)
	}
	responseBuffer := check(
		prepare_readback(device, auto_cast (len(transmissions) * len(receiveChannels) * int(settings.sampleCount)) * size_of(f32)),
	) or_return
	maxImpulseLength: u32 = 1
	for response in impulses do maxImpulseLength = max(maxImpulseLength, cast(u32)len(response))
	maxExcitationLength: u32 = 1
	for response in excitations do maxExcitationLength = max(maxExcitationLength, cast(u32)len(response))
	temporalSharedMemory := (2 * maxImpulseLength + maxExcitationLength) * size_of(f32)
	assert(temporalSharedMemory <= maxComputeSharedMemorySize, "Temporal response shared memory exceeds device maxComputeSharedMemorySize")
	temporalBufferSize := max(1, (len(impulses) * int(maxImpulseLength) + len(excitations) * int(maxExcitationLength)) * size_of(f32))
	temporalBuffer := check(prepare_stream(device, auto_cast temporalBufferSize, sharedQueueFamilyIndices)) or_return
	temporalOutputBuffer := check(
		prepare_temporal_output_buffer(device, auto_cast (len(transmissions) * len(receiveChannels) * int(settings.sampleCount) * size_of(f32))),
	) or_return

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
		SampleWorkgroupSize = pulseConvSampleWorkgroupSize,
		ConvolutionTileSize = pulseConvTileSize,
	}
	temporalSpec: vkTemporalSpecConstants = {
		general             = generalSpec,
		SampleWorkgroupSize = 64,
		MaxImpulseLength    = maxImpulseLength,
		MaxExcitationLength = maxExcitationLength,
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
	temporalShaders, _ := vkField_vk.create_shaders(
		device,
		{
			code = SHADER_COMPUTE_TEMPORAL_RESPONSE,
			entryPoints = {{name = "main", stage = .COMPUTE}},
			specializationInfo = {vkField_vk.create_specialization_info(temporalSpec)},
		},
		{},
		{{stageFlags = {.COMPUTE}, size = size_of(vkTemporalPushData)}},
		false,
		"Temporal Response",
		context.temp_allocator,
	) or_return

	simulator.simulationResources = vkPulseEchoSimulationResources {
		dataBuffer           = vkDataBuffer,
		scatterBuffers       = scatterBuffers,
		dataBufferHeader     = dataBufferHeader,
		responseBuffer       = responseBuffer,
		temporalBuffer       = temporalBuffer,
		temporalOutputBuffer = temporalOutputBuffer,
		calcAperShader       = calcAperShaders[0],
		measAperShaderTx     = measAperShaders[0],
		measAperShaderRcv    = measAperShaders[1],
		coalAperShaderTx     = coalAperShaders[0],
		coalAperShaderRcv    = coalAperShaders[1],
		pulseConvShader      = pulseConvShaders[0],
		temporalShader       = temporalShaders[0],
		calcAperSpec         = calcAperSpec,
		measAperSpecTx       = measAperSpecTx,
		measAperSpecRcv      = measAperSpecRcv,
		coalAperSpecTx       = coalAperSpecTx,
		coalAperSpecRcv      = coalAperSpecRcv,
		pulseConvSpec        = pulseConvSpec,
		temporalSpec         = temporalSpec,
		maxImpulseLength     = maxImpulseLength,
		maxExcitationLength  = maxExcitationLength,
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
		vkField_vk.destroy_shader(device, resources.temporalShader)
		release_staged_buffer(device, resources.dataBuffer)
		for scatterBuffer in resources.scatterBuffers {
			vkField_vk.release_buffer(device, scatterBuffer)
		}
		release_staged_buffer(device, resources.responseBuffer)
		release_staged_buffer(device, resources.temporalBuffer)
		vkField_vk.release_buffer(device, resources.temporalOutputBuffer)
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
	impulses: []TransducerImpulse,
	excitations: []Excitation,
	allocator := context.allocator,
) -> (
	response: []f32,
	result: vk.Result,
) {
	resources, pulseEchoResourcesOk := simulator.simulationResources.(vkPulseEchoSimulationResources)
	if !check(pulseEchoResourcesOk) do return {}, .ERROR_INITIALIZATION_FAILED

	device := simulator.device
	transferQueue, hasTransferQueue := simulator.transferQueue.?

	response = make([]f32, resources.responseBuffer.main.size / size_of(f32), allocator)

	commandBuffer := check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return

	initialDataBuffer := vkBuildDataBuffer(resources.dataBufferHeader, transmissions, receiveChannels, elements, context.temp_allocator)
	initialTemporalBuffer := vkBuildTemporalResponseBuffer(
		impulses,
		excitations,
		resources.maxImpulseLength,
		resources.maxExcitationLength,
		context.temp_allocator,
	)

	if hasTransferQueue {
		transferCommandBuffer := check(vkField_vk.get_command_buffer(device, &simulator.transferCommandPool)) or_return
		vkField_vk.cmd_begin(transferCommandBuffer, true) or_return
		vkField_vk.cmd_upload(transferCommandBuffer, initialDataBuffer, resources.dataBuffer.main, resources.dataBuffer.staging.? or_else {})
		vkField_vk.cmd_upload(transferCommandBuffer, initialTemporalBuffer, resources.temporalBuffer.main, resources.temporalBuffer.staging.? or_else {})
		vkField_vk.cmd_end(transferCommandBuffer) or_return
		simulator.transferTimelineValue += 1
		vkField_vk.queue_submit(
			transferQueue,
			{transferCommandBuffer},
			{},
			{{semaphore = simulator.transferTimeline, value = simulator.transferTimelineValue, stageMask = {.TRANSFER}}},
		) or_return
	}

	vkField_vk.cmd_begin(commandBuffer, true) or_return
	vkField_vk.cmd_clear_buffer(commandBuffer, resources.responseBuffer.main)
	if !hasTransferQueue {
		vkField_vk.cmd_upload(commandBuffer, initialDataBuffer, resources.dataBuffer.main, resources.dataBuffer.staging.? or_else {})
		vkField_vk.cmd_upload(commandBuffer, initialTemporalBuffer, resources.temporalBuffer.main, resources.temporalBuffer.staging.? or_else {})
	}
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
			{
				buffer = resources.dataBuffer.main.buffer,
				size = resources.dataBuffer.main.size,
				offset = 0,
				srcStageMask = {.TRANSFER},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
			},
			{
				buffer = resources.temporalBuffer.main.buffer,
				size = resources.temporalBuffer.main.size,
				offset = 0,
				srcStageMask = {.TRANSFER},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ},
			},
		},
		{},
	)
	vkField_vk.cmd_end(commandBuffer) or_return
	computeWaits: []vkField_vk.SemaphoreBarrier
	if hasTransferQueue {
		computeWaits = {{semaphore = simulator.transferTimeline, value = simulator.transferTimelineValue, stageMask = {.COMPUTE_SHADER}}}
	}
	simulator.computeTimelineValue += 1
	vkField_vk.queue_submit(
		simulator.queue,
		{commandBuffer},
		computeWaits,
		{{semaphore = simulator.computeTimeline, value = simulator.computeTimelineValue, stageMask = {.ALL_COMMANDS}}},
	) or_return
	timelineWait := make(#soa[]vkField_vk.WaitSemaphore, 1, context.temp_allocator)
	timelineWait.sempahore[0] = auto_cast simulator.computeTimeline
	timelineWait.value[0] = simulator.computeTimelineValue
	check(vkField_vk.wait_semaphores(device, timelineWait, auto_cast time.duration_nanoseconds(auto_cast DISPATCH_TIMEOUT))) or_return
	vkField_vk.reset_command_pool(device, &simulator.computeCommandPool) or_return
	if hasTransferQueue {
		vkField_vk.reset_command_pool(device, &simulator.transferCommandPool) or_return
	}
	commandBuffer = check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return

	shaderStage: vk.ShaderStageFlags = {.COMPUTE}

	scatterBatchSize := simulator.info.scattererBatchSize
	dataBufferAddress := vkField_vk.get_buffer_address(device, resources.dataBuffer.main)
	header := resources.dataBufferHeader
	scatterUploadCapacity := int(resources.scatterBuffers[0].size / auto_cast size_of(Scatter))
	scatterWindowBatchCount := max(1, scatterUploadCapacity / int(scatterBatchSize))
	scatterWindowSize := scatterWindowBatchCount * int(scatterBatchSize)
	totalScatterCommands := 0
	for progressWindowOffset := 0; progressWindowOffset < len(scatters); progressWindowOffset += scatterWindowSize {
		progressWindowEnd := min(progressWindowOffset + scatterWindowSize, len(scatters))
		progressWindowBatchCount := (progressWindowEnd - progressWindowOffset + int(scatterBatchSize) - 1) / int(scatterBatchSize)
		totalScatterCommands += (progressWindowBatchCount + SCATTER_BATCHES_PER_COMMAND_BUFFER - 1) / SCATTER_BATCHES_PER_COMMAND_BUFFER
	}
	totalScatterCommands = max(1, totalScatterCommands)
	scatterComputeStartValue := simulator.computeTimelineValue
	progressStopwatch: time.Stopwatch
	time.stopwatch_start(&progressStopwatch)
	lastProgressLogTime: time.Duration
	scatterData := slice.to_bytes(scatters)
	for windowOffset := 0; windowOffset < len(scatters); windowOffset += scatterWindowSize {
		windowEnd := min(windowOffset + scatterWindowSize, len(scatters))
		windowBatchCount := (windowEnd - windowOffset + int(scatterBatchSize) - 1) / int(scatterBatchSize)
		commandBufferCount := (windowBatchCount + SCATTER_BATCHES_PER_COMMAND_BUFFER - 1) / SCATTER_BATCHES_PER_COMMAND_BUFFER
		computeCommandBuffers := check(
			vkField_vk.get_command_buffers(device, &simulator.computeCommandPool, commandBufferCount, allocator = context.temp_allocator),
		) or_return
		transferCommandBuffers: []vkField_vk.CommandBuffer
		if hasTransferQueue {
			transferCommandBuffers = check(
				vkField_vk.get_command_buffers(device, &simulator.transferCommandPool, commandBufferCount, allocator = context.temp_allocator),
			) or_return
		}
		slotComputeTimelineValues: [MAX_FRAMES_IN_FLIGHT]u64
		for computeCommandBuffer, commandBufferIndex in computeCommandBuffers {
			commandStart := windowOffset + commandBufferIndex * SCATTER_BATCHES_PER_COMMAND_BUFFER * int(scatterBatchSize)
			commandEnd := min(commandStart + SCATTER_BATCHES_PER_COMMAND_BUFFER * int(scatterBatchSize), windowEnd)
			ringIndex := commandBufferIndex % len(resources.scatterBuffers)
			if slotComputeTimelineValues[ringIndex] > 0 {
				timelineWait.value[0] = slotComputeTimelineValues[ringIndex]
				check(vkField_vk.wait_semaphores(device, timelineWait, auto_cast time.duration_nanoseconds(auto_cast DISPATCH_TIMEOUT))) or_return
			}
			scatterBuffer := resources.scatterBuffers[ringIndex]
			windowData := scatterData[commandStart * size_of(Scatter):commandEnd * size_of(Scatter)]
			copy(vkField_vk.get_buffer_mapped_data(scatterBuffer)[:len(windowData)], windowData)

			if hasTransferQueue {
				transferCommandBuffer := transferCommandBuffers[commandBufferIndex]
				vkField_vk.cmd_begin(transferCommandBuffer, true) or_return
				vkField_vk.cmd_pipeline_barrier(
					transferCommandBuffer,
					{},
					{
						{
							buffer = scatterBuffer.buffer,
							size = scatterBuffer.size,
							offset = 0,
							srcStageMask = {.HOST},
							srcAccessMask = {.HOST_WRITE},
							dstStageMask = {.TRANSFER},
							dstAccessMask = {.TRANSFER_READ},
						},
					},
					{},
				)
				for transferScatterOffset := commandStart; transferScatterOffset < commandEnd; transferScatterOffset += auto_cast scatterBatchSize {
					transferScatterBatchEnd := min(transferScatterOffset + auto_cast scatterBatchSize, commandEnd)
					transferScatterUploadSize: vk.DeviceSize = auto_cast ((transferScatterBatchEnd - transferScatterOffset) * size_of(Scatter))
					vkField_vk.cmd_copy_buffer(
						transferCommandBuffer,
						scatterBuffer,
						resources.dataBuffer.main,
						{
							{
								sType = .BUFFER_COPY_2,
								srcOffset = auto_cast ((transferScatterOffset - commandStart) * size_of(Scatter)),
								dstOffset = auto_cast header.scatterers,
								size = transferScatterUploadSize,
							},
						},
					)
				}
				vkField_vk.cmd_end(transferCommandBuffer) or_return
				simulator.transferTimelineValue += 1
				vkField_vk.queue_submit(
					transferQueue,
					{transferCommandBuffer},
					{},
					{{semaphore = simulator.transferTimeline, value = simulator.transferTimelineValue, stageMask = {.TRANSFER}}},
				) or_return
			}

			commandBuffer = computeCommandBuffer
			vkField_vk.cmd_begin(commandBuffer, true) or_return
			if !hasTransferQueue {
				vkField_vk.cmd_pipeline_barrier(
					commandBuffer,
					{},
					{
						{
							buffer = scatterBuffer.buffer,
							size = scatterBuffer.size,
							offset = 0,
							srcStageMask = {.HOST},
							srcAccessMask = {.HOST_WRITE},
							dstStageMask = {.TRANSFER},
							dstAccessMask = {.TRANSFER_READ},
						},
					},
					{},
				)
			}
			if hasTransferQueue {
				vkField_vk.cmd_pipeline_barrier(
					commandBuffer,
					{},
					{
						{
							buffer = resources.dataBuffer.main.buffer,
							size = resources.dataBuffer.main.size,
							offset = 0,
							srcStageMask = {.TRANSFER},
							srcAccessMask = {.TRANSFER_WRITE},
							dstStageMask = {.COMPUTE_SHADER},
							dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
						},
					},
					{},
				)
			}

			for scatterOffset := commandStart; scatterOffset < commandEnd; scatterOffset += auto_cast scatterBatchSize {
				if scatterOffset > windowOffset && !hasTransferQueue {
					vkField_vk.cmd_pipeline_barrier(
						commandBuffer,
						{},
						{
							{
								buffer = resources.dataBuffer.main.buffer,
								size = resources.dataBuffer.main.size,
								offset = 0,
								srcStageMask = {.COMPUTE_SHADER},
								srcAccessMask = {.SHADER_READ, .SHADER_WRITE},
								dstStageMask = {.TRANSFER},
								dstAccessMask = {.TRANSFER_WRITE},
							},
						},
						{},
					)
				}

				if !hasTransferQueue {
					scatterBatchEnd := min(scatterOffset + auto_cast scatterBatchSize, len(scatters))
					scatterUploadSize: vk.DeviceSize = auto_cast ((scatterBatchEnd - scatterOffset) * size_of(Scatter))
					vkField_vk.cmd_copy_buffer(
						commandBuffer,
						scatterBuffer,
						resources.dataBuffer.main,
						{
							{
								sType = .BUFFER_COPY_2,
								srcOffset = auto_cast ((scatterOffset - commandStart) * size_of(Scatter)),
								dstOffset = auto_cast header.scatterers,
								size = scatterUploadSize,
							},
						},
					)
					vkField_vk.cmd_pipeline_barrier(
						commandBuffer,
						{},
						{
							{
								buffer = resources.dataBuffer.main.buffer,
								size = resources.dataBuffer.main.size,
								offset = 0,
								srcStageMask = {.TRANSFER},
								srcAccessMask = {.TRANSFER_WRITE},
								dstStageMask = {.COMPUTE_SHADER},
								dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
							},
						},
						{},
					)
				}

				vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.calcAperShader)
				for elementOffset := 0; elementOffset < len(elements); elementOffset += GPU_CALC_ELEMENT_CHUNK_SIZE {
					elementChunkCount := min(GPU_CALC_ELEMENT_CHUNK_SIZE, len(elements) - elementOffset)
					vkField_vk.cmd_push_constants(
						commandBuffer,
						simulator.pipelineLayout,
						shaderStage,
						vkCalcAperPushData {
							elementPositions = dataBufferAddress + auto_cast header.elementPositions,
							apertureResponseRects = dataBufferAddress + auto_cast header.apertureResponseRects,
							elementOffset = auto_cast elementOffset,
							scattererOffset = auto_cast scatterOffset,
						},
					)
					vk.CmdDispatch(
						commandBuffer.commandBuffer,
						u32(math.ceil(f32(elementChunkCount) / f32(resources.calcAperSpec.ElementWorkgroupSize))),
						u32(math.ceil(f32(scatterBatchSize) / f32(resources.calcAperSpec.ScattererWorkgroupSize))),
						1,
					)
				}

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

				vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.measAperShaderTx)
				for elementSetOffset := 0; elementSetOffset < len(transmissions); elementSetOffset += GPU_ELEMENT_SET_CHUNK_SIZE {
					elementSetChunkCount := min(GPU_ELEMENT_SET_CHUNK_SIZE, len(transmissions) - elementSetOffset)
					vkField_vk.cmd_push_constants(commandBuffer, simulator.pipelineLayout, shaderStage, vkCoalescePushData {
						apertureResponseRects = dataBufferAddress + auto_cast header.apertureResponseRects,
						transmissionInfos = dataBufferAddress + auto_cast header.transmissionInfos,
						transmissionResponses = dataBufferAddress + auto_cast header.transmissionResponses,
						transmissionElementCounts = dataBufferAddress + auto_cast header.transmissionElementCounts,
						elementSetMembers = dataBufferAddress + auto_cast header.elementSetMembers,
						elementSetOffset = auto_cast elementSetOffset,
						sampleOffset = 0,
						scattererOffset = auto_cast scatterOffset,
					})
					vk.CmdDispatch(commandBuffer.commandBuffer, u32(math.ceil(f32(elementSetChunkCount) / f32(resources.measAperSpecTx.ElementSetWorkgroupSize))), u32(math.ceil(f32(scatterBatchSize) / f32(resources.measAperSpecTx.ScattererWorkgroupSize))), 1)
				}
				vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.measAperShaderRcv)
				for elementSetOffset := 0; elementSetOffset < len(receiveChannels); elementSetOffset += GPU_ELEMENT_SET_CHUNK_SIZE {
					elementSetChunkCount := min(GPU_ELEMENT_SET_CHUNK_SIZE, len(receiveChannels) - elementSetOffset)
					vkField_vk.cmd_push_constants(commandBuffer, simulator.pipelineLayout, shaderStage, vkCoalescePushData {
						apertureResponseRects = dataBufferAddress + auto_cast header.apertureResponseRects,
						transmissionInfos = dataBufferAddress + auto_cast header.transmissionInfos,
						transmissionResponses = dataBufferAddress + auto_cast header.transmissionResponses,
						transmissionElementCounts = dataBufferAddress + auto_cast header.transmissionElementCounts,
						elementSetMembers = dataBufferAddress + auto_cast header.elementSetMembers,
						elementSetOffset = auto_cast elementSetOffset,
						sampleOffset = 0,
						scattererOffset = auto_cast scatterOffset,
					})
					vk.CmdDispatch(commandBuffer.commandBuffer, u32(math.ceil(f32(elementSetChunkCount) / f32(resources.measAperSpecRcv.ElementSetWorkgroupSize))), u32(math.ceil(f32(scatterBatchSize) / f32(resources.measAperSpecRcv.ScattererWorkgroupSize))), 1)
				}

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
				for sampleOffset: u32 = 0; sampleOffset < simulator.info.apertureSampleCount; sampleOffset += GPU_APERTURE_SAMPLE_CHUNK_SIZE {
					sampleChunkCount := min(GPU_APERTURE_SAMPLE_CHUNK_SIZE, simulator.info.apertureSampleCount - sampleOffset)
					for elementSetOffset := 0; elementSetOffset < len(transmissions); elementSetOffset += GPU_ELEMENT_SET_CHUNK_SIZE {
						elementSetChunkCount := min(GPU_ELEMENT_SET_CHUNK_SIZE, len(transmissions) - elementSetOffset)
						vkField_vk.cmd_push_constants(commandBuffer, simulator.pipelineLayout, shaderStage, vkCoalescePushData {
							apertureResponseRects = dataBufferAddress + auto_cast header.apertureResponseRects,
							transmissionInfos = dataBufferAddress + auto_cast header.transmissionInfos,
							transmissionResponses = dataBufferAddress + auto_cast header.transmissionResponses,
							transmissionElementCounts = dataBufferAddress + auto_cast header.transmissionElementCounts,
							elementSetMembers = dataBufferAddress + auto_cast header.elementSetMembers,
							elementSetOffset = auto_cast elementSetOffset,
							sampleOffset = auto_cast sampleOffset,
							scattererOffset = auto_cast scatterOffset,
						})
						vk.CmdDispatch(commandBuffer.commandBuffer, u32(math.ceil_f32(f32(sampleChunkCount) / f32(resources.coalAperSpecTx.SampleWorkgroupSize))), u32(math.ceil_f32(f32(elementSetChunkCount) / f32(resources.coalAperSpecTx.ElementSetWorkgroupSize))), u32(math.ceil_f32(f32(scatterBatchSize) / f32(resources.coalAperSpecTx.ScattererWorkgroupSize))))
					}
				}
				vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.coalAperShaderRcv)
				for sampleOffset: u32 = 0; sampleOffset < simulator.info.apertureSampleCount; sampleOffset += GPU_APERTURE_SAMPLE_CHUNK_SIZE {
					sampleChunkCount := min(GPU_APERTURE_SAMPLE_CHUNK_SIZE, simulator.info.apertureSampleCount - sampleOffset)
					for elementSetOffset := 0; elementSetOffset < len(receiveChannels); elementSetOffset += GPU_ELEMENT_SET_CHUNK_SIZE {
						elementSetChunkCount := min(GPU_ELEMENT_SET_CHUNK_SIZE, len(receiveChannels) - elementSetOffset)
						vkField_vk.cmd_push_constants(commandBuffer, simulator.pipelineLayout, shaderStage, vkCoalescePushData {
							apertureResponseRects = dataBufferAddress + auto_cast header.apertureResponseRects,
							transmissionInfos = dataBufferAddress + auto_cast header.transmissionInfos,
							transmissionResponses = dataBufferAddress + auto_cast header.transmissionResponses,
							transmissionElementCounts = dataBufferAddress + auto_cast header.transmissionElementCounts,
							elementSetMembers = dataBufferAddress + auto_cast header.elementSetMembers,
							elementSetOffset = auto_cast elementSetOffset,
							sampleOffset = auto_cast sampleOffset,
							scattererOffset = auto_cast scatterOffset,
						})
						vk.CmdDispatch(commandBuffer.commandBuffer, u32(math.ceil_f32(f32(sampleChunkCount) / f32(resources.coalAperSpecRcv.SampleWorkgroupSize))), u32(math.ceil_f32(f32(elementSetChunkCount) / f32(resources.coalAperSpecRcv.ElementSetWorkgroupSize))), u32(math.ceil_f32(f32(scatterBatchSize) / f32(resources.coalAperSpecRcv.ScattererWorkgroupSize))))
					}
				}

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
									for sampleOffset: i32 = 0; sampleOffset < settings.sampleCount; sampleOffset += auto_cast GPU_CONVOLUTION_SAMPLE_CHUNK_SIZE {
										sampleChunkCount := min(auto_cast GPU_CONVOLUTION_SAMPLE_CHUNK_SIZE, settings.sampleCount - sampleOffset)
										vkField_vk.cmd_push_constants(commandBuffer, simulator.pipelineLayout, shaderStage, vkPulseConvPushData {
											transmissionInfos = dataBufferAddress + auto_cast header.transmissionInfos,
											transmissionResponses = dataBufferAddress + auto_cast header.transmissionResponses,
											response = vkField_vk.get_buffer_address(device, resources.responseBuffer.main),
											transmissionIndex = auto_cast transmissionIndex,
											receiveChannelIndex = auto_cast receiveChannelIndex,
											sampleOffset = auto_cast sampleOffset,
											scattererOffset = auto_cast scatterOffset,
										})
										vk.CmdDispatch(commandBuffer.commandBuffer, u32(math.ceil_f32(f32(sampleChunkCount) / f32(resources.pulseConvSpec.SampleWorkgroupSize))), 1, 1)
									}
					}
				}

			}

			vkField_vk.cmd_end(commandBuffer) or_return
			scatterComputeWaits: []vkField_vk.SemaphoreBarrier
			if hasTransferQueue {
				scatterComputeWaits = {{semaphore = simulator.transferTimeline, value = simulator.transferTimelineValue, stageMask = {.COMPUTE_SHADER}}}
			}
			simulator.computeTimelineValue += 1
			vkField_vk.queue_submit(
				simulator.queue,
				{commandBuffer},
				scatterComputeWaits,
				{{semaphore = simulator.computeTimeline, value = simulator.computeTimelineValue, stageMask = {.ALL_COMMANDS}}},
			) or_return
			slotComputeTimelineValues[ringIndex] = simulator.computeTimelineValue
		}
		windowComputeTimelineValue := simulator.computeTimelineValue
		timelineWait.value[0] = windowComputeTimelineValue
		check(vkField_vk.wait_semaphores(device, timelineWait, auto_cast time.duration_nanoseconds(auto_cast DISPATCH_TIMEOUT))) or_return

		completedTimelineValue, timelineValueOk := vkField_vk.get_timeline_value(device, simulator.computeTimeline)
		if timelineValueOk {
			completedCommands := min(int(max(completedTimelineValue, scatterComputeStartValue) - scatterComputeStartValue), totalScatterCommands)
			fraction := f64(completedCommands) / f64(totalScatterCommands)
			elapsedDuration := time.stopwatch_duration(progressStopwatch)
			if elapsedDuration >= VULKAN_PROGRESS_LOG_DELAY_THRESHOLD &&
			   (lastProgressLogTime == 0 || elapsedDuration - lastProgressLogTime >= VULKAN_PROGRESS_LOG_INTERVAL) {
				lastProgressLogTime = elapsedDuration
				percentage := fraction * 100.0
				if fraction > 0 {
					estimatedTotalDuration := time.Duration(f64(elapsedDuration) / fraction)
					estimatedRemainingDuration := max(estimatedTotalDuration - elapsedDuration, time.Duration(0))
					log.infof(
						"Vulkan simulation progress: %.1f%%, estimated completion in %v (elapsed: %v, timeline: %d)",
						percentage,
						estimatedRemainingDuration,
						elapsedDuration,
						completedTimelineValue,
					)
				} else {
					log.infof("Vulkan simulation progress: %.1f%% (elapsed: %v, timeline: %d)", percentage, elapsedDuration, completedTimelineValue)
				}
			}
		}
		if hasTransferQueue {
			vkField_vk.reset_command_pool(device, &simulator.transferCommandPool) or_return
		}
		vkField_vk.reset_command_pool(device, &simulator.computeCommandPool) or_return
		commandBuffer = check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return
	}

	vkField_vk.cmd_begin(commandBuffer, true) or_return
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
				dstStageMask = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
			},
		},
		{},
	)
	vk.CmdBindShadersEXT(commandBuffer.commandBuffer, 1, &shaderStage, &resources.temporalShader)
	temporalAddress := vkField_vk.get_buffer_address(device, resources.temporalBuffer.main)
	responseAddress := vkField_vk.get_buffer_address(device, resources.responseBuffer.main)
	for transmission, transmissionIndex in transmissions {
		for receiveChannel, receiveChannelIndex in receiveChannels {
			impulseLength := response_length(impulses, transmission.impulse)
			excitationLength := response_length(excitations, transmission.excitation)
			receiveImpulseLength := response_length(impulses, receiveChannel.impulse)
			for sampleOffset: i32 = 0; sampleOffset < settings.sampleCount; sampleOffset += auto_cast GPU_CONVOLUTION_SAMPLE_CHUNK_SIZE {
				sampleChunkCount := min(auto_cast GPU_CONVOLUTION_SAMPLE_CHUNK_SIZE, settings.sampleCount - sampleOffset)
				vkField_vk.cmd_push_constants(commandBuffer, simulator.pipelineLayout, shaderStage, vkTemporalPushData {
					response = responseAddress,
					temporalOutput = vkField_vk.get_buffer_address(device, resources.temporalOutputBuffer),
					temporalResponses = temporalAddress,
					lineIndex = auto_cast (transmissionIndex * len(receiveChannels) + receiveChannelIndex),
					impulseIndex = auto_cast transmission.impulse,
					excitationIndex = auto_cast transmission.excitation,
					receiveImpulseIndex = auto_cast receiveChannel.impulse,
					impulseLibraryCount = auto_cast len(impulses),
					impulseCount = auto_cast impulseLength,
					excitationCount = auto_cast excitationLength,
					receiveImpulseCount = auto_cast receiveImpulseLength,
					sampleOffset = auto_cast sampleOffset,
					sampleInterval = 1 / settings.samplingFrequency,
				})
				vk.CmdDispatch(commandBuffer.commandBuffer, u32(math.ceil_f32(f32(sampleChunkCount) / f32(resources.temporalSpec.SampleWorkgroupSize))), 1, 1)
			}
		}
	}
	vkField_vk.cmd_pipeline_barrier(
		commandBuffer,
		{},
		{
			{
				buffer = resources.temporalOutputBuffer.buffer,
				size = resources.temporalOutputBuffer.size,
				offset = 0,
				srcStageMask = {.COMPUTE_SHADER},
				srcAccessMask = {.SHADER_WRITE},
				dstStageMask = {.TRANSFER},
				dstAccessMask = {.TRANSFER_READ},
			},
		},
		{},
	)
	vkField_vk.cmd_copy_buffer(
		commandBuffer,
		resources.temporalOutputBuffer,
		resources.responseBuffer.main,
		{{sType = .BUFFER_COPY_2, srcOffset = 0, dstOffset = 0, size = resources.temporalOutputBuffer.size}},
	)
	vkField_vk.cmd_end(commandBuffer) or_return
	simulator.computeTimelineValue += 1
	vkField_vk.queue_submit(
		simulator.queue,
		{commandBuffer},
		{},
		{{semaphore = simulator.computeTimeline, value = simulator.computeTimelineValue, stageMask = {.ALL_COMMANDS}}},
	) or_return
	timelineWait.value[0] = simulator.computeTimelineValue
	check(vkField_vk.wait_semaphores(device, timelineWait, auto_cast time.duration_nanoseconds(auto_cast DISPATCH_TIMEOUT))) or_return
	vkField_vk.reset_command_pool(device, &simulator.computeCommandPool) or_return
	if hasTransferQueue {
		vkField_vk.reset_command_pool(device, &simulator.transferCommandPool) or_return
	}
	commandBuffer = check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return

	vkField_vk.cmd_begin(commandBuffer, true) or_return
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

	simulator.computeTimelineValue += 1
	vkField_vk.queue_submit(
		simulator.queue,
		{commandBuffer},
		{},
		{{semaphore = simulator.computeTimeline, value = simulator.computeTimelineValue, stageMask = {.ALL_COMMANDS}}},
	) or_return
	timelineWait.value[0] = simulator.computeTimelineValue
	check(vkField_vk.wait_semaphores(device, timelineWait, auto_cast time.duration_nanoseconds(auto_cast DISPATCH_TIMEOUT))) or_return
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

prepare_stream :: proc(device: vkField_vk.Device, size: vk.DeviceSize, queueFamilyIndices: []u32 = {}) -> (buffer: vkStagableBuffer, result: vk.Result) {
	sharingMode := len(queueFamilyIndices) > 0 ? vk.SharingMode.CONCURRENT : vk.SharingMode.EXCLUSIVE
	buffer.main = vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER, .TRANSFER_DST}, sharingMode, queueFamilyIndices) or_return
	memoryType, memoryTypeOk := vkField_vk.find_streaming_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer.main))
	if !memoryTypeOk {
		vkField_vk.destroy_buffer(device, buffer.main)
		buffer.main = vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER, .TRANSFER_DST}, sharingMode, queueFamilyIndices) or_return
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

prepare_temporal_output_buffer :: proc(device: vkField_vk.Device, size: vk.DeviceSize) -> (buffer: vkField_vk.Buffer, result: vk.Result) {
	buffer = vkField_vk.create_buffer(device, size, {.STORAGE_BUFFER, .TRANSFER_SRC}) or_return
	memoryType, memoryTypeOk := vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer))
	if !memoryTypeOk {
		vkField_vk.destroy_buffer(device, buffer)
		return {}, .ERROR_OUT_OF_HOST_MEMORY
	}
	vkField_vk.bind_buffer_to_dedicated_memory(device, &buffer, memoryType) or_return
	return
}

prepare_scatter_buffer :: proc(device: vkField_vk.Device, size: vk.DeviceSize) -> (buffer: vkField_vk.Buffer, result: vk.Result) {
	buffer = vkField_vk.create_buffer(device, size, {.TRANSFER_SRC}) or_return
	memoryType, memoryTypeOk := vkField_vk.find_staging_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer))
	if !memoryTypeOk {
		vkField_vk.destroy_buffer(device, buffer)
		return {}, .ERROR_OUT_OF_HOST_MEMORY
	}
	vkField_vk.bind_buffer_to_dedicated_memory(device, &buffer, memoryType) or_return
	assert(vkField_vk.is_mapped(buffer))
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

vkBuildTemporalResponseBuffer :: proc(
	impulses: []TransducerImpulse,
	excitations: []Excitation,
	maxImpulseLength: u32,
	maxExcitationLength: u32,
	allocator := context.allocator,
) -> []byte {
	totalLength := len(impulses) * int(maxImpulseLength) + len(excitations) * int(maxExcitationLength)
	data := make([]f32, totalLength, allocator)
	offset := 0
	for response in impulses {
		copy(data[offset:offset + len(response)], auto_cast response)
		offset += int(maxImpulseLength)
	}
	for response in excitations {
		copy(data[offset:offset + len(response)], auto_cast response)
		offset += int(maxExcitationLength)
	}
	return slice.to_bytes(data)
}

vkBuildDataBuffer :: proc(
	header: vkDataBufferHeader,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	allocator := context.allocator,
) -> []byte {
	elementCount := len(elements)
	transmissionCount := len(transmissions)
	receiveChannelCount := len(receiveChannels)
	dataBuffer := make([]byte, header.totalSize, allocator)

	(cast(^vkDataBufferHeader)raw_data(dataBuffer))^ = header

	copy(slice.from_ptr(cast(^[3]f32)raw_data(dataBuffer[header.elementPositions:]), elementCount), slice.from_ptr(elements.position, elementCount))
	copy(slice.from_ptr(cast(^[3]f32)raw_data(dataBuffer[header.elementNormals:]), elementCount), slice.from_ptr(elements.normal, elementCount))
	copy(slice.from_ptr(cast(^[2]f32)raw_data(dataBuffer[header.elementSizes:]), elementCount), slice.from_ptr(elements.size, elementCount))
	copy(slice.from_ptr(cast(^f32)raw_data(dataBuffer[header.elementApodizations:]), elementCount), slice.from_ptr(elements.apodization, elementCount))
	copy(slice.from_ptr(cast(^f32)raw_data(dataBuffer[header.elementDelays:]), elementCount), slice.from_ptr(elements.delay, elementCount))
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

	return dataBuffer
}
