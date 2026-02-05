package vkfield

import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"

import "vendor:glfw"
import vk "vendor:vulkan"

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

SHADER_PULSE_ECHO_COMP :: #load("../shaders/pulse_echo.comp.spv")
SHADER_PULSE_ECHO_CUM_COMP :: #load("../shaders/pulse_echo_cum.comp.spv")

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
	settings:              SimulationSettings,
	module:                dynlib.Library,
	using vkInstance:      vkInstance,
	debugMessenger:        vk.DebugUtilsMessengerEXT,
	window:                glfw.WindowHandle,
	surface:               vk.SurfaceKHR,
	using vkDevice:        vkDevice,
	swapchain:             vkSwapchain,
	shaderModules:         [dynamic]vkShaderModule,
	computePipeline:       vkPipeline,
	computeCommandPool:    vkCommandPool,
	computeDescriptorPool: vkDescriptorPool,
	computeFence:          vk.Fence,
	simulationResources:   vkSimulationResources,
}

vkDevice :: struct {
	physicalDevice: vk.PhysicalDevice,
	device:         vk.Device,
	queueIndices:   QueueFamilyIndices,
	computeQueue:   vk.Queue,
	graphicsQueue:  vk.Queue,
	presentQueue:   vk.Queue,
	transferQueue:  vk.Queue,
}

vkSwapchain :: struct {
	swapchain:     vk.SwapchainKHR,
	images:        []vk.Image,
	views:         []vk.ImageView,
	surfaceFormat: vk.SurfaceFormatKHR,
	presentMode:   vk.PresentModeKHR,
	extent:        vk.Extent2D,
}

vkShaderModule :: struct {
	name:            string,
	entryPoint:      string,
	module:          vk.ShaderModule,
	stageCreateInfo: vk.PipelineShaderStageCreateInfo,
}

shaderInfo :: struct {
	name:       string,
	code:       []byte,
	entryPoint: string,
	stage:      vk.ShaderStageFlags,
}

vkPipeline :: struct {
	descriptorSetLayouts: []vk.DescriptorSetLayout,
	pipelineLayout:       vk.PipelineLayout,
	pipeline:             vk.Pipeline,
}

vkCommandPool :: struct {
	commandPool:    vk.CommandPool,
	commandBuffers: []vk.CommandBuffer,
}

vkBuffer :: struct {
	buffer:        vk.Buffer,
	memory:        vk.DeviceMemory,
	size:          vk.DeviceSize,
	usage:         vk.BufferUsageFlags,
	memoryProps:   vk.MemoryPropertyFlags,
	data:          rawptr,
	stagingBuffer: ^vkBuffer,
}

QueueFamilyIndices :: struct {
	compute:  u32,
	transfer: u32,
	graphics: Maybe(u32),
	present:  Maybe(u32),
}

vkSimulationResources :: struct {
	transmitElements: vkBuffer,
	receiveElements:  vkBuffer,
	scatters:         vkBuffer,
	pulseEcho:        vkBuffer,
	stagingBuffers:   [dynamic]vkBuffer,
}

vkSimulationSettings :: struct {
	samplingFrequency: f32,
	speedOfSound:      f32,
	startingTime:      f32,
	sampleCount:       i32,
	scatterIndex:      i32,
}

vkDescriptorPool :: struct {
	pools:     [dynamic]vk.DescriptorPool,
	poolSizes: []vk.DescriptorPoolSize,
	setCount:  u32,
	sets:      [dynamic]vk.DescriptorSet,
}

vkCreateSimulator :: proc(settings: SimulationSettings, simulator: ^vkSimulator) {
	vkInitialize(simulator)

	simulator.settings = settings
	simulator.vkInstance = vkCreateInstance()
	vk.load_proc_addresses_instance(simulator.instance)
	when ENABLE_VALIDATION_LAYERS {
		vkCreateDebugMessenger(simulator.instance, &simulator.debugMessenger)
	}
	if (!settings.headless) {
		simulator.window = glfw.CreateWindow(800, 600, "Vulkan", nil, nil)
		must(glfw.CreateWindowSurface(simulator.instance, simulator.window, nil, &simulator.surface))
	}

	must(vkPickPhysicalDevice(simulator^, &simulator.physicalDevice))
	must(vkCreateDevice(simulator^, &simulator.vkDevice, &simulator.graphicsQueue, &simulator.presentQueue, &simulator.computeQueue, &simulator.transferQueue))
	// vk.load_proc_addresses_device(simulator.device)

	append(
		&simulator.shaderModules,
		vkCreateShaderModule(simulator^, {name = "Pulse Echo", stage = {.COMPUTE}, entryPoint = "main", code = SHADER_PULSE_ECHO_COMP}),
	)
	append(
		&simulator.shaderModules,
		vkCreateShaderModule(simulator^, {name = "Cumulative Pulse Echo", stage = {.COMPUTE}, entryPoint = "main", code = SHADER_PULSE_ECHO_CUM_COMP}),
	)

	if (!settings.headless) {
		must(vkCreateSwapchain(simulator^, &simulator.swapchain))
	}

	must(vkCreateComputePipeline(simulator^, &simulator.computePipeline))

	must(vkCreateComputeCommandPool(simulator^, &simulator.computeCommandPool))

	must(vkCreateComputeDescriptorSets(simulator^, &simulator.computeDescriptorPool))

	must(vkCreateSyncPrimitives(simulator))

	return
}

vkDestroySimulator :: proc(simulator: ^vkSimulator) {
	for pool in simulator.computeDescriptorPool.pools {
		vk.DestroyDescriptorPool(simulator.device, pool, nil)
	}
	vk.DestroyPipeline(simulator.device, simulator.computePipeline.pipeline, nil)
	vk.DestroyPipelineLayout(simulator.device, simulator.computePipeline.pipelineLayout, nil)
	for layout in simulator.computePipeline.descriptorSetLayouts {
		vk.DestroyDescriptorSetLayout(simulator.device, layout, nil)
	}
	vk.DestroyFence(simulator.device, simulator.computeFence, nil)
	vk.DestroyCommandPool(simulator.device, simulator.computeCommandPool.commandPool, nil)
	for shader in simulator.shaderModules {
		vk.DestroyShaderModule(simulator.device, shader.module, nil)
	}
	delete(simulator.shaderModules)
	vkDestroySwapchain(simulator.device, &simulator.swapchain)
	vk.DestroyDevice(simulator.device, nil)
	if simulator.window != nil {
		glfw.DestroyWindow(simulator.window)
	}
	vk.DestroyDebugUtilsMessengerEXT(simulator.instance, simulator.debugMessenger, nil)
	vk.DestroyInstance(simulator.instance, nil)
	dynlib.unload_library(simulator.module)
	simulator^ = {}
}

vkUploadBuffer :: proc(
	device: vkDevice,
	commandBuffer: vk.CommandBuffer,
	buffer: ^vkBuffer,
	data: []byte,
	stagingBuffers: ^[dynamic]vkBuffer,
	loc := #caller_location,
) {
	vkHostUpload(device, buffer, data, stagingBuffers)
	vkDeviceUpload(commandBuffer, buffer)
}

vkHostUpload :: proc(device: vkDevice, buffer: ^vkBuffer, data: []byte, stagingBuffers: ^[dynamic]vkBuffer, loc := #caller_location) {
	bufferData: rawptr
	staging: bool
	if bufferData = buffer.data; bufferData == nil {
		staging = true
		if buffer.stagingBuffer == nil {
			err := resize(stagingBuffers, len(stagingBuffers) + 1)
			if err != .None { log.panic("Failed to allocate space for staging buffer", loc) }
			vkCreateStagingBuffer(device, buffer^, &stagingBuffers[len(stagingBuffers) - 1])
			buffer.stagingBuffer = &stagingBuffers[len(stagingBuffers) - 1]
		}
		bufferData = buffer.stagingBuffer.data
	}

	mem.copy_non_overlapping(bufferData, raw_data(data), len(data))

	if !staging {
		if .HOST_COHERENT not_in buffer.memoryProps {
			range: vk.MappedMemoryRange = {
				sType  = .MAPPED_MEMORY_RANGE,
				memory = buffer.memory,
				size   = buffer.size,
				offset = 0,
			}
			vk.FlushMappedMemoryRanges(device.device, 1, &range)
		}
	}
}

vkDeviceUpload :: proc(commandBuffer: vk.CommandBuffer, buffer: ^vkBuffer) {
	if buffer.stagingBuffer != nil {
		region: vk.BufferCopy = {
			srcOffset = 0,
			dstOffset = 0,
			size      = buffer.stagingBuffer.size,
		}
		vk.CmdCopyBuffer(commandBuffer, buffer.stagingBuffer.buffer, buffer.buffer, 1, &region)
	}
}

vkDeviceDownload :: proc(device: vkDevice, commandBuffer: vk.CommandBuffer, buffer: ^vkBuffer, stagingBuffers: ^[dynamic]vkBuffer, loc := #caller_location) {
	bufferData: rawptr
	staging: bool
	if bufferData = buffer.data; bufferData == nil {
		staging = true
		if (buffer.stagingBuffer == nil) {
			err := resize(stagingBuffers, len(stagingBuffers) + 1)
			if err != .None { log.panic("Failed to allocate space for staging buffer", loc) }
			vkCreateStagingBuffer(device, buffer^, &stagingBuffers[len(stagingBuffers) - 1])
			buffer.stagingBuffer = &stagingBuffers[len(stagingBuffers) - 1]
		}
		bufferData = buffer.stagingBuffer.data
	}

	if buffer.stagingBuffer != nil {
		region: vk.BufferCopy = {
			srcOffset = 0,
			dstOffset = 0,
			size      = buffer.stagingBuffer.size,
		}
		vk.CmdCopyBuffer(commandBuffer, buffer.buffer, buffer.stagingBuffer.buffer, 1, &region)
	}
}

vkHostDownload :: proc(device: vkDevice, buffer: ^vkBuffer, allocator := context.allocator) -> (data: []byte) {
	bufferData: rawptr
	if buffer.stagingBuffer == nil {
		bufferData = buffer.data
		if .HOST_COHERENT not_in buffer.memoryProps {
			range: vk.MappedMemoryRange = {
				sType  = .MAPPED_MEMORY_RANGE,
				memory = buffer.memory,
				size   = buffer.size,
				offset = 0,
			}
			vk.InvalidateMappedMemoryRanges(device.device, 1, &range)
		}
	} else {
		bufferData = buffer.stagingBuffer.data
	}
	data = make([]byte, buffer.size, allocator)
	mem.copy_non_overlapping(raw_data(data), bufferData, len(data))
	return
}

vkCreateStagingBuffer :: proc(device: vkDevice, buffer: vkBuffer, stagingBuffer: ^vkBuffer, loc := #caller_location) -> vk.Result {
	usage: vk.BufferUsageFlags
	usage |= {.TRANSFER_SRC} if (.TRANSFER_DST in buffer.usage) else {}
	usage |= {.TRANSFER_DST} if (.TRANSFER_SRC in buffer.usage) else {}

	bufferInfo: vk.BufferCreateInfo = {
		sType = .BUFFER_CREATE_INFO,
		flags = {},
		usage = usage,
		size  = buffer.size,
	}
	vkCreateBuffer(device, &bufferInfo, {.HOST_VISIBLE, .HOST_COHERENT}, stagingBuffer, loc) or_return
	return .SUCCESS
}

physicalDeviceExtensions :: proc(device: vk.PhysicalDevice, allocator := context.temp_allocator) -> (exts: []vk.ExtensionProperties, res: vk.Result) {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) or_return

	exts = make([]vk.ExtensionProperties, count, allocator)
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(exts)) or_return

	return
}

findQueueFamilies :: proc(simulator: vkSimulator, device: vk.PhysicalDevice) -> (ids: QueueFamilyIndices) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))

	has_compute := false
	has_transfer := false
	for family, i in families {
		if .GRAPHICS in family.queueFlags {
			ids.graphics = u32(i)
		}

		if .COMPUTE in family.queueFlags {
			ids.compute = u32(i)
			has_compute = true
		}

		if .TRANSFER in family.queueFlags {
			ids.transfer = u32(i)
			has_transfer = true
		}

		if !simulator.settings.headless {
			supported: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), simulator.surface, &supported)
			if supported {
				ids.present = u32(i)
			}
		}

		// Found all needed queues?
		_, has_graphics := ids.graphics.?
		_, has_present := ids.present.?
		if has_compute && has_transfer && has_graphics && (simulator.settings.headless || has_present) {
			break
		}
	}

	return
}

SwapchainSupport :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	formats:      []vk.SurfaceFormatKHR,
	presentModes: []vk.PresentModeKHR,
}

querySwapchainSupport :: proc(
	device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	allocator := context.temp_allocator,
) -> (
	support: SwapchainSupport,
	result: vk.Result,
) {
	// NOTE: looks like a wrong binding with the third arg being a multipointer.
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &support.capabilities) or_return

	{
		count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, nil) or_return

		support.formats = make([]vk.SurfaceFormatKHR, count, allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, raw_data(support.formats)) or_return
	}

	{
		count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, nil) or_return

		support.presentModes = make([]vk.PresentModeKHR, count, allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, raw_data(support.presentModes)) or_return
	}

	return
}

chooseSwapchainSurfaceFormat :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}

	// Fallback non optimal.
	return formats[0]
}

chooseSwapchainPresentMode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	// We would like mailbox for the best tradeoff between tearing and latency.
	for mode in modes {
		if mode == .MAILBOX {
			return .MAILBOX
		}
	}

	// As a fallback, fifo (basically vsync) is always available.
	return .FIFO
}

chooseSwapchainExtent :: proc(capabilities: vk.SurfaceCapabilitiesKHR, window: glfw.WindowHandle) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	}

	width, height := glfw.GetFramebufferSize(window)
	return (vk.Extent2D {
				width = clamp(u32(width), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
				height = clamp(u32(height), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
			})
}

findMemoryType :: proc(device: vk.PhysicalDevice, typeFilter: u32, properties: vk.MemoryPropertyFlags) -> (type: u32, ok: bool = true) {
	memProperties: vk.PhysicalDeviceMemoryProperties2 = {
		sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
	}
	vk.GetPhysicalDeviceMemoryProperties2(device, &memProperties)
	memProps := memProperties.memoryProperties
	typeFilter := typeFilter
	for ; typeFilter != 0 && type < memProps.memoryTypeCount; typeFilter &~= 1 << type {
		type = intrinsics.count_trailing_zeros(typeFilter)
		if properties <= memProps.memoryTypes[type].propertyFlags {
			return
		}
	}
	ok = false
	return
}

byte_arr_str :: proc(arr: ^[$N]byte) -> string {
	return strings.truncate_to_byte(string(arr[:]), 0)
}

vk_messenger_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	debugLogger: ^log.Logger = auto_cast pUserData
	context = runtime.default_context()
	context.logger = debugLogger^

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	if .ERROR in messageSeverity {
		// runtime.debug_trap()
	}
	return false
}

must :: proc(result: vk.Result, loc := #caller_location) {
	if result != .SUCCESS {
		log.panicf("vulkan failure %v", result, location = loc)
	}
}
