package vkfield

import "base:intrinsics"
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

SHADER_PULSE_ECHO_COMP                    :: #load("shaders/pulseEcho.spv")
SHADER_PACK_SIR_COMP :: #load("shaders/packSpatialImpulseResponse.spv")

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
	instance:        vkField_vk.Instance,
	debugUserData:   ^vkField_vk.DebugUserData,
	debugMessenger:  vkField_vk.DebugMessenger,
	physicalDevices: #soa[]vkField_vk.PhysicalDevice,
	device:          vkField_vk.Device,

	simulationResources : vkSimulationResources,

	pulseEchoPipelineLayout: vk.PipelineLayout,
	packSirPipelineLayout:   vk.PipelineLayout,

	computeDescriptorSetLayout: vkField_vk.DescriptorSetLayout,
	computeCommandPool:         vkField_vk.CommandPool,
	computeDescriptorPool:      vkField_vk.DescriptorPool,
	computeFence:               vk.Fence,
}

vkSimulationResources :: union {
	vkPulseEchoSimulationResources,
}

vkPulseEchoSimulationResources :: struct {
	elementsBuffer: vkStagableBuffer,
	scattersBuffer: vkStagableBuffer,
	responseBuffer: vkStagableBuffer,
	sirBuffer: vkField_vk.Buffer,
	packSirPipeline: vkField_vk.ComputePipeline(vkPackSirSpecConstants),
	pulseEchoPipeline: vkField_vk.ComputePipeline(vkPulseEchoSpecConstants),
}

vkPackSirPushConstants :: struct {
	elements                : vk.DeviceAddress,
	scatters                : vk.DeviceAddress,
	spatialImpulseResponses : vk.DeviceAddress,
	scatterBatchOffset : u32,
	receiveBatchOffset : u32,
}

vkPackSirSpecConstants :: struct {
	WorkgroupSizeX    : u32,
	WorkgroupSizeY    : u32,
	WorkgroupSizeZ    : u32,
	TransmitCount     : u32,
	ReceiveCount      : u32,
	ScatterCount      : u32,
	ReceiveBatchCount : u32,
	ScatterBatchCount : u32,
	Cumulative        : u32,
	StartTime         : f32,
	SamplingFrequency : f32,
	SpeedOfSound      : f32,
}

vkPulseEchoPushConstants :: struct {
	spatialImpulseResponses: vk.DeviceAddress,
	response:                vk.DeviceAddress,
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

vkStagableBuffer :: struct {
	main: vkField_vk.Buffer,
	staging : Maybe(vkField_vk.Buffer),
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
	requiredCapabilities: vkField_vk.DeviceCapabilities = {.Synchronization2, .Maintenance4, .BufferDeviceAddress}
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

	simulator.packSirPipelineLayout = check(
		vkField_vk.create_pipeline_layout(
			simulator.device,
			{simulator.computeDescriptorSetLayout.layout},
			{{stageFlags = {.COMPUTE}, size = size_of(vkPackSirPushConstants), offset = 0}},
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
	destroy_vulkan_simulator_resources(simulator)
	
	vkField_vk.destroy_fence(simulator.device, simulator.computeFence)
	vkField_vk.destroy_command_pool(simulator.device, simulator.computeCommandPool)
	vkField_vk.destroy_descriptor_pool(simulator.device, simulator.computeDescriptorPool)

	vkField_vk.destroy_pipeline_layout(simulator.device, simulator.pulseEchoPipelineLayout)
	vkField_vk.destroy_pipeline_layout(simulator.device, simulator.packSirPipelineLayout)

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

plan_vulkan_simulator :: proc(simulator: ^vkSimulator, settings: SimulationSettings) -> (result: vk.Result) {
	destroy_vulkan_simulator_resources(simulator)

	device := simulator.device

	elementTotalSize := vkElementBufferSize(settings)

	elementsBuffer := check(prepare_stream(device, elementTotalSize)) or_return
	scattersBuffer := check(prepare_stream(device, size_of(Scatter) * auto_cast settings.scatterCount)) or_return
	responseBuffer := check(prepare_readback(device, size_of(f32) * auto_cast (settings.receiveElementCount * settings.sampleCount))) or_return

	packSirWorkGroupSize :[3]u32: {4, 4, 4}

	sirBufferSize  :: 32 * runtime.Megabyte
	sirPerScatterSize :: size_of([4]f32) + size_of(f32) // Size of Spatial Impulse Response Rectangle Control Points + Scaling Factor
	scatterBatchCount    := u32(settings.scatterCount)
	receiveBatchCount    := u32(settings.receiveElementCount)
	sirTotalSize  := u32(sirPerScatterSize * scatterBatchCount * (receiveBatchCount + u32(settings.transmitElementCount)))

	// Batch Receives to reduce temp buffer size
	if sirTotalSize > sirBufferSize {
		maxReceiveBatchCount := min(u32(settings.receiveElementCount), device.physicalDevice.properties.limits.maxComputeWorkGroupCount.y * packSirWorkGroupSize.y)
		receiveBatchCount     = clamp((sirBufferSize / (sirPerScatterSize * scatterBatchCount)) - u32(settings.transmitElementCount), 1, maxReceiveBatchCount)
		sirTotalSize   = u32(size_of([4]f32) * scatterBatchCount * (receiveBatchCount + u32(settings.transmitElementCount)))
	}

	// Batch Scatters to reduce temp buffer size
	if sirTotalSize > sirBufferSize {
		maxScatterBatchCount := min(u32(settings.scatterCount), device.physicalDevice.properties.limits.maxComputeWorkGroupCount.x * packSirWorkGroupSize.x)
		scatterBatchCount = clamp(sirBufferSize / (sirPerScatterSize * (receiveBatchCount + u32(settings.transmitElementCount))), 1, maxScatterBatchCount)
		sirTotalSize  = u32(size_of([4]f32) * scatterBatchCount * (receiveBatchCount + u32(settings.transmitElementCount)))
	}

	assert(sirTotalSize <= sirBufferSize)
	sirBuffer := check(device_buffer(device, auto_cast sirTotalSize)) or_return

	// NOTE(rnp): specialize shaders
	packSirPipeline := check(
		vkField_vk.create_compute_pipeline(
			simulator.device,
			{kind = .Compute, code = SHADER_PACK_SIR_COMP, entryPoints = {{name = "main", stage = .COMPUTE}}},
			simulator.packSirPipelineLayout,
			vkPackSirSpecConstants {
				WorkgroupSizeX    = 4,
				WorkgroupSizeY    = 4,
				WorkgroupSizeZ    = 4,
				TransmitCount     = u32(settings.transmitElementCount),
				ReceiveCount      = u32(settings.receiveElementCount),
				ScatterCount      = u32(settings.scatterCount),
				ReceiveBatchCount = u32(receiveBatchCount),
				ScatterBatchCount = u32(scatterBatchCount),
				Cumulative        = settings.cumulative ? 1 : 0,
				StartTime         = settings.startTime,
				SamplingFrequency = settings.samplingFrequency,
				SpeedOfSound      = settings.speedOfSound,
			},
			"Pack Spatial Impulse Response",
		),
	) or_return
	
	pulseEchoPipeline := check(
		vkField_vk.create_compute_pipeline(
			device,
			{kind = .Compute, code = SHADER_PULSE_ECHO_COMP, entryPoints = {{name = "main", stage = .COMPUTE}}},
			simulator.pulseEchoPipelineLayout,
			vkPulseEchoSpecConstants {
				// TODO(rnp): subgroup size
				WorkgroupSizeX    = 64,
				SampleCount       = u32(settings.sampleCount),
				TransmitCount     = u32(settings.transmitElementCount),
				ReceiveBatchCount = u32(receiveBatchCount),
				ScatterBatchCount = u32(scatterBatchCount),
				Cumulative        = settings.cumulative ? 1 : 0,
			},
			"Pulse Echo",
		),
	) or_return
	
	simulator.simulationResources = vkPulseEchoSimulationResources {
		elementsBuffer = elementsBuffer,
		scattersBuffer = scattersBuffer,
		responseBuffer = responseBuffer,
		sirBuffer = sirBuffer,
		packSirPipeline = packSirPipeline,
		pulseEchoPipeline = pulseEchoPipeline,
	}
	return
}

destroy_vulkan_simulator_resources :: proc(simulator : ^vkSimulator) {
	device := simulator.device

	switch resources in simulator.simulationResources {
	case vkPulseEchoSimulationResources:
		vkField_vk.destroy_compute_pipeline(device, resources.pulseEchoPipeline)
		vkField_vk.destroy_compute_pipeline(device, resources.packSirPipeline)

		release_staged_buffer(device, resources.elementsBuffer)
		release_staged_buffer(device, resources.scattersBuffer)
		release_staged_buffer(device, resources.responseBuffer)
		vkField_vk.release_buffer(device, resources.sirBuffer)
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
	transmitElements: []Element,
	receiveElements: []Element,
	scatters: []Scatter,
	allocator := context.allocator,
) -> (
	response: []f32,
	result: vk.Result,
) {
	resources, pulseEchoResourcesOk := simulator.simulationResources.(vkPulseEchoSimulationResources)
	if !check(pulseEchoResourcesOk) do return {}, .ERROR_INITIALIZATION_FAILED

	device := simulator.device

	elements := vkPackElementBuffer(settings, transmitElements, receiveElements)
	response = make([]f32, resources.responseBuffer.main.size / size_of(f32), allocator)

	commandBuffer := check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return
	defer vkField_vk.reset_command_buffer(device, &simulator.computeCommandPool, commandBuffer)

	commandBeginInfo: vk.CommandBufferBeginInfo = {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	check(vk.BeginCommandBuffer(commandBuffer, &commandBeginInfo)) or_return

	vkField_vk.cmd_upload(commandBuffer, elements, 
		resources.elementsBuffer.main, resources.elementsBuffer.staging.? or_else {})
	vkField_vk.cmd_upload(commandBuffer, slice.to_bytes(scatters), 
		resources.scattersBuffer.main, resources.scattersBuffer.staging.? or_else {})
	vkField_vk.cmd_clear_buffer(commandBuffer, resources.responseBuffer.main)

	vkField_vk.cmd_pipeline_barrier(
		commandBuffer,
		{},
		{
			{
				buffer = resources.elementsBuffer.main.buffer,
				size   = resources.elementsBuffer.main.size,
				srcStageMask  = {.TRANSFER, .HOST},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask  = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ},
			},
			{
				buffer = resources.scattersBuffer.main.buffer,
				size   = resources.scattersBuffer.main.size,
				srcStageMask  = {.TRANSFER, .HOST},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask  = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ},
			},
			{
				buffer = resources.responseBuffer.main.buffer,
				size   = resources.responseBuffer.main.size,
				offset = 0,
				srcStageMask  = {.TRANSFER, .HOST},
				srcAccessMask = {.TRANSFER_WRITE, .HOST_WRITE},
				dstStageMask  = {.COMPUTE_SHADER},
				dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
			},
		},
		{},
	)

	sirSpecConstants := resources.packSirPipeline.specializationConstants
	pulseEchoConstants := resources.pulseEchoPipeline.specializationConstants
	for receiveOffset : u32 = 0; receiveOffset < u32(settings.receiveElementCount); receiveOffset += u32(sirSpecConstants.ReceiveBatchCount) {
		for scatterOffset : u32 = 0; scatterOffset < u32(settings.scatterCount); scatterOffset += u32(sirSpecConstants.ScatterBatchCount) {
			vkField_vk.cmd_pipeline_barrier(
				commandBuffer,
				{},
				{
					{
						buffer        = resources.sirBuffer.buffer,
						size          = resources.sirBuffer.size,
						offset        = 0,
						srcStageMask  = {.COMPUTE_SHADER},
						srcAccessMask = {.SHADER_READ},
						dstStageMask  = {.COMPUTE_SHADER},
						dstAccessMask = {.SHADER_WRITE},
					},
				},
				{},
			)

			vk.CmdBindPipeline(commandBuffer, .COMPUTE, resources.packSirPipeline.pipeline)

			vkField_vk.cmd_push_constants(commandBuffer, simulator.packSirPipelineLayout, {.COMPUTE}, 
				vkPackSirPushConstants {
					elements = vkField_vk.get_buffer_address(device, resources.elementsBuffer.main),
					scatters = vkField_vk.get_buffer_address(device, resources.scattersBuffer.main),
					spatialImpulseResponses = vkField_vk.get_buffer_address(device, resources.sirBuffer),
					scatterBatchOffset = scatterOffset,
					receiveBatchOffset = receiveOffset,
			})

			vk.CmdDispatch(
				commandBuffer,
				u32(math.ceil(f32(sirSpecConstants.ScatterBatchCount) / f32(sirSpecConstants.WorkgroupSizeX))),
				u32(math.ceil(f32(sirSpecConstants.ReceiveBatchCount) / f32(sirSpecConstants.WorkgroupSizeY))),
				u32(math.ceil(f32(sirSpecConstants.TransmitCount)     / f32(sirSpecConstants.WorkgroupSizeZ))),
			)

			vkField_vk.cmd_pipeline_barrier(
				commandBuffer,
				{},
				{
					{
						buffer        = resources.sirBuffer.buffer,
						size          = resources.sirBuffer.size,
						offset        = 0,
						srcStageMask  = {.COMPUTE_SHADER},
						srcAccessMask = {.SHADER_WRITE},
						dstStageMask  = {.COMPUTE_SHADER},
						dstAccessMask = {.SHADER_READ},
					},
					{
						buffer        = resources.responseBuffer.main.buffer,
						size          = resources.responseBuffer.main.size,
						offset        = 0,
						srcStageMask  = {.COMPUTE_SHADER},
						srcAccessMask = {.SHADER_WRITE},
						dstStageMask  = {.COMPUTE_SHADER},
						dstAccessMask = {.SHADER_READ},
					},
				},
				{},
			)

			vk.CmdBindPipeline(commandBuffer, .COMPUTE, resources.pulseEchoPipeline.pipeline)
			vkField_vk.cmd_push_constants(commandBuffer, simulator.pulseEchoPipelineLayout, {.COMPUTE}, 
				vkPulseEchoPushConstants {
					spatialImpulseResponses = vkField_vk.get_buffer_address(device, resources.sirBuffer),
					response = vkField_vk.get_buffer_address(device, resources.responseBuffer.main),
					receiveBatchOffset = receiveOffset,
			})
			
			vk.CmdDispatch(
				commandBuffer,
				u32(math.ceil(f32(pulseEchoConstants.SampleCount) / f32(pulseEchoConstants.WorkgroupSizeX))),
				pulseEchoConstants.ReceiveBatchCount,
				1,
			)
		}
	}

	vkField_vk.cmd_pipeline_barrier(
		commandBuffer,
		{},
		{
			{
				buffer = resources.responseBuffer.main.buffer,
				size   = resources.responseBuffer.main.size,
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

	check(vk.QueueSubmit2(device.queues[device.computeQueueIndex], 1, &submitInfo, simulator.computeFence)) or_return
	check(vk.WaitForFences(device.device, 1, &simulator.computeFence, true, auto_cast time.duration_nanoseconds(auto_cast DISPATCH_TIMEOUT))) or_return
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

prepare_stream :: proc(
	device: vkField_vk.Device,
	size: vk.DeviceSize,
) -> (
	buffer: vkStagableBuffer,
	result: vk.Result,
) {
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
		if memoryType, memoryTypeOk = vkField_vk.find_staging_memory_type(
			device.physicalDevice,
			vkField_vk.get_memory_requirements(device, stagingBuffer),
		); !memoryTypeOk {
			return {}, .ERROR_OUT_OF_HOST_MEMORY
		}
		vkField_vk.bind_buffer_to_dedicated_memory(device, &stagingBuffer, memoryType) or_return
		buffer.staging = stagingBuffer
	}
	return
}

prepare_readback :: proc(
	device: vkField_vk.Device,
	size: vk.DeviceSize,
) -> (
	buffer: vkStagableBuffer,
	result: vk.Result,
) {
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
		if memoryType, memoryTypeOk = vkField_vk.find_readback_memory_type(
			device.physicalDevice,
			vkField_vk.get_memory_requirements(device, readbackBuffer),
		); !memoryTypeOk {
			return {}, .ERROR_OUT_OF_HOST_MEMORY
		}
		vkField_vk.bind_buffer_to_dedicated_memory(device, &readbackBuffer, memoryType) or_return
		buffer.staging = readbackBuffer
	}
	return
}

vkPackElementBuffer :: proc(settings: SimulationSettings, transmitElements: []Element, receiveElements: []Element) -> []byte {
	assert(len(transmitElements) == auto_cast settings.transmitElementCount)
	assert(len(receiveElements) == auto_cast settings.receiveElementCount)
	elementTotalSize := vkElementBufferSize(settings)
	elementCount : int = auto_cast (settings.transmitElementCount + settings.receiveElementCount)
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
	
	for element, index in transmitElements {
		positions[index] = element.aperture.rectangle.position
		normals[index] = element.aperture.rectangle.normal
		sizes[index] = element.aperture.rectangle.size
		apodizations[index] = element.apodization
		delays[index] = element.delay
	}
	for element, index in receiveElements {
		receiveIndex := index + auto_cast settings.transmitElementCount
		positions[receiveIndex] = element.aperture.rectangle.position
		normals[receiveIndex] = element.aperture.rectangle.normal
		sizes[receiveIndex] = element.aperture.rectangle.size
		apodizations[receiveIndex] = element.apodization
		delays[receiveIndex] = element.delay
	}
	return rectangularElements
}

vkElementBufferSize :: proc(settings: SimulationSettings) -> vk.DeviceSize {
	elementTotalSize: vk.DeviceSize
	elementTotalSize += size_of([3]f32) // Position
	elementTotalSize += size_of([3]f32) // Normals
	elementTotalSize += size_of([2]f32) // Sizes
	elementTotalSize += size_of(f32) // Apodizations
	elementTotalSize += size_of(f32) // Delays
	elementTotalSize *= auto_cast (settings.transmitElementCount + settings.receiveElementCount)
	return elementTotalSize
}
