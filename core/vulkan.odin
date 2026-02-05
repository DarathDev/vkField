package vkfield

import "base:runtime"
import "core:dynlib"
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

when ODIN_OS == .Darwin {
	// NOTE: just a bogus import of the system library,
	// needed so we can add a linker flag to point to /usr/local/lib (where vulkan is installed by default)
	// when trying to load vulkan.
	@(require, extra_linker_flags = "-rpath /usr/local/lib")
	foreign import __ "system:System.framework"
}

ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)

MAX_FRAMES_IN_FLIGHT :: 2

USE_CUMULATIVE_COMPUTE :: #config(USE_CUMULATIVE_COMPUTE, true)

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
	settings:                   SimulationSettings,
	module:                     dynlib.Library,
	instance:                   vkField_vk.Instance,
	debugUserData:              vkField_vk.DebugUserData,
	debugMessenger:             vkField_vk.DebugMessenger,
	physicalDevices:            #soa[]vkField_vk.PhysicalDevice,
	device:                     vkField_vk.Device,
	shaderModule:               vk.ShaderModule,
	computePipelineLayout:      vk.PipelineLayout,
	computeDescriptorSetLayout: vkField_vk.DescriptorSetLayout,
	computePipeline:            vk.Pipeline,
	computeCommandPool:         vkField_vk.CommandPool,
	computeDescriptorPool:      vkField_vk.DescriptorPool,
	computeFence:               vk.Fence,
}

vkSimulationSettings :: struct {
	samplingFrequency: f32,
	speedOfSound:      f32,
	startingTime:      f32,
	sampleCount:       i32,
	scatterIndex:      i32,
}

vkCreateSimulator :: proc(settings: SimulationSettings, simulator: ^vkSimulator) -> (ok := vk.Result.SUCCESS) {
	simulator.settings = settings

	simulator.debugUserData.logger = context.logger
	simulator.instance = confirm(
		vkField_vk.create_instance({appName = "vkField", presentable = true, vulkanVersion = vk.API_VERSION_1_3}, debugUserData = &simulator.debugUserData),
	) or_return

	when ENABLE_VALIDATION_LAYERS {
		simulator.debugMessenger = confirm(vkField_vk.create_debug_messenger(simulator.instance, &simulator.debugUserData)) or_return
	}

	if (!settings.headless) do vkField_util.throw_not_implemented()
	simulator.physicalDevices = vkField_vk.get_physical_devices(simulator.instance.instance) or_return
	requiredCapabilities: vkField_vk.DeviceCapabilities = {.AtomicAddFloat32Buffer, .Synchronization2}
	physicalDevice, physicalDeviceAvailable := vkField_vk.pick_physical_device(
		simulator.instance.instance,
		simulator.physicalDevices,
		{requiredCapabilities = requiredCapabilities},
	)
	if !physicalDeviceAvailable do return vk.Result.ERROR_DEVICE_LOST
	simulator.device = check(vkField_vk.create_device(simulator.instance, physicalDevice, {requiredCapabilities = requiredCapabilities})) or_return

	shaderCode := !settings.cumulative ? SHADER_PULSE_ECHO_COMP : SHADER_PULSE_ECHO_CUMULATIVE_COMP
	shaderCodeLabel := !settings.cumulative ? "Pulse Echo" : "Cumulative Pulse Echo"

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
			{{stageFlags = {.COMPUTE}, size = size_of(vkSimulationSettings), offset = 0}},
		),
	) or_return
	simulator.shaderModule, simulator.computePipeline = check(
		vkField_vk.create_compute_pipeline(
			simulator.device,
			{kind = .Compute, code = shaderCode, entryPoints = {{name = "main", stage = .COMPUTE}}},
			simulator.computePipelineLayout,
			shaderCodeLabel,
		),
	) or_return
	simulator.computeCommandPool = check(vkField_vk.create_command_pool(simulator.device, simulator.device.computeQueueIndex, true)) or_return
	simulator.computeDescriptorPool = check(
		vkField_vk.create_descriptor_pool(simulator.device, 1, simulator.computeDescriptorSetLayout, label = "Compute"),
	) or_return
	simulator.computeFence = check(vkField_vk.create_fence(simulator.device, label = "Compute")) or_return

	return
}

vkDestroySimulator :: proc(simulator: ^vkSimulator) {
	vkField_vk.destroy_fence(simulator.device, simulator.computeFence)
	vkField_vk.destroy_command_pool(simulator.device, simulator.computeCommandPool)
	vkField_vk.destroy_descriptor_pool(simulator.device, simulator.computeDescriptorPool)
	vkField_vk.destroy_pipeline(simulator.device, simulator.computePipeline)
	vkField_vk.destroy_pipeline_layout(simulator.device, simulator.computePipelineLayout)
	vkField_vk.destroy_descriptor_set_layout(simulator.device, simulator.computeDescriptorSetLayout)
	vkField_vk.destroy_shader_module(simulator.device, simulator.shaderModule)
	vkField_vk.destroy_device(&simulator.device)
	vkField_vk.free_physical_devices(&simulator.physicalDevices)
	when ENABLE_VALIDATION_LAYERS {
		vkField_vk.destroy_debug_messenger(simulator.instance.instance, &simulator.debugMessenger)
	}
	vkField_vk.destroy_instance(&simulator.instance)
	simulator^ = {}
}

vkSimulate :: proc(
	simulator: ^vkSimulator,
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
	settings := simulator.settings

	response = make([]f32, simulator.settings.receiveElementCount * simulator.settings.sampleCount, allocator)

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

	// responseBufferView := check(vkField_vk.create_buffer_view(device, responseBuffer, .R32_SFLOAT)) or_return
	// defer vkField_vk.destroy_buffer_view(device, responseBufferView)

	vk.CmdBindPipeline(commandBuffer, .COMPUTE, simulator.computePipeline)

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

	simSettings := vkSimulationSettings {
		samplingFrequency = settings.samplingFrequency,
		speedOfSound      = settings.speedOfSound,
		startingTime      = settings.startTime,
		sampleCount       = settings.sampleCount,
	}

	// dispatch
	for i: int; i < int(settings.scatterCount); i += 1 {
		simSettings.scatterIndex = i32(i)
		vkField_vk.cmd_push_constants(commandBuffer, simulator.computePipelineLayout, {.COMPUTE}, simSettings)
		vk.CmdDispatch(
			commandBuffer,
			u32(math.ceil(f32(simulator.settings.sampleCount) / 128)),
			u32(settings.transmitElementCount),
			u32(settings.receiveElementCount),
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
	check(vk.WaitForFences(device.device, 1, &computeFence, true, auto_cast time.duration_nanoseconds(auto_cast 10 * time.Second))) or_return
	vkField_vk.read_from_buffer(downloadBuffer, slice.to_bytes(response))
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
