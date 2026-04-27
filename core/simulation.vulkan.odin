package vkfield

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

SHADER_PULSE_ECHO_COMP         :: #load("shaders/pulse_echo.spv")
SHADER_PACK_SCATTER_RECTS_COMP :: #load("shaders/pack_scatter_rects.spv")

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

	pulseEchoPipelineLayout:        vk.PipelineLayout,
	packScatterRectsPipelineLayout: vk.PipelineLayout,

	computeDescriptorSetLayout: vkField_vk.DescriptorSetLayout,
	computeCommandPool:         vkField_vk.CommandPool,
	computeDescriptorPool:      vkField_vk.DescriptorPool,
	computeFence:               vk.Fence,
}

vkPackScatterRectsPushConstants :: struct {
	scatterBatchOffset : u32,
}

vkPackScatterRectsSpecConstants :: struct {
	WorkgroupSizeX    : u32,
	WorkgroupSizeY    : u32,
	WorkgroupSizeZ    : u32,
	ScatterBatchCount : u32,
	TransmitCount     : u32,
	ReceiveCount      : u32,
	Cumulative        : u32,
	StartTime         : f32,
	SamplingFrequency : f32,
	SpeedOfSound      : f32,
}

vkPulseEchoSpecConstants :: struct {
	WorkgroupSizeX    : u32,
	SampleCount       : u32,
	TransmitCount     : u32,
	ReceiveCount      : u32,
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
	requiredCapabilities: vkField_vk.DeviceCapabilities = {.Synchronization2}
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
			{{stageFlags = {.COMPUTE}, size = 0, offset = 0}},
		),
	) or_return

	simulator.packScatterRectsPipelineLayout = check(
		vkField_vk.create_pipeline_layout(
			simulator.device,
			{simulator.computeDescriptorSetLayout.layout},
			{{stageFlags = {.COMPUTE}, size = size_of(vkPackScatterRectsPushConstants), offset = 0}},
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
	vkField_vk.destroy_pipeline_layout(simulator.device, simulator.packScatterRectsPipelineLayout)

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

	packRectsBufferSize       :: 32 * 1024 * 1024
	packRectSingleScatterSize := (4 * size_of(f32) + 4 * size_of(f32)) * (settings.receiveElementCount + settings.transmitElementCount)
	scatterBatchCount         := u32(math.min(settings.scatterCount, packRectsBufferSize / packRectSingleScatterSize))
	packRectsScaleBufferSize  := size_of(f32) * scatterBatchCount * u32(settings.receiveElementCount + settings.transmitElementCount)

	// NOTE(rnp): specialize shaders
	pulseEchoPipeline        : vkField_vk.ComputePipeline
	packScatterRectsPipeline : vkField_vk.ComputePipeline
	packScatterRectsSpecConstants := vkPackScatterRectsSpecConstants {
		WorkgroupSizeX    = 4,
		WorkgroupSizeY    = 4,
		WorkgroupSizeZ    = 4,
		ScatterBatchCount = scatterBatchCount,
		TransmitCount     = u32(settings.transmitElementCount),
		ReceiveCount      = u32(settings.receiveElementCount),
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
		ReceiveCount      = u32(settings.receiveElementCount),
		ScatterBatchCount = scatterBatchCount,
		Cumulative        = settings.cumulative ? 1 : 0,
	}

	{
		// TODO(rnp): doesn't odin have a compile time way to generate this?
		packScatterRectsSpecMap := []vk.SpecializationMapEntry {
			{
				constantID = 0,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, WorkgroupSizeX)),
				size       = size_of(u32),
			},
			{
				constantID = 1,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, WorkgroupSizeY)),
				size       = size_of(u32),
			},
			{
				constantID = 2,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, WorkgroupSizeZ)),
				size       = size_of(u32),
			},
			{
				constantID = 3,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, ScatterBatchCount)),
				size       = size_of(u32),
			},
			{
				constantID = 4,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, TransmitCount)),
				size       = size_of(u32),
			},
			{
				constantID = 5,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, ReceiveCount)),
				size       = size_of(u32),
			},
			{
				constantID = 6,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, Cumulative)),
				size       = size_of(u32),
			},
			{
				constantID = 7,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, StartTime)),
				size       = size_of(f32),
			},
			{
				constantID = 8,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, SamplingFrequency)),
				size       = size_of(f32),
			},
			{
				constantID = 9,
				offset     = u32(offset_of(vkPackScatterRectsSpecConstants, SpeedOfSound)),
				size       = size_of(f32),
			},
		}

		packScatterRectsSpecInfo := vk.SpecializationInfo {
			mapEntryCount = u32(len(packScatterRectsSpecMap)),
			pMapEntries   = &packScatterRectsSpecMap[0],
			dataSize      = size_of(packScatterRectsSpecConstants),
			pData         = &packScatterRectsSpecConstants,
		}

		packScatterRectsPipeline = check(
			vkField_vk.create_compute_pipeline(
				simulator.device,
				{kind = .Compute, code = SHADER_PACK_SCATTER_RECTS_COMP, entryPoints = {{name = "main", stage = .COMPUTE}}},
				simulator.packScatterRectsPipelineLayout,
				&packScatterRectsSpecInfo,
				"Pack Scatter Rects",
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
				offset     = u32(offset_of(vkPulseEchoSpecConstants, ReceiveCount)),
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
		vkField_vk.destroy_compute_pipeline(device, packScatterRectsPipeline)
	}

	response = make([]f32, settings.receiveElementCount * settings.sampleCount, allocator)

	commandBuffer := check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return
	defer vkField_vk.reset_command_buffer(device, &simulator.computeCommandPool, commandBuffer)

	commandBeginInfo: vk.CommandBufferBeginInfo = {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	check(vk.BeginCommandBuffer(commandBuffer, &commandBeginInfo)) or_return

	transmitElementsBuffer, transmitElementsStagingBuffer := check(stream(device, commandBuffer, transmitElements)) or_return
	receiveElementsBuffer,  receiveElementsStagingBuffer  := check(stream(device, commandBuffer, receiveElements)) or_return
	scattersBuffer, scattersStagingBuffer                 := check(stream(device, commandBuffer, scatters)) or_return
	responseBuffer, responseReadbackBuffer                := check(prepare_readback(device, commandBuffer, response)) or_return

	// TODO(rnp): these can really just be the same buffer
	packRectsBuffer                                       := check(device_buffer(device, auto_cast packRectsBufferSize)) or_return
	packRectsScaleBuffer                                  := check(device_buffer(device, auto_cast packRectsScaleBufferSize)) or_return

	defer {
		vkField_vk.release_buffer(device, transmitElementsBuffer)
		vkField_vk.release_buffer(device, receiveElementsBuffer)
		vkField_vk.release_buffer(device, scattersBuffer)
		vkField_vk.release_buffer(device, responseBuffer)
		vkField_vk.release_buffer(device, packRectsBuffer)
		vkField_vk.release_buffer(device, packRectsScaleBuffer)

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

	// TODO(rnp): clear should be done in a shader
	// Initialize response to zero for atomic accumulation.
	vkField_vk.cmd_upload(commandBuffer, slice.to_bytes(response), responseBuffer)

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
	packRectsDescriptor: vk.DescriptorBufferInfo = {
		buffer = packRectsBuffer.buffer,
		range  = packRectsBuffer.size,
		offset = 0,
	}
	packRectsScaleDescriptor: vk.DescriptorBufferInfo = {
		buffer = packRectsScaleBuffer.buffer,
		range  = packRectsScaleBuffer.size,
		offset = 0,
	}

	vkField_vk.update_descriptor_sets(
		device,
		{
			{dstSet = descriptorSet, dstBinding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &transmitElementsDescriptor},
			{dstSet = descriptorSet, dstBinding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &receiveElementsDescriptor},
			{dstSet = descriptorSet, dstBinding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &scattersDescriptor},
			{dstSet = descriptorSet, dstBinding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &responseDescriptor},
			{dstSet = descriptorSet, dstBinding = 4, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &packRectsDescriptor},
			{dstSet = descriptorSet, dstBinding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &packRectsScaleDescriptor},
		},
	)

	for scatterOffset : u32 = 0; scatterOffset < u32(settings.scatterCount); scatterOffset += u32(scatterBatchCount) {
		packScatterRectsPushConstants := vkPackScatterRectsPushConstants {
			scatterBatchOffset = scatterOffset,
		}

		vkField_vk.cmd_pipeline_barrier(
			commandBuffer,
			{},
			{
				{
					buffer        = packRectsBuffer.buffer,
					size          = packRectsBuffer.size,
					offset        = 0,
					srcStageMask  = {.COMPUTE_SHADER},
					srcAccessMask = {.SHADER_READ},
					dstStageMask  = {.COMPUTE_SHADER},
					dstAccessMask = {.SHADER_WRITE},
				},
				{
					buffer        = packRectsScaleBuffer.buffer,
					size          = packRectsScaleBuffer.size,
					offset        = 0,
					srcStageMask  = {.COMPUTE_SHADER},
					srcAccessMask = {.SHADER_READ},
					dstStageMask  = {.COMPUTE_SHADER},
					dstAccessMask = {.SHADER_WRITE},
				},
			},
			{},
		)

		vk.CmdBindPipeline(commandBuffer, .COMPUTE, packScatterRectsPipeline.pipeline)
		vk.CmdBindDescriptorSets(commandBuffer, .COMPUTE, simulator.packScatterRectsPipelineLayout,
		                         0, 1, &descriptorSet, 0, nil)
		vkField_vk.cmd_push_constants(commandBuffer, simulator.packScatterRectsPipelineLayout,
		                              {.COMPUTE}, packScatterRectsPushConstants)

		vk.CmdDispatch(
			commandBuffer,
			u32(math.ceil(f32(packScatterRectsSpecConstants.ScatterBatchCount) / f32(packScatterRectsSpecConstants.WorkgroupSizeX))),
			u32(math.ceil(f32(packScatterRectsSpecConstants.ReceiveCount)      / f32(packScatterRectsSpecConstants.WorkgroupSizeY))),
			u32(math.ceil(f32(packScatterRectsSpecConstants.TransmitCount)     / f32(packScatterRectsSpecConstants.WorkgroupSizeZ))),
		)

		vkField_vk.cmd_pipeline_barrier(
			commandBuffer,
			{},
			{
				{
					buffer        = packRectsBuffer.buffer,
					size          = packRectsBuffer.size,
					offset        = 0,
					srcStageMask  = {.COMPUTE_SHADER},
					srcAccessMask = {.SHADER_WRITE},
					dstStageMask  = {.COMPUTE_SHADER},
					dstAccessMask = {.SHADER_READ},
				},
				{
					buffer        = packRectsScaleBuffer.buffer,
					size          = packRectsScaleBuffer.size,
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

		vk.CmdBindPipeline(commandBuffer, .COMPUTE, pulseEchoPipeline.pipeline)
		vk.CmdBindDescriptorSets(commandBuffer, .COMPUTE, simulator.pulseEchoPipelineLayout,
		                         0, 1, &descriptorSet, 0, nil)
		vk.CmdDispatch(
			commandBuffer,
			u32(math.ceil(f32(pulseEchoSpecConstants.SampleCount) / f32(pulseEchoSpecConstants.WorkgroupSizeX))),
			u32(pulseEchoSpecConstants.ReceiveCount),
			1,
		)
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
	_ = vkField_vk.bind_buffer_to_dedicated_memory(&buffer, device, memoryType) or_return
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
	_ = vkField_vk.bind_buffer_to_dedicated_memory(&buffer, device, memoryType) or_return

	if buffer.mappedData == nil {
		stagingBuffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_staging_memory_type(
			device.physicalDevice,
			vkField_vk.get_memory_requirements(device, stagingBuffer.(vkField_vk.Buffer)),
		); !memoryTypeOk {
			return {}, {}, .ERROR_OUT_OF_HOST_MEMORY
		}
		_ = vkField_vk.bind_buffer_to_dedicated_memory(&stagingBuffer.(vkField_vk.Buffer), device, memoryType) or_return
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
	buffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER}) or_return
	memoryType, memoryTypeOk := vkField_vk.find_streaming_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer))
	if !memoryTypeOk {
		vkField_vk.destroy_buffer(device, buffer)
		buffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER, .TRANSFER_SRC}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_private_memory_type(device.physicalDevice, vkField_vk.get_memory_requirements(device, buffer));
		   !memoryTypeOk {
			return {}, {}, .ERROR_OUT_OF_HOST_MEMORY
		}
	}
	_ = vkField_vk.bind_buffer_to_dedicated_memory(&buffer, device, memoryType) or_return

	if buffer.mappedData == nil {
		readbackBuffer = vkField_vk.create_buffer(device, auto_cast slice.size(data), {.STORAGE_BUFFER}) or_return
		if memoryType, memoryTypeOk = vkField_vk.find_readback_memory_type(
			device.physicalDevice,
			vkField_vk.get_memory_requirements(device, readbackBuffer.(vkField_vk.Buffer)),
		); !memoryTypeOk {
			return {}, {}, .ERROR_OUT_OF_HOST_MEMORY
		}
		_ = vkField_vk.bind_buffer_to_dedicated_memory(&readbackBuffer.(vkField_vk.Buffer), device, memoryType) or_return
	}
	return
}
