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

USE_CUMULATIVE_COMPUTE :: #config(USE_CUMULATIVE_COMPUTE, true)

VKFIELD_SAMPLE_GROUP_X := #config(SAMPLE_GROUP_X, 128)
VKFIELD_RECEIVE_GROUP_Y := #config(RECEIVE_GROUP_Y, 16)
VKFIELD_SCATTER_REDUCTION_Z := #config(SCATTER_REDUCTION_Z, 8)

SHADER_PULSE_ECHO_COMP :: #load("shaders/pulse_echo.spv")
SHADER_PULSE_ECHO_CUMULATIVE_COMP :: #load("shaders/pulse_echo_cumulative.spv")

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
	shaderModules:              [dynamic]vk.ShaderModule,
	computePipelineLayout:      vk.PipelineLayout,
	using computePipelines:     vkPipelines,
	computeDescriptorSetLayout: vkField_vk.DescriptorSetLayout,
	computeCommandPool:         vkField_vk.CommandPool,
	computeDescriptorPool:      vkField_vk.DescriptorPool,
	computeFence:               vk.Fence,
}

vkPipelines :: struct {
	pulseEcho:           vkField_vk.ComputePipeline,
	pulseEchoCumulative: vkField_vk.ComputePipeline,
}

vkSimulationPushConstants :: struct {
	samplingFrequency: f32,
	speedOfSound:      f32,
	startingTime:      f32,
	sampleCount:       i32,
	receiveStart:      i32,
	receiveCount:      i32,
	transmitCount:     i32,
	transmitStart:     i32,
	transmitBatchCount: i32,
	scatterCount:      i32,
}

create_vulkan_simulator :: proc() -> (simulator: vkSimulator, ok := vk.Result.SUCCESS) {
	simulator.debugUserData = new(vkField_vk.DebugUserData)
	simulator.debugUserData.logger = context.logger
	simulator.instance = confirm(
		vkField_vk.create_instance({appName = "vkField", presentable = true, vulkanVersion = vk.API_VERSION_1_3}, debugUserData = simulator.debugUserData),
	) or_return

	when ENABLE_VALIDATION_LAYERS {
		simulator.debugMessenger = confirm(vkField_vk.create_debug_messenger(simulator.instance, simulator.debugUserData)) or_return
	}

	simulator.physicalDevices = vkField_vk.get_physical_devices(simulator.instance.instance) or_return
	requiredCapabilities: vkField_vk.DeviceCapabilities = {.AtomicAddFloat32Buffer, .Synchronization2}
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
			},
		),
	) or_return
	simulator.computePipelineLayout = check(
		vkField_vk.create_pipeline_layout(
			simulator.device,
			{simulator.computeDescriptorSetLayout.layout},
			{{stageFlags = {.COMPUTE}, size = size_of(vkSimulationPushConstants), offset = 0}},
		),
	) or_return

	simulator.pulseEcho = check(
		vkField_vk.create_compute_pipeline(
			simulator.device,
			{kind = .Compute, code = SHADER_PULSE_ECHO_COMP, entryPoints = {{name = "main", stage = .COMPUTE}}},
			simulator.computePipelineLayout,
			"Pulse Echo",
		),
	) or_return
	simulator.pulseEchoCumulative = check(
		vkField_vk.create_compute_pipeline(
			simulator.device,
			{kind = .Compute, code = SHADER_PULSE_ECHO_CUMULATIVE_COMP, entryPoints = {{name = "main", stage = .COMPUTE}}},
			simulator.computePipelineLayout,
			"Cumulative Pulse Echo",
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
	vkField_vk.destroy_compute_pipeline(simulator.device, simulator.pulseEcho)
	vkField_vk.destroy_compute_pipeline(simulator.device, simulator.pulseEchoCumulative)
	vkField_vk.destroy_pipeline_layout(simulator.device, simulator.computePipelineLayout)
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

	response = make([]f32, settings.receiveElementCount * settings.sampleCount, allocator)

	commandBuffer := check(vkField_vk.get_command_buffer(device, &simulator.computeCommandPool)) or_return
	defer vkField_vk.reset_command_buffer(device, &simulator.computeCommandPool, commandBuffer)

	commandBeginInfo: vk.CommandBufferBeginInfo = {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	check(vk.BeginCommandBuffer(commandBuffer, &commandBeginInfo)) or_return

	transmitElementsBuffer, transmitElementsStagingBuffer := check(stream(device, commandBuffer, transmitElements)) or_return
	receiveElementsBuffer, receiveElementsStagingBuffer := check(stream(device, commandBuffer, receiveElements)) or_return
	scattersBuffer, scattersStagingBuffer := check(stream(device, commandBuffer, scatters)) or_return
	responseBuffer, responseReadbackBuffer := check(prepare_readback(device, commandBuffer, response)) or_return
	defer {
		vk.FreeMemory(device.device, transmitElementsBuffer.deviceMemory, nil)
		vk.FreeMemory(device.device, receiveElementsBuffer.deviceMemory, nil)
		vk.FreeMemory(device.device, scattersBuffer.deviceMemory, nil)
		vk.FreeMemory(device.device, responseBuffer.deviceMemory, nil)
		vkField_vk.destroy_buffer(device, transmitElementsBuffer)
		vkField_vk.destroy_buffer(device, receiveElementsBuffer)
		vkField_vk.destroy_buffer(device, scattersBuffer)
		vkField_vk.destroy_buffer(device, responseBuffer)

		if buffer, bufferOk := transmitElementsStagingBuffer.?; bufferOk {
			vk.FreeMemory(device.device, buffer.deviceMemory, nil)
			vkField_vk.destroy_buffer(device, buffer)
		}
		if buffer, bufferOk := receiveElementsStagingBuffer.?; bufferOk {
			vk.FreeMemory(device.device, buffer.deviceMemory, nil)
			vkField_vk.destroy_buffer(device, buffer)
		}
		if buffer, bufferOk := scattersStagingBuffer.?; bufferOk {
			vk.FreeMemory(device.device, buffer.deviceMemory, nil)
			vkField_vk.destroy_buffer(device, buffer)
		}
		if buffer, bufferOk := responseReadbackBuffer.?; bufferOk {
			vk.FreeMemory(device.device, buffer.deviceMemory, nil)
			vkField_vk.destroy_buffer(device, buffer)
		}
	}

	// Initialize response to zero for atomic accumulation.
	vkField_vk.cmd_upload(commandBuffer, slice.to_bytes(response), responseBuffer)

	if !settings.cumulative do vk.CmdBindPipeline(commandBuffer, .COMPUTE, simulator.pulseEcho.pipeline)
	else do vk.CmdBindPipeline(commandBuffer, .COMPUTE, simulator.pulseEchoCumulative.pipeline)

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

	vkField_vk.update_descriptor_sets(
		device,
		{
			{dstSet = descriptorSet, dstBinding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &transmitElementsDescriptor},
			{dstSet = descriptorSet, dstBinding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &receiveElementsDescriptor},
			{dstSet = descriptorSet, dstBinding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &scattersDescriptor},
			{dstSet = descriptorSet, dstBinding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &responseDescriptor},
		},
	)

	vk.CmdBindDescriptorSets(commandBuffer, vk.PipelineBindPoint.COMPUTE, simulator.computePipelineLayout, 0, 1, &descriptorSet, 0, nil)

	simSettings := vkSimulationPushConstants {
		samplingFrequency = settings.samplingFrequency,
		speedOfSound      = settings.speedOfSound,
		startingTime      = settings.startTime,
		sampleCount       = settings.sampleCount,
		receiveStart      = 0,
		transmitCount     = settings.transmitElementCount,
		receiveCount      = settings.receiveElementCount,
		scatterCount      = settings.scatterCount,
	}
	workLimit := settings.dispatchWorkLimit
	if workLimit <= 0 {
		workLimit = 1 << 24
	}

	for receiveStart: i32 = 0; receiveStart < simSettings.receiveCount; receiveStart += i32(VKFIELD_RECEIVE_GROUP_Y) {
		simSettings.receiveStart = receiveStart
		receiveBatchCount := min(simSettings.receiveCount - receiveStart, i32(VKFIELD_RECEIVE_GROUP_Y))
		if receiveBatchCount < 1 {
			continue
		}

		workPerTransmit := i64(max(1, simSettings.sampleCount)) * i64(receiveBatchCount) * i64(max(1, simSettings.scatterCount))
		if workPerTransmit < 1 {
			workPerTransmit = 1
		}
		simSettings.transmitBatchCount = 1

		for transmitStart: i32 = 0; transmitStart < simSettings.transmitCount; transmitStart += simSettings.transmitBatchCount {
			simSettings.transmitStart = transmitStart
			transmitRemaining := simSettings.transmitCount - transmitStart
			transmitBatchCount := i32(max(1, min(transmitRemaining, i32(i64(workLimit) / workPerTransmit))))
			simSettings.transmitBatchCount = transmitBatchCount
			vkField_vk.cmd_push_constants(commandBuffer, simulator.computePipelineLayout, {.COMPUTE}, simSettings)
			vk.CmdDispatch(
				commandBuffer,
				u32(math.ceil(f32(settings.sampleCount) / f32(VKFIELD_SAMPLE_GROUP_X))),
				u32(VKFIELD_RECEIVE_GROUP_Y),
				u32(math.ceil(f32(settings.scatterCount) / f32(VKFIELD_SCATTER_REDUCTION_Z))),
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
	check(vk.WaitForFences(device.device, 1, &computeFence, true, auto_cast time.duration_nanoseconds(auto_cast 100 * time.Second))) or_return
	vkField_vk.read_from_buffer(downloadBuffer, slice.to_bytes(response))
	vk.DeviceWaitIdle(device.device) or_return
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
