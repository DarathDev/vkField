package vkfield

import "base:runtime"
import "core:log"
import "core:math"
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

ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)

MAX_FRAMES_IN_FLIGHT :: 2

DISPATCH_TIMEOUT :: 1000 * time.Second

SHADER_PULSE_ECHO_COMP                  :: #load("shaders/pulse_echo.spv")
SHADER_PACK_SPATIAL_IMPULSE_RESPONSE_COMP :: #load("shaders/pack_spatial_impulse_response.spv")

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
	instance:                   vkField_vk.Instance,
	debugUserData:              ^vkField_vk.DebugUserData,
	debugMessenger:             vkField_vk.DebugMessenger,
	physicalDevices:            #soa[]vkField_vk.PhysicalDevice,
	device:                     vkField_vk.Device,

	pulseEchoPipelineLayout:                  vk.PipelineLayout,
	packSpatialImpulseResponsePipelineLayout: vk.PipelineLayout,

	computeDescriptorSetLayout: vkField_vk.DescriptorSetLayout,
	computeCommandPool:         vkField_vk.CommandPool,
	computeDescriptorPool:      vkField_vk.DescriptorPool,
	computeFence:               vk.Fence,
}

vkPackSpatialImpulseResponsePushConstants :: struct {
	scatterBatchOffset : u32,
	receiveBatchOffset : u32,
}

vkPackSpatialImpulseResponseSpecConstants :: struct {
	WorkgroupSizeX    : u32,
	WorkgroupSizeY    : u32,
	WorkgroupSizeZ    : u32,
	ScatterBatchCount : u32,
	ReceiveBatchCount : u32,
	TransmitCount     : u32,
	Cumulative        : u32,
	StartTime         : f32,
	SamplingFrequency : f32,
	SpeedOfSound      : f32,
}

vkPulseEchoPushConstants :: struct {
	receiveBatchOffset : u32,
}

vkPulseEchoSpecConstants :: struct {
	WorkgroupSizeX    : u32,
	SampleCount       : u32,
	TransmitCount     : u32,
	ReceiveBatchCount : u32,
	ScatterBatchCount : u32,
	Cumulative        : u32,
}

create_vulkan_simulator :: proc() -> (simulator: vkSimulator, ok := vk.Result.SUCCESS) {
	simulator.debugUserData = new(vkField_vk.DebugUserData)
	simulator.debugUserData.logger = context.logger
	simulator.instance = confirm(
		vkField_vk.create_instance({appName = "vkField", vulkanVersion = vk.API_VERSION_1_3}, debugUserData = simulator.debugUserData),
	) or_return

	when ENABLE_VALIDATION_LAYERS {
		simulator.debugMessenger = confirm(vkField_vk.create_debug_messenger(simulator.instance, simulator.debugUserData)) or_return
	}

	simulator.physicalDevices = vkField_vk.get_physical_devices(simulator.instance.instance) or_return
	requiredCapabilities: vkField_vk.DeviceCapabilities = {.Synchronization2, .Maintenance4}
	physicalDevice, physicalDeviceAvailable := vkField_vk.pick_physical_device(
		simulator.instance.instance,
		simulator.physicalDevices,
		{requiredCapabilities = requiredCapabilities},
	)
	if !physicalDeviceAvailable do return simulator, vk.Result.ERROR_DEVICE_LOST
	simulator.device = check(vkField_vk.create_device(simulator.instance, physicalDevice, {requiredCapabilities = requiredCapabilities})) or_return

	simulator.computeDescriptorSetLayout = check(
		vkField_vk.create_descriptor_set_layout(
			simulator.device,
			{
				{binding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
				{binding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
				{binding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
				{binding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
				{binding = 4, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
				{binding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
			},
		),
	) or_return

	simulator.pulseEchoPipelineLayout = check(
		vkField_vk.create_pipeline_layout(
			simulator.device,
			{simulator.computeDescriptorSetLayout.layout},
			{{stageFlags = {.COMPUTE}, size = size_of(vkPulseEchoPushConstants), offset = 0}},
		),
	) or_return

	simulator.packSpatialImpulseResponsePipelineLayout = check(
		vkField_vk.create_pipeline_layout(
			simulator.device,
			{simulator.computeDescriptorSetLayout.layout},
			{{stageFlags = {.COMPUTE}, size = size_of(vkPackSpatialImpulseResponsePushConstants), offset = 0}},
		),
	) or_return

	simulator.computeCommandPool = check(vkField_vk.create_command_pool(simulator.device, simulator.device.computeQueueIndex, true)) or_return
	simulator.computeDescriptorPool = check(
		vkField_vk.create_descriptor_pool(simulator.device, 1, simulator.computeDescriptorSetLayout, label = "Compute"),
	) or_return
	simulator.computeFence = check(vkField_vk.create_fence(simulator.device, label = "Compute")) or_return

	return
}

destroy_vulkan_simulator :: proc(simulator: ^vkSimulator) {
	vkField_vk.destroy_fence(simulator.device, simulator.computeFence)
	vkField_vk.destroy_command_pool(simulator.device, simulator.computeCommandPool)
	vkField_vk.destroy_descriptor_pool(simulator.device, simulator.computeDescriptorPool)

	vkField_vk.destroy_pipeline_layout(simulator.device, simulator.pulseEchoPipelineLayout)
	vkField_vk.destroy_pipeline_layout(simulator.device, simulator.packSpatialImpulseResponsePipelineLayout)

	vkField_vk.destroy_descriptor_set_layout(simulator.device, simulator.computeDescriptorSetLayout)
	vkField_vk.destroy_device(&simulator.device)
	vkField_vk.free_physical_devices(&simulator.physicalDevices)
	when ENABLE_VALIDATION_LAYERS {
		vkField_vk.destroy_debug_messenger(simulator.instance.instance, &simulator.debugMessenger)
	}
	vkField_vk.destroy_instance(&simulator.instance)
	free(simulator.debugUserData)
	simulator^ = {}
}

vkSimulate :: proc(
	simulator: ^vkSimulator,
	settings: SimulationSettings,
	transmitElements: []Element,
	receiveElements: []Element,
	scatters: []Scatter,
	allocator := context.allocator,
) -> (
	response: []f32,
	result: vk.Result,
) {
	device := simulator.device
	computeFence := simulator.computeFence

	packSpatialImpulseResponseWorkGroupSize :[3]u32: {4, 4, 4}

	packSpatialImpulseBufferSize  :: 32 * runtime.Megabyte
	scatterBatchCount    := u32(settings.scatterCount)
	receiveBatchCount    := u32(settings.receiveElementCount)
	packSpatialImpulseScatterSize  := u32(size_of([4]f32) * scatterBatchCount * (receiveBatchCount + u32(settings.transmitElementCount)))

	// Batch Receives to reduce temp buffer size
	if packSpatialImpulseScatterSize > packSpatialImpulseBufferSize {
		maxReceiveBatchCount := min(u32(settings.receiveElementCount), device.physicalDevice.properties.limits.maxComputeWorkGroupCount.y * packSpatialImpulseResponseWorkGroupSize.y)
		receiveBatchCount     = clamp((packSpatialImpulseBufferSize / (size_of([4]f32) * scatterBatchCount)) - u32(settings.transmitElementCount), 1, maxReceiveBatchCount)
		packSpatialImpulseScatterSize   = u32(size_of([4]f32) * scatterBatchCount * (receiveBatchCount + u32(settings.transmitElementCount)))
	}

	// Batch Scatters to reduce temp buffer size
	if packSpatialImpulseScatterSize > packSpatialImpulseBufferSize {
		maxScatterBatchCount := min(u32(settings.scatterCount), device.physicalDevice.properties.limits.maxComputeWorkGroupCount.x * packSpatialImpulseResponseWorkGroupSize.x)
		scatterBatchCount = clamp(packSpatialImpulseBufferSize / (size_of([4]f32) * (receiveBatchCount + u32(settings.transmitElementCount))), 1, maxScatterBatchCount)
		packSpatialImpulseScatterSize  = u32(size_of([4]f32) * scatterBatchCount * (receiveBatchCount + u32(settings.transmitElementCount)))
	}

	assert(packSpatialImpulseScatterSize <= packSpatialImpulseBufferSize)

	packSpatialImpulseScaleBufferSize := packSpatialImpulseScatterSize / (size_of([4]f32) / size_of(f32))

	// NOTE(rnp): specialize shaders
	pulseEchoPipeline        : vkField_vk.ComputePipeline
	packSpatialImpulseResponsePipeline : vkField_vk.ComputePipeline
	packSpatialImpulseResponseSpecConstants := vkPackSpatialImpulseResponseSpecConstants {
		WorkgroupSizeX    = 4,
		WorkgroupSizeY    = 4,
		WorkgroupSizeZ    = 4,
		ScatterBatchCount = u32(scatterBatchCount),
		ReceiveBatchCount = u32(receiveBatchCount),
		TransmitCount     = u32(settings.transmitElementCount),
		Cumulative        = settings.cumulative ? 1 : 0,
		StartTime         = settings.startTime,
		SamplingFrequency = settings.samplingFrequency,
		SpeedOfSound      = settings.speedOfSound,
	}

	pulseEchoSpecConstants := vkPulseEchoSpecConstants {
		// TODO(rnp): subgroup size
		WorkgroupSizeX    = 64,
		SampleCount       = u32(settings.sampleCount),
		TransmitCount     = u32(settings.transmitElementCount),
		ReceiveBatchCount = u32(receiveBatchCount),
		ScatterBatchCount = u32(scatterBatchCount),
		Cumulative        = settings.cumulative ? 1 : 0,
	}



	{
		// TODO(rnp): doesn't odin have a compile time way to generate this?
		packSpatialImpulseResponseSpecMap := []vk.SpecializationMapEntry {
			{
				constantID = 0,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, WorkgroupSizeX)),
				size       = size_of(u32),
			},
			{
				constantID = 1,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, WorkgroupSizeY)),
				size       = size_of(u32),
			},
			{
				constantID = 2,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, WorkgroupSizeZ)),
				size       = size_of(u32),
			},
			{
				constantID = 3,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, ScatterBatchCount)),
				size       = size_of(u32),
			},
			{
				constantID = 4,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, ReceiveBatchCount)),
				size       = size_of(u32),
			},
			{
				constantID = 5,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, TransmitCount)),
				size       = size_of(u32),
			},
			{
				constantID = 6,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, Cumulative)),
				size       = size_of(u32),
			},
			{
				constantID = 7,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, StartTime)),
				size       = size_of(f32),
			},
			{
				constantID = 8,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, SamplingFrequency)),
				size       = size_of(f32),
			},
			{
				constantID = 9,
				offset     = u32(offset_of(vkPackSpatialImpulseResponseSpecConstants, SpeedOfSound)),
				size       = size_of(f32),
			},
		}

		packSpatialImpulseResponseSpecInfo := vk.SpecializationInfo {
			mapEntryCount = u32(len(packSpatialImpulseResponseSpecMap)),
			pMapEntries   = &packSpatialImpulseResponseSpecMap[0],
			dataSize      = size_of(packSpatialImpulseResponseSpecConstants),
			pData         = &packSpatialImpulseResponseSpecConstants,
		}

		packSpatialImpulseResponsePipeline = check(
			vkField_vk.create_compute_pipeline(
				simulator.device,
				{kind = .Compute, code = SHADER_PACK_SPATIAL_IMPULSE_RESPONSE_COMP, entryPoints = {{name = "main", stage = .COMPUTE}}},
				simulator.packSpatialImpulseResponsePipelineLayout,
				&packSpatialImpulseResponseSpecInfo,
				"Pack Spatial Impulse Response",
			),
		) or_return

		pulseEchoSpecMap := []vk.SpecializationMapEntry {
			{
				constantID = 0,
				offset     = u32(offset_of(vkPulseEchoSpecConstants, WorkgroupSizeX)),
				size       = size_of(u32),
			},
			{
				constantID = 1,
				offset     = u32(offset_of(vkPulseEchoSpecConstants, SampleCount)),
				size       = size_of(u32),
			},
			{
				constantID = 2,
				offset     = u32(offset_of(vkPulseEchoSpecConstants, TransmitCount)),
				size       = size_of(u32),
			},
			{
				constantID = 3,
				offset     = u32(offset_of(vkPulseEchoSpecConstants, ReceiveBatchCount)),
				size       = size_of(u32),
			},
			{
				constantID = 4,
				offset     = u32(offset_of(vkPulseEchoSpecConstants, ScatterBatchCount)),
				size       = size_of(u32),
			},
			{
				constantID = 5,
				offset     = u32(offset_of(vkPulseEchoSpecConstants, Cumulative)),
				size       = size_of(u32),
			},
		}
		pulseEchoSpecInfo := vk.SpecializationInfo {
			mapEntryCount = u32(len(pulseEchoSpecMap)),
			pMapEntries   = &pulseEchoSpecMap[0],
			dataSize      = size_of(pulseEchoSpecConstants),
			pData         = &pulseEchoSpecConstants,
		}

		pulseEchoPipeline = check(
			vkField_vk.create_compute_pipeline(
				device,
				{kind = .Compute, code = SHADER_PULSE_ECHO_COMP, entryPoints = {{name = "main", stage = .COMPUTE}}},
				simulator.pulseEchoPipelineLayout,
				&pulseEchoSpecInfo,
				"Pulse Echo",
			),
		) or_return
	}
	defer {
		vkField_vk.destroy_compute_pipeline(device, pulseEchoPipeline)
		vkField_vk.destroy_compute_pipeline(device, packSpatialImpulseResponsePipeline)
	}

	response = make([]f32, settings.receiveElementCount * settings.sampleCount, allocator)

	commandBuffer := check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return
	defer vkField_vk.reset_command_buffer(device, &simulator.computeCommandPool, commandBuffer)

	commandBeginInfo: vk.CommandBufferBeginInfo = {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	check(vk.BeginCommandBuffer(commandBuffer, &commandBeginInfo)) or_return

	transmitElementsBuffer, transmitElementsStagingBuffer     := check(stream(device, commandBuffer, transmitElements)) or_return
	receiveElementsBuffer,  receiveElementsStagingBuffer      := check(stream(device, commandBuffer, receiveElements)) or_return
	scattersBuffer, scattersStagingBuffer                     := check(stream(device, commandBuffer, scatters)) or_return
	responseBuffer, responseReadbackBuffer                    := check(prepare_readback(device, commandBuffer, response)) or_return
	packSpatialImpulseBufferMemory, packSpatialImpulseBuffers := check(device_buffers(device, []vk.DeviceSize { auto_cast packSpatialImpulseScatterSize, auto_cast packSpatialImpulseScaleBufferSize})) or_return

	defer {
		vkField_vk.release_buffer(device, transmitElementsBuffer)
		vkField_vk.release_buffer(device, receiveElementsBuffer)
		vkField_vk.release_buffer(device, scattersBuffer)
		vkField_vk.release_buffer(device, responseBuffer)
		for buffer in packSpatialImpulseBuffers {
			vkField_vk.destroy_buffer(device, buffer)
		}
		vkField_vk.free_memory(device, packSpatialImpulseBufferMemory)
		delete(packSpatialImpulseBuffers)

		if buffer, bufferOk := transmitElementsStagingBuffer.?; bufferOk {
			vkField_vk.release_buffer(device, buffer)
		}
		if buffer, bufferOk := receiveElementsStagingBuffer.?; bufferOk {
			vkField_vk.release_buffer(device, buffer)
		}
		if buffer, bufferOk := scattersStagingBuffer.?; bufferOk {
			vkField_vk.release_buffer(device, buffer)
		}
		if buffer, bufferOk := responseReadbackBuffer.?; bufferOk {
			vkField_vk.release_buffer(device, buffer)
		}
	}

	// Initialize response to zero for atomic accumulation.
	vkField_vk.cmd_clear_buffer(commandBuffer, responseBuffer)

	vkField_vk.cmd_pipeline_barrier(
		commandBuffer,
		{},
		{
			{
				buffer = transmitElementsBuffer.buffer,
				size = transmitElementsBuffer.size,
				srcStageMask = {.TRANSFER, .HOST},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ},
			},
			{
				buffer = receiveElementsBuffer.buffer,
				size = receiveElementsBuffer.size,
				srcStageMask = {.TRANSFER, .HOST},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ},
			},
			{
				buffer = scattersBuffer.buffer,
				size = scattersBuffer.size,
				srcStageMask = {.TRANSFER, .HOST},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ},
			},
			{
				buffer = responseBuffer.buffer,
				size = responseBuffer.size,
				offset = 0,
				srcStageMask = {.TRANSFER, .HOST},
				srcAccessMask = {.TRANSFER_WRITE, .HOST_WRITE},
				dstStageMask = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
			},
		},
		{},
	)

	descriptorSet := check(vkField_vk.allocate_descriptor_set(device, simulator.computeDescriptorPool, simulator.computeDescriptorSetLayout)) or_return

	// TODO(rnp): if this is vulkan 1.3 then BDA should just be used for most of these
	transmitElementsDescriptor: vk.DescriptorBufferInfo = {
		buffer = transmitElementsBuffer.buffer,
		range  = transmitElementsBuffer.size,
		offset = 0,
	}
	receiveElementsDescriptor: vk.DescriptorBufferInfo = {
		buffer = receiveElementsBuffer.buffer,
		range  = receiveElementsBuffer.size,
		offset = 0,
	}
	scattersDescriptor: vk.DescriptorBufferInfo = {
		buffer = scattersBuffer.buffer,
		range  = scattersBuffer.size,
		offset = 0,
	}
	responseDescriptor: vk.DescriptorBufferInfo = {
		buffer = responseBuffer.buffer,
		range  = responseBuffer.size,
		offset = 0,
	}
	packSpatialImpulseDescriptor: vk.DescriptorBufferInfo = {
		buffer = packSpatialImpulseBuffers[0].buffer,
		range  = packSpatialImpulseBuffers[0].size,
		offset = 0,
	}
	packSpatialImpulseScaleDescriptor: vk.DescriptorBufferInfo = {
		buffer = packSpatialImpulseBuffers[1].buffer,
		range  = packSpatialImpulseBuffers[1].size,
		offset = 0,
	}

	vkField_vk.update_descriptor_sets(
		device,
		{
			{dstSet = descriptorSet, dstBinding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &transmitElementsDescriptor},
			{dstSet = descriptorSet, dstBinding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &receiveElementsDescriptor},
			{dstSet = descriptorSet, dstBinding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &scattersDescriptor},
			{dstSet = descriptorSet, dstBinding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &responseDescriptor},
			{dstSet = descriptorSet, dstBinding = 4, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &packSpatialImpulseDescriptor},
			{dstSet = descriptorSet, dstBinding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &packSpatialImpulseScaleDescriptor},
		},
	)

	for receiveOffset : u32 = 0; receiveOffset < u32(settings.receiveElementCount); receiveOffset += u32(receiveBatchCount) {
		for scatterOffset : u32 = 0; scatterOffset < u32(settings.scatterCount); scatterOffset += u32(scatterBatchCount) {
			packSpatialImpulseResponsePushConstants := vkPackSpatialImpulseResponsePushConstants {
				scatterBatchOffset = scatterOffset,
				receiveBatchOffset = receiveOffset,
			}
			vkField_vk.cmd_pipeline_barrier(
				commandBuffer,
				{},
				{
					{
						buffer        = packSpatialImpulseBuffers[0].buffer,
						size          = packSpatialImpulseBuffers[0].size,
						offset        = 0,
						srcStageMask  = {.COMPUTE_SHADER},
						srcAccessMask = {.SHADER_READ},
						dstStageMask  = {.COMPUTE_SHADER},
						dstAccessMask = {.SHADER_WRITE},
					},
					{
						buffer        = packSpatialImpulseBuffers[1].buffer,
						size          = packSpatialImpulseBuffers[1].size,
						offset        = 0,
						srcStageMask  = {.COMPUTE_SHADER},
						srcAccessMask = {.SHADER_READ},
						dstStageMask  = {.COMPUTE_SHADER},
						dstAccessMask = {.SHADER_WRITE},
					},
				},
				{},
			)

			vk.CmdBindPipeline(commandBuffer, .COMPUTE, packSpatialImpulseResponsePipeline.pipeline)
			vk.CmdBindDescriptorSets(commandBuffer, .COMPUTE, simulator.packSpatialImpulseResponsePipelineLayout,
								 0, 1, &descriptorSet, 0, nil)
			vkField_vk.cmd_push_constants(commandBuffer, simulator.packSpatialImpulseResponsePipelineLayout,
									  {.COMPUTE}, packSpatialImpulseResponsePushConstants)

			vk.CmdDispatch(
				commandBuffer,
				u32(math.ceil(f32(packSpatialImpulseResponseSpecConstants.ScatterBatchCount) / f32(packSpatialImpulseResponseSpecConstants.WorkgroupSizeX))),
				u32(math.ceil(f32(packSpatialImpulseResponseSpecConstants.ReceiveBatchCount) / f32(packSpatialImpulseResponseSpecConstants.WorkgroupSizeY))),
				u32(math.ceil(f32(packSpatialImpulseResponseSpecConstants.TransmitCount)     / f32(packSpatialImpulseResponseSpecConstants.WorkgroupSizeZ))),
			)

			vkField_vk.cmd_pipeline_barrier(
				commandBuffer,
				{},
				{
					{
						buffer        = packSpatialImpulseBuffers[0].buffer,
						size          = packSpatialImpulseBuffers[0].size,
						offset        = 0,
						srcStageMask  = {.COMPUTE_SHADER},
						srcAccessMask = {.SHADER_WRITE},
						dstStageMask  = {.COMPUTE_SHADER},
						dstAccessMask = {.SHADER_READ},
					},
					{
						buffer        = packSpatialImpulseBuffers[1].buffer,
						size          = packSpatialImpulseBuffers[1].size,
						offset        = 0,
						srcStageMask  = {.COMPUTE_SHADER},
						srcAccessMask = {.SHADER_WRITE},
						dstStageMask  = {.COMPUTE_SHADER},
						dstAccessMask = {.SHADER_READ},
					},
					{
						buffer        = responseBuffer.buffer,
						size          = responseBuffer.size,
						offset        = 0,
						srcStageMask  = {.COMPUTE_SHADER},
						srcAccessMask = {.SHADER_WRITE},
						dstStageMask  = {.COMPUTE_SHADER},
						dstAccessMask = {.SHADER_READ},
					},
				},
				{},
			)

			pulseEchoPushConstants := vkPulseEchoPushConstants {
				receiveBatchOffset = receiveOffset,
			}
			vkField_vk.cmd_push_constants(commandBuffer, simulator.pulseEchoPipelineLayout,
			                              {.COMPUTE}, pulseEchoPushConstants)
			vk.CmdBindPipeline(commandBuffer, .COMPUTE, pulseEchoPipeline.pipeline)
			vk.CmdBindDescriptorSets(commandBuffer, .COMPUTE, simulator.pulseEchoPipelineLayout,
			                         0, 1, &descriptorSet, 0, nil)
			vk.CmdDispatch(
				commandBuffer,
				u32(math.ceil(f32(pulseEchoSpecConstants.SampleCount) / f32(pulseEchoSpecConstants.WorkgroupSizeX))),
				pulseEchoSpecConstants.ReceiveBatchCount,
				1,
			)
		}
	}

	vkField_vk.cmd_pipeline_barrier(
		commandBuffer,
		{},
		{
			{
				buffer = responseBuffer.buffer,
				size = responseBuffer.size,
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
	if buffer, bufferOk := responseReadbackBuffer.(vkField_vk.Buffer); bufferOk {
		vkField_vk.cmd_download_from_buffer(commandBuffer, responseBuffer, buffer)
		downloadBuffer = buffer
	} else {
		downloadBuffer = responseBuffer
	}

	check(vk.EndCommandBuffer(commandBuffer)) or_return

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

	check(vk.QueueSubmit2(device.queues[device.computeQueueIndex], 1, &submitInfo, computeFence)) or_return
	check(vk.WaitForFences(device.device, 1, &computeFence, true, auto_cast time.duration_nanoseconds(auto_cast DISPATCH_TIMEOUT))) or_return
	vkField_vk.read_from_buffer(downloadBuffer, slice.to_bytes(response))
	vk.DeviceWaitIdle(device.device) or_return
	return
}

device_buffer :: proc(
	device : vkField_vk.Device,
	size   : vk.DeviceSize,
) -> (
	buffer : vkField_vk.Buffer,
	result : vk.Result,
) {
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
	device : vkField_vk.Device,
	sizes   : []vk.DeviceSize,
	alignment: vk.DeviceSize = 1
) -> (
	memory: vkField_vk.Memory,
	buffers : []vkField_vk.Buffer,
	result : vk.Result,
) {
	totalSize : vk.DeviceSize
	offsets := make([]vk.DeviceSize, len(sizes), context.temp_allocator)
	for index in 0..<len(sizes) {
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

stream :: proc(
	device: vkField_vk.Device,
	commandBuffer: vk.CommandBuffer,
	data: []$T,
) -> (
	buffer: vkField_vk.Buffer,
	stagingBuffer: Maybe(vkField_vk.Buffer),
	result: vk.Result,
) {
	buffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER}) or_return
	memoryType, memoryTypeOk := vkField_vk.find_streaming_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer))
	if !memoryTypeOk {
		vkField_vk.destroy_buffer(device, buffer)
		buffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER, .TRANSFER_DST}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer));
		   !memoryTypeOk {
			return {}, {}, .ERROR_OUT_OF_HOST_MEMORY
		}
	}
	vkField_vk.bind_buffer_to_dedicated_memory(device, &buffer, memoryType) or_return

	if buffer.memory.mappedData == nil {
		stagingBuffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_staging_memory_type(
			device.physicalDevice,
			vkField_vk.get_memory_requirements(device, stagingBuffer.(vkField_vk.Buffer)),
		); !memoryTypeOk {
			return {}, {}, .ERROR_OUT_OF_HOST_MEMORY
		}
		vkField_vk.bind_buffer_to_dedicated_memory(device, &stagingBuffer.(vkField_vk.Buffer), memoryType) or_return
		vkField_vk.cmd_upload(commandBuffer, slice.to_bytes(data), buffer, stagingBuffer = stagingBuffer.(vkField_vk.Buffer))
	} else {
		vkField_vk.cmd_upload(commandBuffer, slice.to_bytes(data), buffer)
	}
	return
}

prepare_readback :: proc(
	device: vkField_vk.Device,
	commandBuffer: vk.CommandBuffer,
	data: []$T,
) -> (
	buffer: vkField_vk.Buffer,
	readbackBuffer: Maybe(vkField_vk.Buffer),
	result: vk.Result,
) {
	buffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER, .TRANSFER_DST}) or_return
	memoryType, memoryTypeOk := vkField_vk.find_streaming_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer))
	if !memoryTypeOk {
		vkField_vk.destroy_buffer(device, buffer)
		buffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer));
		   !memoryTypeOk {
			return {}, {}, .ERROR_OUT_OF_HOST_MEMORY
		}
	}
	vkField_vk.bind_buffer_to_dedicated_memory(device, &buffer, memoryType) or_return

	if buffer.memory.mappedData == nil {
		readbackBuffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_readback_memory_type(
			device.physicalDevice,
			vkField_vk.get_memory_requirements(device, readbackBuffer.(vkField_vk.Buffer)),
		); !memoryTypeOk {
			return {}, {}, .ERROR_OUT_OF_HOST_MEMORY
		}
		vkField_vk.bind_buffer_to_dedicated_memory(device, &readbackBuffer.(vkField_vk.Buffer), memoryType) or_return
	}
	return
}
