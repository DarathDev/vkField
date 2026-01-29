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
	renderPass:            vk.RenderPass,
	framebuffers:          []vk.Framebuffer,
	graphicsPipeline:      vkPipeline,
	computePipeline:       vkPipeline,
	computeCommandPool:    vkCommandPool,
	computeDescriptorPool: vkDescriptorPool,
	computeFence:          vk.Fence,
	simulationResources:   vkSimulationResources,
}

vkInstance :: struct {
	instance:          vk.Instance,
	enabledExtensions: [dynamic]cstring,
	enabledLayers:     [dynamic]cstring,
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
		must(vkCreateRenderPass(simulator^, &simulator.renderPass))
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
	vk.DestroyRenderPass(simulator.device, simulator.renderPass, nil)
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

@(private = "file")
vkInitialize :: proc "contextless" (simulator: ^vkSimulator) {
	context = runtime.default_context()

	loaded: bool

	// Load Vulkan library by platform
	when ODIN_OS == .Windows {
		simulator.module, loaded = dynlib.load_library("vulkan-1.dll")
	} else when ODIN_OS == .Darwin {
		simulator.module, loaded = dynlib.load_library("libvulkan.dylib", true)

		if !loaded {
			simulator.module, loaded = dynlib.load_library("libvulkan.1.dylib", true)
		}

		if !loaded {
			simulator.module, loaded = dynlib.load_library("libMoltenVK.dylib", true)
		}

		// Add support for using Vulkan and MoltenVK in a Framework. App store rules for iOS
		// strictly enforce no .dylib's. If they aren't found it just falls through
		if !loaded {
			simulator.module, loaded = dynlib.load_library("vulkan.framework/vulkan", true)
		}

		if !loaded {
			simulator.module, loaded = dynlib.load_library("MoltenVK.framework/MoltenVK", true)
			ta := context.temp_allocator
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			_, found_lib_path := os.lookup_env("DYLD_FALLBACK_LIBRARY_PATH", ta)
			// modern versions of macOS don't search /usr/local/lib automatically contrary to what
			// man dlopen says Vulkan SDK uses this as the system-wide installation location, so
			// we're going to fallback to this if all else fails
			if !loaded && !found_lib_path {
				simulator.module, loaded = dynlib.load_library("/usr/local/lib/libvulkan.dylib", true)
			}
		}
	} else {
		simulator.module, loaded = dynlib.load_library("libvulkan.so.1", true)
		if !loaded {
			simulator.module, loaded = dynlib.load_library("libvulkan.so", true)
		}
	}

	ensure(loaded, "Failed to load Vulkan library!")
	ensure(simulator.module != nil, "Failed to load Vulkan library module!")

	vkGetInstanceProcAddr, found := dynlib.symbol_address(simulator.module, "vkGetInstanceProcAddr")
	ensure(found, "Failed to get instance process address!")

	// Load the base vulkan procedures before we start using them
	vk.load_proc_addresses_global(vkGetInstanceProcAddr)
	assert(vk.CreateInstance != nil, "vulkan function pointers not loaded")
}

vkCreateInstance :: proc() -> vkInstance {
	instanceCreateInfo := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pApplicationName = "VkField",
			applicationVersion = vk.MAKE_VERSION(0, 0, 0),
			pEngineName = "No Engine",
			engineVersion = vk.MAKE_VERSION(1, 0, 0),
			apiVersion = vk.API_VERSION_1_2,
		},
	}

	extensions := slice.clone_to_dynamic(glfw.GetRequiredInstanceExtensions(), context.temp_allocator)

	when ODIN_OS == .Darwin {
		instanceCreateInfo.flags |= {.ENUMERATE_PORTABILITY_KHR}
		append(&extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
	}
	layers: [dynamic]cstring

	when ENABLE_VALIDATION_LAYERS {
		validationLayer :: cstring("VK_LAYER_KHRONOS_validation")
		append(&layers, validationLayer)
		instanceCreateInfo.ppEnabledLayerNames = raw_data(layers)
		instanceCreateInfo.enabledLayerCount = 1

		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		// Severity based on logger level.
		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error {
			severity |= {.ERROR}
		}
		if context.logger.lowest_level <= .Warning {
			severity |= {.WARNING}
		}
		if context.logger.lowest_level <= .Info {
			severity |= {.INFO}
		}
		if context.logger.lowest_level <= .Debug {
			severity |= {.VERBOSE}
		}

		debugLogger = context.logger
		dbgInfo := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = severity,
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE}, //TODO: .DEVICE_ADDRESS_BINDING needs to be checked // all of them.
			pfnUserCallback = vk_messenger_callback,
			pUserData       = &debugLogger,
		}
		instanceCreateInfo.pNext = &dbgInfo
	}

	instanceCreateInfo.enabledExtensionCount = u32(len(extensions))
	instanceCreateInfo.ppEnabledExtensionNames = raw_data(extensions)

	instance: vk.Instance
	must(vk.CreateInstance(&instanceCreateInfo, nil, &instance))
	return {instance, extensions, layers}
}

when ENABLE_VALIDATION_LAYERS {
	vkCreateDebugMessenger :: proc(instance: vk.Instance, dbgMsg: ^vk.DebugUtilsMessengerEXT) -> (result: vk.Result) {
		// Severity based on logger level.
		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error {
			severity |= {.ERROR}
		}
		if context.logger.lowest_level <= .Warning {
			severity |= {.WARNING}
		}
		if context.logger.lowest_level <= .Info {
			severity |= {.INFO}
		}
		if context.logger.lowest_level <= .Debug {
			severity |= {.VERBOSE}
		}

		dbg_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = severity,
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE}, //TODO: .DEVICE_ADDRESS_BINDING needs to be checked // all of them.
			pfnUserCallback = vk_messenger_callback,
			pUserData       = &debugLogger,
		}
		must(vk.CreateDebugUtilsMessengerEXT(instance, &dbg_create_info, nil, dbgMsg))
		return .SUCCESS
	}
}

@(require_results)
vkPickPhysicalDevice :: proc(simulator: vkSimulator, chosenDevice: ^vk.PhysicalDevice) -> vk.Result {
	count: u32
	vk.EnumeratePhysicalDevices(simulator.instance, &count, nil) or_return
	if count == 0 { log.panic("vulkan: No GPU found!") }

	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(simulator.instance, &count, raw_data(devices)) or_return

	bestDeviceScore := 0
	for device in devices {
		if score := scorePhysicalDevice(device, simulator); score > bestDeviceScore {
			chosenDevice^ = device
			bestDeviceScore = score
		}
	}

	if (bestDeviceScore <= 0) { log.panic("vulkan: No suitable GPU found!") }
	return .SUCCESS

	scorePhysicalDevice :: proc(device: vk.PhysicalDevice, simulator: vkSimulator) -> (score: int) {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)

		name := byte_arr_str(&props.deviceName) // Can't I use cString -> string casting?
		log.infof("vulkan: evaluating device %q", name)
		defer log.infof("vulkan: device %q scored %v", name, score)

		features: vk.PhysicalDeviceFeatures
		vk.GetPhysicalDeviceFeatures(device, &features)

		// Check Geometry Support
		if !simulator.settings.headless {
			if !features.geometryShader {
				log.infof("vulkan: device %q can only be used in headless mode as it does not support geometry shaders", name)
				return 0
			}
		}

		// Check extension support
		{
			extensions, result := physicalDeviceExtensions(device, context.temp_allocator)
			if result != .SUCCESS {
				log.infof("vulkan: enumerate device extension properties failed: %v", result)
				return 0
			}

			deviceExtensions: [dynamic]cstring = slice.clone_to_dynamic(DEVICE_EXTENSIONS, context.temp_allocator)
			if !simulator.settings.headless {
				append(&deviceExtensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
			}

			required_loop: for required in deviceExtensions {
				for &extension in extensions {
					extensionName := byte_arr_str(&extension.extensionName)
					if extensionName == string(required) {
						continue required_loop
					}
				}

				log.infof("vulkan: device %q does not support required extension %q", name, required)
				return 0
			}
		}

		// Check Swapchain Support
		if !simulator.settings.headless {
			support, result := querySwapchainSupport(device, simulator.surface, context.temp_allocator)
			if result != .SUCCESS {
				log.infof("vulkan: query swapchain support failure: %v", result)
				return 0
			}

			// Need at least a format and present mode.
			if len(support.formats) == 0 || len(support.presentModes) == 0 {
				log.info("vulkan: device %q does not support swapchain", name)
				return 0
			}
		}

		families := findQueueFamilies(simulator, device)
		if _, has_graphics := families.graphics.?; !has_graphics {
			log.info("vulkan: device %q does not have a graphics queue", name)
			return 0
		}
		if _, has_present := families.present.?; !simulator.settings.headless && !has_present {
			log.info("vulkan: device %q does not have a presentation queue", name)
			return 0
		}

		// Favor GPUs.
		switch props.deviceType {
		case .DISCRETE_GPU:
			score += 300_000
		case .INTEGRATED_GPU:
			score += 200_000
		case .VIRTUAL_GPU:
			score += 100_000
		case .CPU, .OTHER:
		}
		log.infof("vulkan: scored %i based on device type %v", score, props.deviceType)

		// Maximum texture size.
		score += int(props.limits.maxImageDimension2D)
		log.infof("vulkan: added the max 2D image dimensions (texture size) of %v to the score", props.limits.maxImageDimension2D)
		return
	}
}

vkCreateDevice :: proc(
	simulator: vkSimulator,
	vkDevice: ^vkDevice,
	graphicsQueue: ^vk.Queue,
	presentQueue: ^vk.Queue,
	computeQueue: ^vk.Queue,
	transferQueue: ^vk.Queue,
) -> (
	result: vk.Result,
) {
	vkDevice.physicalDevice = simulator.physicalDevice
	vkDevice.queueIndices = findQueueFamilies(simulator, vkDevice.physicalDevice)
	{
		// TODO: this is kinda messy.
		indices_set := make(map[u32]struct{}, allocator = context.temp_allocator)
		indices_set[vkDevice.queueIndices.graphics.?] = {}
		if !simulator.settings.headless {
			indices_set[vkDevice.queueIndices.present.?] = {}
		}
		indices_set[vkDevice.queueIndices.compute] = {}
		indices_set[vkDevice.queueIndices.transfer] = {}

		queue_create_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(indices_set), context.temp_allocator)
		for family in indices_set {
			append(
				&queue_create_infos,
				vk.DeviceQueueCreateInfo{sType = .DEVICE_QUEUE_CREATE_INFO, queueFamilyIndex = family, queueCount = 1, pQueuePriorities = raw_data([]f32{1})}, // Scheduling priority between 0 and 1.
			)
		}

		deviceExtensions: [dynamic]cstring = slice.clone_to_dynamic(DEVICE_EXTENSIONS, context.temp_allocator)
		if !simulator.settings.headless {
			append(&deviceExtensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
		}

		vk13Feats: vk.PhysicalDeviceVulkan13Features = {
			sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
			synchronization2 = true,
		}
		deviceFeatures: vk.PhysicalDeviceFeatures2 = {
			sType    = .PHYSICAL_DEVICE_FEATURES_2,
			features = {},
			pNext    = &vk13Feats,
		}

		device_create_info := vk.DeviceCreateInfo {
			sType                   = .DEVICE_CREATE_INFO,
			pQueueCreateInfos       = raw_data(queue_create_infos),
			queueCreateInfoCount    = u32(len(queue_create_infos)),
			enabledLayerCount       = u32(len(simulator.enabledLayers)),
			ppEnabledLayerNames     = raw_data(simulator.enabledLayers),
			ppEnabledExtensionNames = raw_data(deviceExtensions),
			enabledExtensionCount   = u32(len(deviceExtensions)),
			pNext                   = &deviceFeatures,
		}

		vk.CreateDevice(vkDevice.physicalDevice, &device_create_info, nil, &vkDevice.device) or_return

		vk.GetDeviceQueue(vkDevice.device, vkDevice.queueIndices.graphics.?, 0, graphicsQueue)
		if !simulator.settings.headless {
			vk.GetDeviceQueue(vkDevice.device, vkDevice.queueIndices.present.?, 0, presentQueue)
		}
		vk.GetDeviceQueue(vkDevice.device, vkDevice.queueIndices.compute, 0, computeQueue)
		vk.GetDeviceQueue(vkDevice.device, vkDevice.queueIndices.transfer, 0, transferQueue)
	}
	return
}

vkCreateSwapchain :: proc(simulator: vkSimulator, using vkSwapchain: ^vkSwapchain) -> vk.Result {
	indices := findQueueFamilies(simulator, simulator.physicalDevice)

	// Setup swapchain.
	{
		support, result := querySwapchainSupport(simulator.physicalDevice, simulator.surface, context.temp_allocator)
		if result != .SUCCESS {
			log.panicf("vulkan: query swapchain failed: %v", result)
		}

		surfaceFormat = chooseSwapchainSurfaceFormat(support.formats)
		presentMode = chooseSwapchainPresentMode(support.presentModes)
		extent = chooseSwapchainExtent(support.capabilities, simulator.window)

		image_count := support.capabilities.minImageCount + 1
		if support.capabilities.maxImageCount > 0 && image_count > support.capabilities.maxImageCount {
			image_count = support.capabilities.maxImageCount
		}

		create_info := vk.SwapchainCreateInfoKHR {
			sType            = .SWAPCHAIN_CREATE_INFO_KHR,
			surface          = simulator.surface,
			minImageCount    = image_count,
			imageFormat      = surfaceFormat.format,
			imageColorSpace  = surfaceFormat.colorSpace,
			imageExtent      = extent,
			imageArrayLayers = 1,
			imageUsage       = {.COLOR_ATTACHMENT},
			preTransform     = support.capabilities.currentTransform,
			compositeAlpha   = {.OPAQUE},
			presentMode      = presentMode,
			clipped          = true,
		}

		if indices.graphics != indices.present {
			create_info.imageSharingMode = .CONCURRENT
			create_info.queueFamilyIndexCount = 2
			create_info.pQueueFamilyIndices = raw_data([]u32{indices.graphics.?, indices.present.?})
		}

		must(vk.CreateSwapchainKHR(simulator.device, &create_info, nil, &swapchain))
	}

	// Setup swapchain images.
	{
		count: u32
		must(vk.GetSwapchainImagesKHR(simulator.device, swapchain, &count, nil))

		images = make([]vk.Image, count)
		views = make([]vk.ImageView, count)
		must(vk.GetSwapchainImagesKHR(simulator.device, swapchain, &count, raw_data(images)))

		for image, i in images {
			create_info := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = image,
				viewType = .D2,
				format = surfaceFormat.format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			}
			must(vk.CreateImageView(simulator.device, &create_info, nil, &views[i]))
		}
	}

	return .SUCCESS
}

vkDestroySwapchain :: proc(device: vk.Device, vkSwapchain: ^vkSwapchain) {
	if vkSwapchain.swapchain == {} {
		return
	}
	for view in vkSwapchain.views {
		vk.DestroyImageView(device, view, nil)
	}
	delete(vkSwapchain.views)
	delete(vkSwapchain.images)
	vk.DestroySwapchainKHR(device, vkSwapchain.swapchain, nil)
	vkSwapchain^ = {}
}

vkCreateShaderModule :: proc(simulator: vkSimulator, using shaderInfo: shaderInfo) -> (vkModule: vkShaderModule) {
	as_u32 := slice.reinterpret([]u32, code)

	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(as_u32),
	}
	must(vk.CreateShaderModule(simulator.device, &create_info, nil, &vkModule.module))
	vkModule.name = name
	vkModule.entryPoint = entryPoint
	vkModule.stageCreateInfo = {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = stage,
		module = vkModule.module,
		pName  = "main",
	}
	return
}

vkCreateRenderPass :: proc(simulator: vkSimulator, renderPass: ^vk.RenderPass) -> vk.Result {
	color_attachment := vk.AttachmentDescription {
		format         = simulator.swapchain.surfaceFormat.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}

	color_attachment_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_ref,
	}

	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}

	createInfo := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}

	vk.CreateRenderPass(simulator.device, &createInfo, nil, renderPass) or_return

	return .SUCCESS
}

vkCreateComputePipeline :: proc(simulator: vkSimulator, pipeline: ^vkPipeline) -> vk.Result {
	pushConstantRange: vk.PushConstantRange = {
		stageFlags = {.COMPUTE},
		size       = size_of(vkSimulationSettings),
		offset     = 0,
	}
	descriptorSetLayoutBindings: []vk.DescriptorSetLayoutBinding = {
		{binding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
		{binding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
		{binding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
		{binding = 3, descriptorType = .STORAGE_TEXEL_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
	}
	descriptorSetLayout: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		flags        = {},
		bindingCount = u32(len(descriptorSetLayoutBindings)),
		pBindings    = raw_data(descriptorSetLayoutBindings),
		pNext        = nil,
	}
	pipeline.descriptorSetLayouts = make([]vk.DescriptorSetLayout, 1)
	vk.CreateDescriptorSetLayout(simulator.device, &descriptorSetLayout, nil, raw_data(pipeline.descriptorSetLayouts)) or_return
	layoutCreateInfo: vk.PipelineLayoutCreateInfo = {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		flags                  = {},
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &pushConstantRange,
		setLayoutCount         = u32(len(pipeline.descriptorSetLayouts)),
		pSetLayouts            = raw_data(pipeline.descriptorSetLayouts),
		pNext                  = nil,
	}
	vk.CreatePipelineLayout(simulator.device, &layoutCreateInfo, nil, &pipeline.pipelineLayout) or_return

	when !USE_CUMULATIVE_COMPUTE {
		computeshaderIndex := 0
	} else {
		computeshaderIndex := 1
	}

	stageCreateInfo: vk.PipelineShaderStageCreateInfo = {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		flags  = {},
		stage  = {.COMPUTE},
		module = simulator.shaderModules[computeshaderIndex].module,
		pName  = strings.clone_to_cstring(simulator.shaderModules[computeshaderIndex].entryPoint, context.temp_allocator),
	}

	pipelineCreateInfo: vk.ComputePipelineCreateInfo = {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		flags  = {},
		stage  = stageCreateInfo,
		layout = pipeline.pipelineLayout,
	}

	vk.CreateComputePipelines(simulator.device, {}, 1, &pipelineCreateInfo, nil, &pipeline.pipeline)
	return .SUCCESS
}

vkCreateComputeCommandPool :: proc(simulator: vkSimulator, vkCommandPool: ^vkCommandPool) -> vk.Result {
	poolInfo: vk.CommandPoolCreateInfo = {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {},
		queueFamilyIndex = simulator.queueIndices.compute,
	}
	vk.CreateCommandPool(simulator.device, &poolInfo, nil, &vkCommandPool.commandPool) or_return

	allocInfo: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = vkCommandPool.commandPool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	vkCommandPool.commandBuffers = make([]vk.CommandBuffer, allocInfo.commandBufferCount)

	vk.AllocateCommandBuffers(simulator.device, &allocInfo, raw_data(vkCommandPool.commandBuffers)) or_return
	return .SUCCESS
}

vkCreateComputeDescriptorSets :: proc(simulator: vkSimulator, descriptorPool: ^vkDescriptorPool) -> vk.Result {
	descriptorPool.poolSizes = {{type = .STORAGE_BUFFER, descriptorCount = 3}, {type = .STORAGE_TEXEL_BUFFER, descriptorCount = 1}}

	poolInfo: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {},
		poolSizeCount = auto_cast len(descriptorPool.poolSizes),
		pPoolSizes    = raw_data(descriptorPool.poolSizes),
		maxSets       = 1,
	}

	allocOk := resize(&descriptorPool.pools, len(descriptorPool.pools) + 1)
	if allocOk != .None {
		if allocOk == .Out_Of_Memory { return .ERROR_OUT_OF_HOST_MEMORY }
		log.panicf("Failed to allocate DescriptorPool array %v", allocOk)
	}
	vk.CreateDescriptorPool(simulator.device, &poolInfo, nil, raw_data(descriptorPool.pools)) or_return
	descriptorPool.setCount += poolInfo.maxSets

	setInfo: vk.DescriptorSetAllocateInfo = {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = descriptorPool.pools[len(descriptorPool.pools) - 1],
		descriptorSetCount = 1,
		pSetLayouts        = raw_data(simulator.computePipeline.descriptorSetLayouts),
	}

	allocOk = resize(&descriptorPool.sets, len(descriptorPool.sets) + 1)
	if allocOk != .None {
		if allocOk == .Out_Of_Memory { return .ERROR_OUT_OF_HOST_MEMORY }
		log.panicf("Failed to allocate DescriptorSets array %v", allocOk)
	}
	vk.AllocateDescriptorSets(simulator.device, &setInfo, raw_data(descriptorPool.sets)) or_return

	return .SUCCESS
}

vkCreateSyncPrimitives :: proc(simulator: ^vkSimulator) -> vk.Result {
	fenceInfo: vk.FenceCreateInfo = {
		sType = .FENCE_CREATE_INFO,
		flags = {},
	}

	vk.CreateFence(simulator.device, &fenceInfo, nil, &simulator.computeFence) or_return

	return .SUCCESS
}

vkCreateBuffer :: proc(
	device: vkDevice,
	bufferInfo: ^vk.BufferCreateInfo,
	memoryProperties: vk.MemoryPropertyFlags,
	buffer: ^vkBuffer,
	loc := #caller_location,
) -> vk.Result {
	vk.CreateBuffer(device.device, bufferInfo, nil, &buffer.buffer) or_return
	buffer.usage = bufferInfo.usage
	buffer.size = bufferInfo.size
	bufferMemReqs: vk.BufferMemoryRequirementsInfo2 = {
		sType  = .BUFFER_MEMORY_REQUIREMENTS_INFO_2,
		buffer = buffer.buffer,
	}
	memReqs: vk.MemoryRequirements2 = {
		sType = .MEMORY_REQUIREMENTS_2,
	}
	vk.GetBufferMemoryRequirements2(device.device, &bufferMemReqs, &memReqs)
	memType, ok := findMemoryType(device.physicalDevice, memReqs.memoryRequirements.memoryTypeBits, memoryProperties)
	if !ok {
		log.panicf("Cannot obtain memory with requested properties %v", memoryProperties, loc)
	}
	allocInfo: vk.MemoryAllocateInfo = {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = memReqs.memoryRequirements.size,
		memoryTypeIndex = memType,
	}
	vk.AllocateMemory(device.device, &allocInfo, nil, &buffer.memory)
	memProperties: vk.PhysicalDeviceMemoryProperties2 = {
		sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
	}
	vk.GetPhysicalDeviceMemoryProperties2(device.physicalDevice, &memProperties)
	buffer.memoryProps = memProperties.memoryProperties.memoryTypes[memType].propertyFlags
	if .HOST_VISIBLE in buffer.memoryProps {
		vk.MapMemory(device.device, buffer.memory, 0, buffer.size, {}, &buffer.data) or_return
	}
	bindInfo: vk.BindBufferMemoryInfo = {
		sType        = .BIND_BUFFER_MEMORY_INFO,
		buffer       = buffer.buffer,
		memory       = buffer.memory,
		memoryOffset = 0,
	}
	vk.BindBufferMemory2(device.device, 1, &bindInfo) or_return
	return .SUCCESS
}

vkCreateBufferView :: proc(device: vkDevice, buffer: vkBuffer, format: vk.Format, view: ^vk.BufferView) -> vk.Result {
	viewInfo: vk.BufferViewCreateInfo = {
		sType  = .BUFFER_VIEW_CREATE_INFO,
		flags  = {},
		buffer = buffer.buffer,
		range  = buffer.size,
		offset = 0,
		format = format,
	}
	vk.CreateBufferView(device.device, &viewInfo, nil, view) or_return
	return .SUCCESS
}

vkDestroyBuffer :: proc(device: vkDevice, buffer: vkBuffer) {
	vk.DestroyBuffer(device.device, buffer.buffer, nil)
	vk.FreeMemory(device.device, buffer.memory, nil)
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
		runtime.debug_trap()
	}
	return false
}

must :: proc(result: vk.Result, loc := #caller_location) {
	if result != .SUCCESS {
		log.panicf("vulkan failure %v", result, location = loc)
	}
}
