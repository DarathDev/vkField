package vkField_vulkan

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math/bits"
import "core:mem"
import "core:slice"
import "core:strings"
import win32 "core:sys/windows"
import vk "vendor:vulkan"
import rdm_util "vkField:utility"

@(private = "file")
assert :: rdm_util.assert
@(private = "file")
check :: rdm_util.check

REQUIRE_RESOURCE_LABELS :: #config(REQUIRE_RESOURCE_LABELS, ODIN_DEBUG)
@(thread_local)
EXCUSE_RESOURCE_LABELS: bool

/* -------------------- */
/* ----- Instance ----- */
/* -------------------- */

AppInfo :: struct {
	appName:       string,
	appVersion:    rdm_util.SemanticVersion,
	engineName:    string,
	engineVersion: rdm_util.SemanticVersion,
	vulkanVersion: u32,
	presentable:   bool,
}

Instance :: struct {
	instance:          vk.Instance,
	apiVersion:        u32,
	enabledLayers:     [dynamic]cstring,
	enabledExtensions: [dynamic]cstring,
}

@(require_results)
create_instance :: proc(
	appInfo: AppInfo,
	requiredExtensions: []string = {},
	optionalExtensions: []string = {},
	debugUserData: ^DebugUserData = nil,
	allocator := context.allocator,
) -> (
	instance: Instance,
	result: vk.Result,
) {

	instanceCreateInfo := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pNext            = nil,
		pApplicationInfo = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pNext = nil,
			pApplicationName = strings.clone_to_cstring(appInfo.appName, context.temp_allocator),
			applicationVersion = vk.MAKE_VERSION(auto_cast appInfo.appVersion.major, auto_cast appInfo.appVersion.minor, auto_cast appInfo.appVersion.patch),
			pEngineName = strings.clone_to_cstring(appInfo.engineName, context.temp_allocator),
			engineVersion = vk.MAKE_VERSION(
				auto_cast appInfo.engineVersion.major,
				auto_cast appInfo.engineVersion.minor,
				auto_cast appInfo.engineVersion.patch,
			),
			apiVersion = appInfo.vulkanVersion,
		},
	}

	instance.enabledLayers = make([dynamic]cstring, allocator)
	instance.enabledExtensions = make([dynamic]cstring, allocator)

	extensions: [dynamic]string
	if appInfo.presentable {
		presentExtensions := get_required_instance_presentation_extensions()
		extensions = slice.clone_to_dynamic(presentExtensions, context.temp_allocator)
	}

	when ODIN_OS == .Darwin {
		instanceCreateInfo.flags |= {.ENUMERATE_PORTABILITY_KHR}
		append(&extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
	}

	availableExtensionCount: u32
	for result = check(vk.EnumerateInstanceExtensionProperties(nil, &availableExtensionCount, nil)); result == .INCOMPLETE; {  }
	availableExtensions := make([]vk.ExtensionProperties, availableExtensionCount, context.temp_allocator)
	for result = check(vk.EnumerateInstanceExtensionProperties(nil, &availableExtensionCount, raw_data(availableExtensions))); result == .INCOMPLETE; {  }

	when ENABLE_VALIDATION_LAYERS {
		validationLayer :: "VK_LAYER_KHRONOS_validation"

		append(&instance.enabledLayers, strings.clone_to_cstring(validationLayer, allocator))
		instanceCreateInfo.ppEnabledLayerNames = raw_data(instance.enabledLayers)
		instanceCreateInfo.enabledLayerCount = 1

		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error { severity |= {.ERROR} }
		if context.logger.lowest_level <= .Warning { severity |= {.WARNING} }
		if context.logger.lowest_level <= .Info { severity |= {.INFO} }
		if context.logger.lowest_level <= .Debug { severity |= {.VERBOSE} }

		dbgInfo := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			pNext           = nil,
			messageSeverity = severity,
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = vk_messenger_callback,
			pUserData       = debugUserData,
		}

		for &availableExtension in availableExtensions {
			rhs := strings.string_from_null_terminated_ptr(auto_cast &availableExtension.extensionName, vk.MAX_EXTENSION_NAME_SIZE)
			if strings.compare(vk.EXT_DEVICE_ADDRESS_BINDING_REPORT_EXTENSION_NAME, rhs) == 0 {
				dbgInfo.messageType |= {.DEVICE_ADDRESS_BINDING}
				append(&instance.enabledExtensions, vk.EXT_DEVICE_ADDRESS_BINDING_REPORT_EXTENSION_NAME)
			}
		}

		instanceCreateInfo.pNext = &dbgInfo
	}

	for extension in requiredExtensions {
		append(&extensions, extension)
	}

	extensionLoop: for extension in extensions {
		for &availableExtension in availableExtensions {
			rhs := strings.string_from_null_terminated_ptr(auto_cast &availableExtension.extensionName, vk.MAX_EXTENSION_NAME_SIZE)
			if strings.compare(extension, rhs) == 0 do continue extensionLoop
		}

		check(vk.Result.ERROR_EXTENSION_NOT_PRESENT, fmt.tprintf("Extension %v is not available", extension)) or_return
		return
	}

	for extension in optionalExtensions {
		for &availableExtension in availableExtensions {
			rhs := strings.string_from_null_terminated_ptr(auto_cast &availableExtension.extensionName, vk.MAX_EXTENSION_NAME_SIZE)
			if strings.compare(extension, rhs) == 0 { append(&extensions, extension); break }
		}
	}

	ppExtensionNames: []cstring = make([]cstring, len(extensions), context.temp_allocator)
	for extension, i in extensions {
		ppExtensionNames[i] = strings.clone_to_cstring(extension, context.temp_allocator)
	}
	instanceCreateInfo.enabledExtensionCount = u32(len(extensions))
	instanceCreateInfo.ppEnabledExtensionNames = raw_data(ppExtensionNames)

	check(vk.CreateInstance(&instanceCreateInfo, nil, &instance.instance)) or_return
	instance.apiVersion = appInfo.vulkanVersion
	vk.load_proc_addresses_instance(instance.instance)
	return
}

destroy_instance :: proc(instance: ^Instance) {
	for layer in instance.enabledLayers {
		delete(layer, instance.enabledLayers.allocator)
	}
	delete(instance.enabledLayers)
	for extension in instance.enabledExtensions {
		delete(extension, instance.enabledExtensions.allocator)
	}
	delete(instance.enabledExtensions)
	vk.DestroyInstance(instance.instance, nil)
}

/* --------------------------- */
/* ----- Debug Messenger ----- */
/* --------------------------- */

DebugMessenger :: struct {
	debugMessenger: vk.DebugUtilsMessengerEXT,
	userData:       ^DebugUserData,
}

DebugUserData :: struct {
	logger: runtime.Logger,
}

@(require_results)
create_debug_messenger :: proc(instance: Instance, userData: ^DebugUserData, allocator := context.allocator) -> (dbgMsg: DebugMessenger, result: vk.Result) {
	// Severity based on logger level.
	severity: vk.DebugUtilsMessageSeverityFlagsEXT
	if context.logger.lowest_level <= .Error { severity |= {.ERROR} }
	if context.logger.lowest_level <= .Warning { severity |= {.WARNING} }
	if context.logger.lowest_level <= .Info { severity |= {.INFO} }
	if context.logger.lowest_level <= .Debug { severity |= {.VERBOSE} }

	createInfo := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		pNext           = nil,
		messageSeverity = severity,
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = vk_messenger_callback,
		pUserData       = userData,
	}
	for &availableExtension in instance.enabledExtensions {
		rhs := strings.string_from_null_terminated_ptr(auto_cast &availableExtension, 128)
		if strings.compare(vk.EXT_DEVICE_ADDRESS_BINDING_REPORT_EXTENSION_NAME, rhs) == 0 {
			createInfo.messageType |= {.DEVICE_ADDRESS_BINDING}
		}
	}
	check(vk.CreateDebugUtilsMessengerEXT(instance.instance, &createInfo, nil, &dbgMsg.debugMessenger)) or_return
	return
}

destroy_debug_messenger :: proc(instance: vk.Instance, dbgMsg: ^DebugMessenger) {
	vk.DestroyDebugUtilsMessengerEXT(instance, dbgMsg.debugMessenger, nil)
}

/* ------------------- */
/* ----- Surface ----- */
/* ------------------- */

create_surface :: proc {
	create_win32_surface,
}

create_win32_surface :: proc(instance: vk.Instance, window: win32.HWND, hInstance: win32.HINSTANCE) -> (surface: vk.SurfaceKHR, ok: vk.Result) {
	createInfo: vk.Win32SurfaceCreateInfoKHR = {
		sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
		flags     = {},
		hwnd      = window,
		hinstance = hInstance,
	}
	check(vk.CreateWin32SurfaceKHR(instance, &createInfo, nil, &surface)) or_return
	return
}

destroy_surface :: proc(instance: vk.Instance, surface: vk.SurfaceKHR) {
	vk.DestroySurfaceKHR(instance, surface, nil)
}

/* --------------------------- */
/* ----- Physical Device ----- */
/* --------------------------- */

DeviceCriteria :: struct {
	graphics:             bool,
	present:              bool,
	requiredCapabilities: DeviceCapabilities,
	optionalCapabilities: DeviceCapabilities,
}

DeviceCapability :: enum {
	// Vulkan 1.0 Features
	GeometryShaders,
	TessellationShaders,
	SampleRateShading,
	LogicOp,
	MultiDrawIndirect,
	DepthClamp,
	DepthBounds,
	WideLines,
	LargePoints,
	MultiViewport,
	SamplerAnisotropy,
	ShaderFloat64,
	ShaderInt64,
	ShaderInt16,
	// Vulkan 1.1 Features
	MultiView,
	ShaderDrawParameters,
	// Vulkan 1.2 Features
	DrawIndirectCount,
	ShaderFloat16,
	ShaderInt8,
	DescriptorIndexing,
	VariableDescriptorCount,
	TimelineSemaphore,
	BufferDeviceAddress,
	// Vulkan 1.3 Features
	Synchronization2,
	DynamicRendering,
	Maintenance4,
	// Mesh Shaders
	MeshShader,
	// Swapchain Maintenance
	SwapchainMaintenance,
	// Shader Object
	ShaderObject,
	// Extensions
	AtomicAddFloat32Buffer,
	Swapchain,
	FifoLatestReady,
	ExternalMemoryHost,
}

DeviceCapabilities :: bit_set[DeviceCapability]

PhysicalDevice :: struct {
	name:             string,
	physicalDevice:   vk.PhysicalDevice,
	properties:       vk.PhysicalDeviceProperties,
	capabilities:     DeviceCapabilities,
	queueFamilies:    []vk.QueueFamilyProperties,
	memoryProperties: vk.PhysicalDeviceMemoryProperties,
	memoryHeaps:      [dynamic; vk.MAX_MEMORY_TYPES]vk.MemoryHeap,
	memoryTypes:      [dynamic; vk.MAX_MEMORY_HEAPS]vk.MemoryType,
}

@(require_results)
get_physical_devices :: proc(instance: vk.Instance, allocator := context.allocator) -> (devices: #soa[]PhysicalDevice, result: vk.Result) {

	deviceCount: u32
	check(vk.EnumeratePhysicalDevices(instance, &deviceCount, nil)) or_return
	devicesOk: mem.Allocator_Error
	devices, devicesOk = make(#soa[]PhysicalDevice, deviceCount, allocator)
	if devicesOk != .None {
		result = vk.Result.ERROR_OUT_OF_HOST_MEMORY
		return
	}
	check(vk.EnumeratePhysicalDevices(instance, &deviceCount, devices.physicalDevice)) or_return

	features := make_device_features(~{}, context.temp_allocator)

	for &device in devices {
		vk.GetPhysicalDeviceProperties(device.physicalDevice, &device.properties)
		device.name = strings.clone_from_cstring_bounded(cast(cstring)&device.properties.deviceName[0], vk.MAX_PHYSICAL_DEVICE_NAME_SIZE, allocator)
		queueFamilyCount: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(device.physicalDevice, &queueFamilyCount, nil)
		device.queueFamilies = make([]vk.QueueFamilyProperties, queueFamilyCount, allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(device.physicalDevice, &queueFamilyCount, raw_data(device.queueFamilies))
		extensionCount: u32

		vk.GetPhysicalDeviceFeatures2(device.physicalDevice, &features)
		check(vk.EnumerateDeviceExtensionProperties(device.physicalDevice, nil, &extensionCount, nil)) or_return
		extensions := make([]vk.ExtensionProperties, extensionCount, context.temp_allocator)
		check(vk.EnumerateDeviceExtensionProperties(device.physicalDevice, nil, &extensionCount, raw_data(extensions))) or_return
		device.capabilities = deduce_device_capabilities(features, extensions)

		memoryProperties: vk.PhysicalDeviceMemoryProperties
		vk.GetPhysicalDeviceMemoryProperties(device.physicalDevice, &memoryProperties)
		clear(&device.memoryHeaps); clear(&device.memoryTypes)
		append(&device.memoryHeaps, ..memoryProperties.memoryHeaps[:memoryProperties.memoryHeapCount])
		append(&device.memoryTypes, ..memoryProperties.memoryTypes[:memoryProperties.memoryTypeCount])
	}
	return
}

free_physical_devices :: proc(devices: ^#soa[]PhysicalDevice, allocator := context.allocator) {
	for &device in devices {
		delete(device.queueFamilies, allocator)
		clear(&device.memoryHeaps)
		clear(&device.memoryTypes)
		delete(device.name, allocator)
	}
	delete(devices^, allocator)
}

/* ------------------ */
/* ----- Device ----- */
/* ------------------ */

Device :: struct {
	physicalDevice:      PhysicalDevice,
	device:              vk.Device,
	multiQueueIndex:     u32,
	computeQueueIndex:   u32,
	transferQueueIndex:  u32,
	headlessQueueIndex:  u32,
	presentQueueIndex:   u32,
	queues:              map[u32]vk.Queue,
	enabledCapabilities: DeviceCapabilities,
}

@(require_results)
create_device :: proc(
	instance: Instance,
	physicalDevice: PhysicalDevice,
	criteria: DeviceCriteria,
	label := "",
	allocator := context.allocator,
) -> (
	device: Device,
	result: vk.Result,
) {
	checkLabel(label)
	context.allocator = allocator

	defer check(result != .SUCCESS || device.device != {})

	queueIndices := make(map[u32]u32, context.temp_allocator)

	computeQueueIndex: u32
	computeQueueIndex = get_compute_queue(physicalDevice.physicalDevice, physicalDevice.queueFamilies)
	queueIndices[computeQueueIndex] = 1
	device.computeQueueIndex = computeQueueIndex

	transferQueueIndex: u32
	transferQueueIndex = get_transfer_queue(physicalDevice.physicalDevice, physicalDevice.queueFamilies)
	queueIndices[transferQueueIndex] = 1
	device.transferQueueIndex = transferQueueIndex

	headlessQueueIndex: Maybe(u32)
	if criteria.graphics {
		headlessQueueIndex = get_headless_queue(physicalDevice.physicalDevice, physicalDevice.queueFamilies)
		queueIndices[headlessQueueIndex.(u32)] = 1
		device.headlessQueueIndex = headlessQueueIndex.(u32)
	}

	presentQueueIndex: Maybe(u32)
	if criteria.present {
		presentQueueIndex = assert(get_present_queue(physicalDevice.physicalDevice, physicalDevice.queueFamilies))
		queueIndices[presentQueueIndex.(u32)] = 1
		device.presentQueueIndex = presentQueueIndex.(u32)
	}

	multiQueueIndex: Maybe(u32)
	if criteria.graphics && criteria.present {
		multiQueueIndex = assert(get_multi_queue(physicalDevice.physicalDevice, physicalDevice.queueFamilies))
		queueIndices[multiQueueIndex.(u32)] = 1
		device.multiQueueIndex = multiQueueIndex.(u32)
	}

	queueCreateInfos := make([]vk.DeviceQueueCreateInfo, len(queueIndices), context.temp_allocator)
	totalQueueCount: u32
	for _, queueCount in queueIndices {
		totalQueueCount += queueCount
	}

	queuePriorities := make([]f32, totalQueueCount, context.temp_allocator)
	for &priority in queuePriorities {
		priority = 1
	}

	createCount := 0
	priorityCount := 0
	for queueIndex, queueCount in queueIndices {
		queueCreateInfos[createCount] = vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			pNext            = nil,
			queueFamilyIndex = queueIndex,
			queueCount       = queueCount,
			pQueuePriorities = &queuePriorities[priorityCount],
		}
		createCount += 1
		priorityCount += int(queueCount)
	}

	device.enabledCapabilities = criteria.requiredCapabilities + (criteria.optionalCapabilities & physicalDevice.capabilities)
	enabledExtensions := make([dynamic]cstring, context.temp_allocator)
	add_capability_extensions(&enabledExtensions, device.enabledCapabilities)

	deviceFeatures := make_device_features(device.enabledCapabilities, context.temp_allocator)

	deviceCreateInfo: vk.DeviceCreateInfo = {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &deviceFeatures,
		enabledLayerCount       = u32(len(instance.enabledLayers)),
		ppEnabledLayerNames     = raw_data(instance.enabledLayers),
		enabledExtensionCount   = u32(len(enabledExtensions)),
		ppEnabledExtensionNames = raw_data(enabledExtensions),
		queueCreateInfoCount    = u32(len(queueCreateInfos)),
		pQueueCreateInfos       = raw_data(queueCreateInfos),
	}

	check(vk.CreateDevice(physicalDevice.physicalDevice, &deviceCreateInfo, nil, &device.device)) or_return
	name(device, label)
	device.physicalDevice = physicalDevice

	device.queues = make(map[u32]vk.Queue, allocator)
	for queueIndex, _ in queueIndices {
		queue: vk.Queue
		vk.GetDeviceQueue(device.device, queueIndex, 0, &queue)
		device.queues[queueIndex] = queue
	}
	return
}

destroy_device :: proc(device: ^Device) {
	delete(device.queues)
	vk.DestroyDevice(device.device, nil)
}

/* --------------------- */
/* ----- Swapchain ----- */
/* --------------------- */

SwapCriteria :: struct {
	supportHdr:              bool,
	uncappedFrameRate:       bool,
	framebufferSize:         [2]u32,
	supportsFifoLatestReady: bool,
}

SwapchainSupport :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	formats:      []vk.SurfaceFormatKHR,
	presentModes: []vk.PresentModeKHR,
}

Swapchain :: struct {
	allocator:     mem.Allocator,
	surface:       vk.SurfaceKHR,
	swapchain:     vk.SwapchainKHR,
	images:        #soa[dynamic]Image,
	views:         #soa[dynamic]ImageView,
	semaphores:    [dynamic]BinarySemaphore,
	surfaceFormat: vk.SurfaceFormatKHR,
	presentMode:   vk.PresentModeKHR,
	extent:        vk.Extent2D,
	support:       SwapchainSupport,
}

@(require_results)
create_swapchain :: proc(
	device: ^Device,
	surface: vk.SurfaceKHR,
	criteria: SwapCriteria,
	label: string = "",
	allocator := context.allocator,
) -> (
	swapchain: Swapchain,
	result: vk.Result,
) {
	checkLabel(label)
	defer check(result != .SUCCESS || swapchain.swapchain != {})
	defer check(result != .SUCCESS || swapchain.surface != {})

	swapchain.support = query_swapchain_support(device.physicalDevice.physicalDevice, surface, allocator) or_return
	surfaceFormat, formatOk := choose_swap_surface_format(swapchain.support.formats, criteria)
	presentMode := choose_swap_present_mode(swapchain.support.presentModes, criteria)
	extent := choose_swap_extent(swapchain.support.capabilities, criteria)
	check(formatOk)

	imageCount: u32 = swapchain.support.capabilities.minImageCount + 1
	if (swapchain.support.capabilities.maxImageCount > 0) {
		imageCount = min(imageCount, swapchain.support.capabilities.maxImageCount)
	}

	createInfo: vk.SwapchainCreateInfoKHR = {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		pNext            = nil,
		surface          = surface,
		minImageCount    = imageCount,
		imageFormat      = surfaceFormat.format,
		imageColorSpace  = surfaceFormat.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		preTransform     = swapchain.support.capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = presentMode,
		clipped          = false, // TODO: This might interfere with screenshotting, streaming etc. if true. Check with Vulkan spec
		imageSharingMode = .EXCLUSIVE,
		oldSwapchain     = {},
	}
	swapchain = {
		allocator     = allocator,
		surfaceFormat = surfaceFormat,
		extent        = extent,
		presentMode   = presentMode,
		surface       = surface,
	}

	make_swapchain(device^, &createInfo, &swapchain, label)
	return
}

recreate_swapchain :: proc(
	device: Device,
	oldSwapchain: Swapchain,
	criteria: SwapCriteria,
	label: string = "",
	allocator := context.allocator,
) -> (
	swapchain: Swapchain,
	result: vk.Result,
) {
	checkLabel(label)
	swapchain.support = query_swapchain_support(device.physicalDevice.physicalDevice, oldSwapchain.surface, allocator) or_return
	surfaceFormat, formatOk := check(choose_swap_surface_format(swapchain.support.formats, criteria))
	if !formatOk do return {}, .ERROR_FORMAT_NOT_SUPPORTED
	presentMode := choose_swap_present_mode(swapchain.support.presentModes, criteria)
	extent := choose_swap_extent(swapchain.support.capabilities, criteria)

	imageCount: u32 = swapchain.support.capabilities.minImageCount + 1
	if (swapchain.support.capabilities.maxImageCount > 0) {
		imageCount = min(imageCount, swapchain.support.capabilities.maxImageCount)
	}

	createInfo: vk.SwapchainCreateInfoKHR = {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		pNext            = nil,
		surface          = oldSwapchain.surface,
		minImageCount    = imageCount,
		imageFormat      = surfaceFormat.format,
		imageColorSpace  = surfaceFormat.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		preTransform     = swapchain.support.capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = presentMode,
		clipped          = false, // TODO: This might interfere with screenshotting, streaming etc. if true. Check with Vulkan spec
		imageSharingMode = .EXCLUSIVE,
		oldSwapchain     = oldSwapchain.swapchain,
	}
	swapchain = {
		allocator     = allocator,
		surfaceFormat = surfaceFormat,
		extent        = extent,
		presentMode   = presentMode,
		surface       = oldSwapchain.surface,
	}
	make_swapchain(device, &createInfo, &swapchain, label) or_return
	return
}

@(private)
make_swapchain :: proc(device: Device, createInfo: ^vk.SwapchainCreateInfoKHR, swapchain: ^Swapchain, label: string = "") -> (result: vk.Result) {

	check(swapchain.swapchain == {} || swapchain.swapchain == createInfo.oldSwapchain)
	defer check(len(swapchain.images) >= auto_cast createInfo.minImageCount)
	defer check(len(swapchain.images) == len(swapchain.views))
	defer check(len(swapchain.images) == len(swapchain.semaphores))

	for view in swapchain.views {
		destroy_image_view(device, view)
	}
	for semaphore in swapchain.semaphores {
		destroy_binary_semaphore(device, semaphore)
	}

	check(vk.CreateSwapchainKHR(device.device, createInfo, nil, &swapchain.swapchain)) or_return
	name(device, swapchain.swapchain, label)

	imageCount: u32
	check(vk.GetSwapchainImagesKHR(device.device, swapchain.swapchain, &imageCount, nil)) or_return
	swapchain.images = make(#soa[dynamic]Image, imageCount, swapchain.allocator)
	swapchain.views = make(#soa[dynamic]ImageView, imageCount, swapchain.allocator)
	swapchain.semaphores = make([dynamic]BinarySemaphore, imageCount, swapchain.allocator)
	check(vk.GetSwapchainImagesKHR(device.device, swapchain.swapchain, &imageCount, swapchain.images.image)) or_return
	for &image, index in swapchain.images {
		image.type = .D2
		image.format = createInfo.imageFormat
		image.extent = {
			width  = createInfo.imageExtent.width,
			height = createInfo.imageExtent.height,
		}
		image.usage = createInfo.imageUsage
		image.samples = {._1}
		name(device, swapchain.images.image[index], fmt.tprintf("%s's Swap %d", label, index))

		swapchain.views[index] = check(create_image_view(device, image, label = fmt.tprintf("%s's Swap %d", label, index))) or_return
		swapchain.semaphores[index] = create_binary_semaphore(device, fmt.tprintf("%s's Swap %d Present Finished Binary", label, index)) or_return
	}
	return
}

destroy_swapchain :: proc(device: Device, swapchain: Swapchain) {
	delete(swapchain.views)
	for &view in swapchain.views {
		v := view
		destroy_image_view(device, v)
		view = v
	}
	for &sempahore in swapchain.semaphores {
		s := sempahore
		destroy_semaphore(device, auto_cast s)
		sempahore = s
	}
	vk.DestroySwapchainKHR(device.device, swapchain.swapchain, nil)
}

swap_length :: proc(swapchain: Swapchain) -> int {
	return len(swapchain.images)
}

/* ----------------- */
/* ----- Fence ----- */
/* ----------------- */

create_fence :: proc(device: Device, signaled: bool = false, label := "") -> (fence: vk.Fence, result: vk.Result) {
	checkLabel(label)
	info: vk.FenceCreateInfo = {
		sType = .FENCE_CREATE_INFO,
		flags = signaled ? {.SIGNALED} : {},
	}
	vk.CreateFence(device.device, &info, nil, &fence) or_return
	if len(label) > 0 {
		name(device, fence, label)
	}
	return
}

destroy_fence :: proc(device: Device, fence: vk.Fence) {
	vk.DestroyFence(device.device, fence, nil)
}

/* --------------------- */
/* ----- Semaphore ----- */
/* --------------------- */

TimelineSemaphore :: distinct vk.Semaphore

BinarySemaphore :: distinct vk.Semaphore

create_binary_semaphore :: proc(device: Device, label := "") -> (semaphore: BinarySemaphore, result: vk.Result) {
	checkLabel(label)
	typeInfo: vk.SemaphoreTypeCreateInfo = {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		pNext         = nil,
		semaphoreType = .BINARY,
	}
	createInfo: vk.SemaphoreCreateInfo = {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &typeInfo,
		flags = {},
	}
	check(vk.CreateSemaphore(device.device, &createInfo, nil, auto_cast &semaphore)) or_return
	if len(label) > 0 {
		name(device, cast(vk.Semaphore)semaphore, label)
	}
	return
}

create_timeline_semaphore :: proc(device: Device, initialValue: u64 = 0, label := "") -> (semaphore: TimelineSemaphore, result: vk.Result) {
	checkLabel(label)
	typeInfo: vk.SemaphoreTypeCreateInfo = {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		pNext         = nil,
		semaphoreType = .TIMELINE,
		initialValue  = initialValue,
	}
	createInfo: vk.SemaphoreCreateInfo = {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &typeInfo,
		flags = {},
	}
	check(vk.CreateSemaphore(device.device, &createInfo, nil, auto_cast &semaphore)) or_return
	if len(label) > 0 {
		name(device, cast(vk.Semaphore)semaphore, label)
	}
	return
}

destroy_semaphore :: proc {
	destroy_binary_semaphore,
	destroy_timeline_semaphore,
}

destroy_binary_semaphore :: proc(device: Device, semaphore: BinarySemaphore) {
	vk.DestroySemaphore(device.device, auto_cast semaphore, nil)
}

destroy_timeline_semaphore :: proc(device: Device, semaphore: TimelineSemaphore) {
	vk.DestroySemaphore(device.device, auto_cast semaphore, nil)
}

/* ------------------ */
/* ----- Events ----- */
/* ------------------ */

Event :: struct {
	event:      vk.Event,
	deviceOnly: bool,
}

create_event :: proc(device: Device, deviceOnly: bool, label := "") -> (event: vk.Event, result: vk.Result) {
	checkLabel(label)
	eventCreateInfo: vk.EventCreateInfo = {
		sType = .EVENT_CREATE_INFO,
		flags = deviceOnly ? {.DEVICE_ONLY} : {},
	}

	check(vk.CreateEvent(device.device, &eventCreateInfo, nil, &event)) or_return
	if len(label) > 0 {
		name(device, event, label)
	}
	return
}

destroy_event :: proc(device: Device, event: Event) {
	vk.DestroyEvent(device.device, event.event, nil)
}

/* ------------------- */
/* ----- Command ----- */
/* ------------------- */

CommandPool :: struct {
	commandPool:         vk.CommandPool,
	commandBuffers:      [dynamic]vk.CommandBuffer,
	usedCommandBuffers:  [dynamic]vk.CommandBuffer,
	resetCommandBuffers: bool,
}

create_command_pool :: proc(
	device: Device,
	queueIndex: u32,
	resetCommandBuffers := false,
	label := "",
	allocator := context.allocator,
) -> (
	commandPool: CommandPool,
	result: vk.Result,
) {
	checkLabel(label)
	createInfo: vk.CommandPoolCreateInfo = {
		sType            = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = queueIndex,
		flags            = resetCommandBuffers ? {.RESET_COMMAND_BUFFER} : {},
	}
	check(vk.CreateCommandPool(device.device, &createInfo, nil, &commandPool.commandPool)) or_return
	if len(label) > 0 {
		name(device, commandPool.commandPool, label)
	}
	commandPool.commandBuffers = make([dynamic]vk.CommandBuffer, allocator)
	commandPool.usedCommandBuffers = make([dynamic]vk.CommandBuffer, allocator)
	commandPool.resetCommandBuffers = .RESET_COMMAND_BUFFER in createInfo.flags
	return
}

get_command_buffer :: proc(device: Device, commandPool: ^CommandPool) -> (commandBuffer: vk.CommandBuffer, result: vk.Result) {
	result = get_command_buffers(device, commandPool, slice.from_ptr(&commandBuffer, 1))
	return
}

get_command_buffers :: proc(device: Device, commandPool: ^CommandPool, commandBuffers: []vk.CommandBuffer) -> (result: vk.Result) {
	count := len(commandBuffers)
	available := len(commandPool.commandBuffers)
	extra := available - count
	if (count == 0) do return

	if available > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(commandBuffers), &commandPool.commandBuffers[extra], min(available, count) * size_of(vk.CommandBuffer))
		resize(&commandPool.commandBuffers, max(extra, 0))
	}

	needed := max(-extra, 0)
	if needed > 0 {
		check(allocate_command_buffers(device, commandPool.commandPool, commandBuffers[available:])) or_return
	}

	append_elems(&commandPool.usedCommandBuffers, ..commandBuffers)
	return
}

allocate_command_buffers :: proc(device: Device, commandPool: vk.CommandPool, commandBuffers: []vk.CommandBuffer) -> (result: vk.Result) {
	allocInfo: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = commandPool,
		commandBufferCount = u32(len(commandBuffers)),
		level              = .PRIMARY,
	}
	check(vk.AllocateCommandBuffers(device.device, &allocInfo, raw_data(commandBuffers))) or_return
	return
}

reset_command_pool :: proc(device: Device, commandPool: ^CommandPool) -> (result: vk.Result) {
	check(vk.ResetCommandPool(device.device, commandPool.commandPool, {})) or_return
	append(&commandPool.commandBuffers, ..commandPool.usedCommandBuffers[:])
	clear(&commandPool.usedCommandBuffers)
	return
}

reset_command_buffer :: proc(device: Device, commandPool: ^CommandPool, commandBuffer: vk.CommandBuffer) {
	check(commandPool.resetCommandBuffers)
	index := assert(slice.linear_search(commandPool.usedCommandBuffers[:], commandBuffer))
	check(vk.ResetCommandBuffer(commandBuffer, {}))
	unordered_remove(&commandPool.usedCommandBuffers, index)
	append(&commandPool.commandBuffers, commandBuffer)
	return
}

destroy_command_pool :: proc(device: Device, commandPool: CommandPool) {
	vk.DestroyCommandPool(device.device, commandPool.commandPool, nil)
	delete(commandPool.commandBuffers)
	delete(commandPool.usedCommandBuffers)
}

/* ----------------------- */
/* ----- Descriptors ----- */
/* ----------------------- */

DescriptorSetLayout :: struct {
	layout:   vk.DescriptorSetLayout,
	bindings: []vk.DescriptorSetLayoutBinding,
}

create_descriptor_set_layout :: proc(
	device: Device,
	bindings: []vk.DescriptorSetLayoutBinding,
	label := "",
	allocator := context.allocator,
) -> (
	layout: DescriptorSetLayout,
	result: vk.Result,
) {
	checkLabel(label)
	bindingFlags := make([]vk.DescriptorBindingFlags, len(bindings), context.temp_allocator)
	bindingInfo: vk.DescriptorSetLayoutBindingFlagsCreateInfo = {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(bindings)),
		pBindingFlags = raw_data(bindingFlags),
	}
	for &binding in bindingFlags {
		binding = .DescriptorIndexing in device.enabledCapabilities ? {.UPDATE_AFTER_BIND, .PARTIALLY_BOUND, .UPDATE_UNUSED_WHILE_PENDING} : {}
	}
	createInfo: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		flags        = .DescriptorIndexing in device.enabledCapabilities ? {.UPDATE_AFTER_BIND_POOL} : {},
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
		pNext        = &bindingInfo,
	}
	vk.CreateDescriptorSetLayout(device.device, &createInfo, nil, &layout.layout) or_return
	if len(label) > 0 {
		name(device, layout.layout, label)
	}
	layout.bindings = slice.clone(bindings, allocator)
	return
}

destroy_descriptor_set_layout :: proc(device: Device, layout: DescriptorSetLayout) {
	vk.DestroyDescriptorSetLayout(device.device, layout.layout, nil)
	delete(layout.bindings)
	return
}

DescriptorPool :: struct {
	pool:         vk.DescriptorPool,
	setCapacity:  u32,
	setAvailable: u32,
	capacity:     map[vk.DescriptorType]u32,
	available:    map[vk.DescriptorType]u32,
}

create_descriptor_pool :: proc(
	device: Device,
	#any_int maxSets: u32,
	layout: DescriptorSetLayout,
	label := "",
	allocator := context.allocator,
) -> (
	pool: DescriptorPool,
	result: vk.Result,
) {
	checkLabel(label)
	sizes := make(map[vk.DescriptorType]u32, context.temp_allocator)
	for binding in layout.bindings {
		if binding.descriptorType in sizes do sizes[binding.descriptorType] += binding.descriptorCount
		else do sizes[binding.descriptorType] = binding.descriptorCount
	}
	poolSizes := make([]vk.DescriptorPoolSize, len(sizes), context.temp_allocator)
	sizeIndex := 0
	for key, value in sizes {
		poolSizes[sizeIndex] = {
			type            = key,
			descriptorCount = value * maxSets,
		}
		sizeIndex += 1
	}
	createInfo: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = maxSets,
		poolSizeCount = u32(len(poolSizes)),
		pPoolSizes    = raw_data(poolSizes),
	}
	vk.CreateDescriptorPool(device.device, &createInfo, nil, &pool.pool) or_return
	if len(label) > 0 {
		name(device, pool.pool, label)
	}

	pool.capacity = make(map[vk.DescriptorType]u32, allocator)
	pool.available = make(map[vk.DescriptorType]u32, allocator)
	pool.setCapacity = maxSets
	pool.setAvailable = maxSets

	return
}

destroy_descriptor_pool :: proc(device: Device, pool: DescriptorPool) -> (result: vk.Result) {
	vk.DestroyDescriptorPool(device.device, pool.pool, nil)
	delete(pool.capacity)
	delete(pool.available)
	return
}

reset_descriptor_pool :: proc(device: Device, pool: ^DescriptorPool) -> (result: vk.Result) {
	vk.ResetDescriptorPool(device.device, pool.pool, {}) or_return
	for key, &value in pool.available {
		value = pool.capacity[key]
	}
	pool.setAvailable = pool.setCapacity
	return
}

allocate_descriptor_set :: proc(
	device: Device,
	pool: DescriptorPool,
	layout: DescriptorSetLayout,
	label := "",
) -> (
	descriptorSet: vk.DescriptorSet,
	result: vk.Result,
) {
	checkLabel(label)
	setLayout := layout.layout
	allocInfo: vk.DescriptorSetAllocateInfo = {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = pool.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &setLayout,
	}
	vk.AllocateDescriptorSets(device.device, &allocInfo, &descriptorSet) or_return
	if len(label) > 0 {
		name(device, descriptorSet, label)
	}
	return
}

update_descriptor_sets :: proc(device: Device, writes: []vk.WriteDescriptorSet = {}, copies: []vk.CopyDescriptorSet = {}) {
	for &write in writes do write.sType = .WRITE_DESCRIPTOR_SET
	for &copy in copies do copy.sType = .COPY_DESCRIPTOR_SET
	vk.UpdateDescriptorSets(device.device, u32(len(writes)), raw_data(writes), u32(len(copies)), raw_data(copies))
}

/* ------------------- */
/* ----- Shaders ----- */
/* ------------------- */

@(rodata)
SHADER_KIND_STAGES: [ShaderKind][]vk.ShaderStageFlag = {
	.Raster  = {.VERTEX, .FRAGMENT},
	.Mesh    = {.TASK_EXT, .MESH_EXT, .FRAGMENT},
	.Compute = {.COMPUTE},
}

ShaderKind :: enum {
	Raster,
	Mesh,
	Compute,
}

ShaderKinds :: bit_set[ShaderKind]

ShaderEntryPoint :: struct {
	name:  string,
	stage: vk.ShaderStageFlag,
}

ShaderInfo :: struct {
	kind:        ShaderKind,
	code:        []byte,
	entryPoints: []ShaderEntryPoint,
}

create_shader_module :: proc(device: Device, code: []byte, label := "") -> (module: vk.ShaderModule, result: vk.Result) {
	checkLabel(label)
	moduleInfo: vk.ShaderModuleCreateInfo = {
		sType    = .SHADER_MODULE_CREATE_INFO,
		flags    = {},
		codeSize = len(code),
		pCode    = cast(^u32)raw_data(code),
	}
	vk.CreateShaderModule(device.device, &moduleInfo, nil, &module) or_return
	if len(label) > 0 {
		name(device, module, label)
	}
	return
}
destroy_shader_module :: proc(device: Device, module: vk.ShaderModule) {
	vk.DestroyShaderModule(device.device, module, nil)
}

create_shader_object :: proc(
	device: Device,
	info: ShaderInfo,
	setLayouts: []vk.DescriptorSetLayout = {},
	pushConstantRanges: []vk.PushConstantRange = {},
	label := "",
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	shaders: []vk.ShaderEXT,
	stages: []vk.ShaderStageFlags,
	result: vk.Result,
) {
	checkLabel(label)
	if len(info.code) == 0 do return

	desiredStages := SHADER_KIND_STAGES[info.kind]
	selectedEntryPoints := make([dynamic]ShaderEntryPoint, context.temp_allocator)

	for stage in desiredStages {
		for entryPoint in info.entryPoints {
			if entryPoint.stage == stage {
				append(&selectedEntryPoints, entryPoint)
				break
			}
		}
	}

	shaderCount := len(selectedEntryPoints)
	if shaderCount == 0 do return

	// Ensure code begin and end are aligned to 4 bytes
	code := info.code
	if (uintptr(&code[0]) & (4 - 1) != 0) || (len(code) % 4 != 0) {
		c, _ := runtime.make_aligned([]byte, 4 * ((len(code) + 3) / 4), 4, context.temp_allocator)
		copy_slice(c, code)
		code = c
	}

	shaderCreateInfos, _ := make([]vk.ShaderCreateInfoEXT, shaderCount, context.temp_allocator)
	shaders, _ = make([]vk.ShaderEXT, shaderCount, allocator, loc)
	stages, _ = make([]vk.ShaderStageFlags, shaderCount, allocator, loc)

	for entryPoint, index in selectedEntryPoints {
		stages[index] = {entryPoint.stage}
	}

	for entryPoint, index in selectedEntryPoints {
		name := strings.clone_to_cstring(entryPoint.name, context.temp_allocator)
		shaderCreateInfos[index] = {
			sType                  = .SHADER_CREATE_INFO_EXT,
			flags                  = (len(selectedEntryPoints) > 1) ? {.LINK_STAGE} : {},
			stage                  = stages[index],
			nextStage              = {},
			codeType               = .SPIRV,
			codeSize               = len(code),
			pCode                  = raw_data(code),
			pName                  = name,
			setLayoutCount         = u32(len(setLayouts)),
			pSetLayouts            = raw_data(setLayouts),
			pushConstantRangeCount = u32(len(pushConstantRanges)),
			pPushConstantRanges    = raw_data(pushConstantRanges),
		}
		if entryPoint.stage == .MESH_EXT && slice.contains(stages, vk.ShaderStageFlags{.TASK_EXT}) {
			shaderCreateInfos[index].flags |= {.NO_TASK_SHADER}
		}
		for nextIndex := index + 1; nextIndex < len(stages); nextIndex += 1 {
			shaderCreateInfos[index].nextStage |= stages[nextIndex]
		}
	}

	check(vk.CreateShadersEXT(device.device, u32(shaderCount), raw_data(shaderCreateInfos), nil, raw_data(shaders))) or_return
	if len(label) > 0 {
		for shader, i in shaders {
			shaderLabel := len(shaders) > 1 ? fmt.tprintf("%s_%d", label, i) : label
			name(device, shader, shaderLabel)
		}
	}
	return
}

destroy_shader_object :: proc(device: Device, shader: vk.ShaderEXT) {
	vk.DestroyShaderEXT(device.device, shader, nil)
}

/* --------------------- */
/* ----- Pipelines ----- */
/* --------------------- */

create_pipeline_layout :: proc(
	device: Device,
	descriptorSetLayouts: []vk.DescriptorSetLayout = {},
	pushConstantRanges: []vk.PushConstantRange = {},
	label := "",
) -> (
	layout: vk.PipelineLayout,
	result: vk.Result,
) {
	checkLabel(label)
	createInfo: vk.PipelineLayoutCreateInfo = {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		flags                  = {},
		setLayoutCount         = u32(len(descriptorSetLayouts)),
		pSetLayouts            = raw_data(descriptorSetLayouts),
		pushConstantRangeCount = u32(len(pushConstantRanges)),
		pPushConstantRanges    = raw_data(pushConstantRanges),
	}

	check(vk.CreatePipelineLayout(device.device, &createInfo, nil, &layout)) or_return
	if len(label) > 0 {
		name(device, layout, label)
	}
	return
}

destroy_pipeline_layout :: proc(device: Device, layout: vk.PipelineLayout) {
	vk.DestroyPipelineLayout(device.device, layout, nil)
}

destroy_pipeline :: proc(device: Device, pipeline: vk.Pipeline) {
	vk.DestroyPipeline(device.device, pipeline, nil)
}

GraphicsTechnique :: struct {
	using rasterizationOptions: RasterizationOptions,
	using blendOptions:         BlendOptions,
	multisample:                vk.SampleCountFlags,
	shaderInfo:                 ShaderInfo,
	dynamicsState:              map[vk.DynamicState]struct{},
}

RasterizationOptions :: struct {
	topology:    vk.PrimitiveTopology,
	polygonMode: vk.PolygonMode,
	cullMode:    vk.CullModeFlags,
	frontFace:   vk.FrontFace,
	lineWidth:   f32,
}

BlendOptions :: struct {
	logicOperation: Maybe(vk.LogicOp),
	writeMask:      vk.ColorComponentFlags,
	colorOperation: Maybe(BlendOperation),
	alphaOperation: Maybe(BlendOperation),
}

BlendOperation :: struct {
	sourceFactor:      vk.BlendFactor,
	destinationFactor: vk.BlendFactor,
	operation:         vk.BlendOp,
}

create_graphics_pipeline :: proc(
	device: Device,
	shaderModule: vk.ShaderModule,
	layout: vk.PipelineLayout,
	technique: GraphicsTechnique,
	label := "",
) -> (
	pipeline: vk.Pipeline,
	ok: vk.Result,
) {
	checkLabel(label)
	technique := technique
	create_graphics_pipelines(device, shaderModule, layout, slice.from_ptr(&technique, 1), slice.from_ptr(&pipeline, 1), label) or_return
	return
}

create_graphics_pipelines :: proc(
	device: Device,
	shaderModule: vk.ShaderModule,
	layout: vk.PipelineLayout,
	techniques: []GraphicsTechnique,
	pipelines: []vk.Pipeline,
	label := "",
) -> (
	ok: vk.Result,
) {
	checkLabel(label)
	pipelineCount := len(techniques)
	makePipelineInfo :: #force_inline proc($T: typeid, count: int, loc := #caller_location) -> (array: []T, result: vk.Result) {
		arrayOk: mem.Allocator_Error
		if array, arrayOk = make([]T, count, context.temp_allocator); arrayOk != .None {
			result = .ERROR_OUT_OF_HOST_MEMORY
		}
		return
	}

	pipelineInfos := makePipelineInfo(vk.GraphicsPipelineCreateInfo, pipelineCount) or_return

	vertexInputState: vk.PipelineVertexInputStateCreateInfo = {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	inputAssemblyStates := makePipelineInfo(vk.PipelineInputAssemblyStateCreateInfo, pipelineCount) or_return
	tesselationState: vk.PipelineTessellationStateCreateInfo = {
		sType = .PIPELINE_TESSELLATION_STATE_CREATE_INFO,
	}
	viewportStates := makePipelineInfo(vk.PipelineViewportStateCreateInfo, pipelineCount) or_return
	rasterizationStates := makePipelineInfo(vk.PipelineRasterizationStateCreateInfo, pipelineCount) or_return
	multisampleStates := makePipelineInfo(vk.PipelineMultisampleStateCreateInfo, pipelineCount) or_return
	depthStencilStates := makePipelineInfo(vk.PipelineDepthStencilStateCreateInfo, pipelineCount) or_return
	colorBlendStates := makePipelineInfo(vk.PipelineColorBlendStateCreateInfo, pipelineCount) or_return
	colorBlendAttachmentStates := make([dynamic]vk.PipelineColorBlendAttachmentState, context.temp_allocator)
	dynamicStates := makePipelineInfo(vk.PipelineDynamicStateCreateInfo, pipelineCount) or_return

	dynamics: []vk.DynamicState = {
		// Viewport
		.VIEWPORT,
		.SCISSOR,
		.VIEWPORT_WITH_COUNT,
		.SCISSOR_WITH_COUNT,
		// Input Assembly
		.PRIMITIVE_TOPOLOGY,
		.PRIMITIVE_RESTART_ENABLE,
		// Rasterizer
		.RASTERIZER_DISCARD_ENABLE,
		.CULL_MODE,
		.FRONT_FACE,
		.LINE_WIDTH,
		.POLYGON_MODE_EXT,
		// Depth & Stencil
		.DEPTH_TEST_ENABLE,
		.DEPTH_WRITE_ENABLE,
		.DEPTH_COMPARE_OP,
		.DEPTH_BOUNDS_TEST_ENABLE,
		.DEPTH_BOUNDS,
		.STENCIL_TEST_ENABLE,
		.STENCIL_WRITE_MASK,
		.STENCIL_OP,
		.STENCIL_COMPARE_MASK,
		.STENCIL_REFERENCE,
		// Blend
		.BLEND_CONSTANTS,
	}

	for i in 0 ..< pipelineCount {
		shaderStages := make([dynamic]vk.PipelineShaderStageCreateInfo, context.temp_allocator)
		for entryPoint in techniques[i].shaderInfo.entryPoints {
			name := strings.clone_to_cstring(entryPoint.name, context.temp_allocator)
			stageInfo: vk.PipelineShaderStageCreateInfo = {
				sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage  = {entryPoint.stage},
				module = shaderModule,
				pName  = name,
			}
			append(&shaderStages, stageInfo)
		}
		inputAssemblyStates[i] = {
			sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology               = techniques[i].topology,
			primitiveRestartEnable = false,
		}
		viewportStates[i] = {
			sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1, // TODO: Query Max Viewport Count
			scissorCount  = 1, // TODO: Query Max Scissor Count
		}
		rasterizationStates[i] = {
			sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			depthClampEnable        = true,
			rasterizerDiscardEnable = true,
			polygonMode             = techniques[i].polygonMode,
			cullMode                = techniques[i].cullMode,
			frontFace               = techniques[i].frontFace,
			lineWidth               = techniques[i].lineWidth,
		}
		multisampleStates[i] = {
			sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = techniques[i].multisample,
		}
		depthStencilStates[i] = {
			sType           = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = false,
		}
		colorBlendLogicOp, colorBlendLogicOpOk := techniques[i].blendOptions.logicOperation.?
		cbColorOp, cbColorOpOk := techniques[i].blendOptions.colorOperation.?
		cbAlphaOp, cbAlphaOpOk := techniques[i].blendOptions.alphaOperation.?
		cbAttachmentIndex := append(
			&colorBlendAttachmentStates,
			vk.PipelineColorBlendAttachmentState {
				colorWriteMask = techniques[i].blendOptions.writeMask,
				blendEnable = b32(cbColorOpOk || cbAlphaOpOk),
				colorBlendOp = cbColorOp.operation,
				srcColorBlendFactor = cbColorOp.sourceFactor,
				dstColorBlendFactor = cbColorOp.destinationFactor,
				alphaBlendOp = cbAlphaOp.operation,
				srcAlphaBlendFactor = cbAlphaOp.sourceFactor,
				dstAlphaBlendFactor = cbAlphaOp.destinationFactor,
			},
		)
		colorBlendStates[i] = {
			sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			logicOpEnable   = b32(colorBlendLogicOpOk),
			logicOp         = colorBlendLogicOp,
			attachmentCount = 1,
			pAttachments    = &colorBlendAttachmentStates[cbAttachmentIndex],
		}
		dynamicStates[i] = {
			sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = u32(len(dynamics)),
			pDynamicStates    = raw_data(dynamics),
		}
		pipelineInfos[i] = {
			sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
			flags               = {},
			layout              = layout,
			stageCount          = u32(len(shaderStages)),
			pStages             = raw_data(shaderStages),
			pVertexInputState   = &vertexInputState,
			pInputAssemblyState = &inputAssemblyStates[i],
			pTessellationState  = &tesselationState,
			pViewportState      = &viewportStates[i],
			pRasterizationState = &rasterizationStates[i],
			pMultisampleState   = &multisampleStates[i],
			pDepthStencilState  = &depthStencilStates[i],
			pColorBlendState    = &colorBlendStates[i],
		}
	}

	check(vk.CreateGraphicsPipelines(device.device, {}, u32(pipelineCount), raw_data(pipelineInfos), nil, raw_data(pipelines))) or_return
	if len(label) > 0 {
		for pipeline, i in pipelines {
			pipelineLabel := len(pipelines) > 1 ? fmt.tprintf("%s_%d", label, i) : label
			name(device, pipeline, pipelineLabel)
		}
	}
	return
}

create_compute_pipeline :: proc(
	device: Device,
	shaderInfo: ShaderInfo,
	layout: vk.PipelineLayout,
	label := "",
) -> (
	module: vk.ShaderModule,
	pipeline: vk.Pipeline,
	ok: vk.Result,
) {
	checkLabel(label)

	assert(len(shaderInfo.entryPoints) == 1)
	module = create_shader_module(device, shaderInfo.code, label) or_return

	stageCreateInfo: vk.PipelineShaderStageCreateInfo = {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		flags  = {},
		stage  = {.COMPUTE},
		module = module,
		pName  = strings.clone_to_cstring(shaderInfo.entryPoints[0].name, context.temp_allocator),
	}

	createInfo: vk.ComputePipelineCreateInfo = {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		flags  = {},
		layout = layout,
		stage  = stageCreateInfo,
	}

	check(vk.CreateComputePipelines(device.device, {}, 1, &createInfo, nil, &pipeline)) or_return
	if len(label) > 0 {
		name(device, pipeline, label)
	}
	return
}

/* --------------------- */
/* ----- Resources ----- */
/* --------------------- */

GpuResource :: struct {
	deviceMemory: vk.DeviceMemory,
	offset:       vk.DeviceSize,
	size:         vk.DeviceSize,
	memoryType:   u32,
	memoryProps:  vk.MemoryPropertyFlags,
	sharingMode:  vk.SharingMode,
	mappedData:   rawptr,
}

@(require_results)
bind :: proc {
	bind_buffer_to_dedicated_memory,
	bind_buffer_to_dynamic_gpu_arena,
	bind_image_to_dedicated_memory,
	bind_image_to_dynamic_gpu_arena,
}

destroy_device_memory :: proc(device: Device, memory: vk.DeviceMemory) {
	vk.FreeMemory(device.device, memory, nil)
}

/* ------------------ */
/* ----- Buffer ----- */
/* ------------------ */

Buffer :: struct {
	buffer:            vk.Buffer,
	usage:             vk.BufferUsageFlags,
	using gpuResource: GpuResource,
}

BufferView :: struct {
	view: vk.BufferView,
}

@(require_results)
create_buffer :: proc(
	device: Device,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	sharingMode: vk.SharingMode = .EXCLUSIVE,
	queueFamilyIndices: []u32 = {},
	label := "",
) -> (
	buffer: Buffer,
	result: vk.Result,
) {
	checkLabel(label)
	bufferInfo: vk.BufferCreateInfo = {
		sType                 = .BUFFER_CREATE_INFO,
		size                  = size,
		usage                 = usage,
		sharingMode           = sharingMode,
		queueFamilyIndexCount = auto_cast len(queueFamilyIndices),
		pQueueFamilyIndices   = raw_data(queueFamilyIndices),
	}
	vk.CreateBuffer(device.device, &bufferInfo, nil, &buffer.buffer) or_return
	buffer.size, buffer.usage, buffer.sharingMode = size, usage, sharingMode
	if len(label) > 0 {
		name(device, buffer.buffer, label)
	}
	return
}

destroy_buffer :: proc(device: Device, buffer: Buffer) {
	vk.DestroyBuffer(device.device, buffer.buffer, nil)
}

@(require_results)
bind_buffer :: proc {
	bind_buffer_to_dedicated_memory,
	bind_buffer_to_dynamic_gpu_arena,
}

@(require_results)
bind_buffer_to_dedicated_memory :: proc(buffer: ^Buffer, device: Device, memoryType: u32, label := "") -> (memory: vk.DeviceMemory, result: vk.Result) {
	checkLabel(label)
	memoryRequirements := get_memory_requirements(device, buffer^)
	assert(bits.bitfield_extract(memoryRequirements.memoryTypeBits, auto_cast memoryType, 1) == 1)
	flags_info: vk.MemoryAllocateFlagsInfo
	alloc_info: vk.MemoryAllocateInfo = {
		sType           = .MEMORY_ALLOCATE_INFO,
		memoryTypeIndex = memoryType,
		allocationSize  = memoryRequirements.size,
	}
	if .BufferDeviceAddress in device.enabledCapabilities {
		flags_info = {
			sType = .MEMORY_ALLOCATE_FLAGS_INFO,
			flags = {.DEVICE_ADDRESS},
		}
		alloc_info.pNext = &flags_info
	}
	check(vk.AllocateMemory(device.device, &alloc_info, nil, &memory)) or_return
	check(vk.BindBufferMemory(device.device, buffer.buffer, memory, 0)) or_return
	buffer.deviceMemory, buffer.memoryType, buffer.memoryProps = memory, memoryType, get_memory_properties(device.physicalDevice, memoryType)
	if .HOST_VISIBLE in buffer.memoryProps {
		check(vk.MapMemory(device.device, buffer.deviceMemory, buffer.offset, buffer.size, {}, &buffer.mappedData)) or_return
	}
	if len(label) > 0 {
		name(device, buffer.deviceMemory, label)
	}
	return
}

@(require_results)
bind_buffer_to_dynamic_gpu_arena :: proc(buffer: ^Buffer, arena: ^DynamicGpuArena) -> (result: vk.Result) {
	memoryRequirements := get_memory_requirements(arena.device, buffer^)
	memory, offset, memoryType, mappedData := check(dynamic_gpu_arena_allocate_by_requirements(arena, memoryRequirements)) or_return
	check(vk.BindBufferMemory(arena.device.device, buffer.buffer, memory, offset)) or_return
	buffer.deviceMemory, buffer.offset, buffer.memoryType, buffer.memoryProps, buffer.mappedData =
		memory, offset, memoryType, get_memory_properties(arena.device.physicalDevice, memoryType), mappedData
	return
}

@(require_results)
create_buffer_view :: proc(
	device: Device,
	buffer: Buffer,
	format := vk.Format.UNDEFINED,
	offset: Maybe(vk.DeviceSize) = {},
	range: Maybe(vk.DeviceSize) = {},
	label := "",
) -> (
	view: BufferView,
	result: vk.Result,
) {
	checkLabel(label)
	createInfo: vk.BufferViewCreateInfo = {
		sType  = .BUFFER_VIEW_CREATE_INFO,
		flags  = {},
		buffer = buffer.buffer,
		format = format,
		offset = offset.(vk.DeviceSize) or_else 0,
		range  = range.(vk.DeviceSize) or_else buffer.size,
	}
	vk.CreateBufferView(device.device, &createInfo, nil, &view.view) or_return
	if len(label) > 0 {
		name(device, view.view, label)
	}
	return
}

destroy_buffer_view :: proc(device: Device, view: BufferView) {
	vk.DestroyBufferView(device.device, view.view, nil)
}

/* ----------------- */
/* ----- Image ----- */
/* ----------------- */

Image :: struct {
	image:             vk.Image,
	type:              vk.ImageType,
	format:            vk.Format,
	extent:            vk.Extent3D,
	usage:             vk.ImageUsageFlags,
	mipLevels:         u32,
	arrayLayers:       u32,
	samples:           vk.SampleCountFlags,
	tiling:            vk.ImageTiling,
	using gpuResource: GpuResource,
	stagingImage:      ^Image,
}

ImageView :: struct {
	view: vk.ImageView,
}

@(require_results)
create_image :: proc(
	device: Device,
	format: vk.Format,
	extent: vk.Extent3D,
	usage: vk.ImageUsageFlags = {},
	imageType: vk.ImageType = .D2,
	sharingMode: vk.SharingMode = .EXCLUSIVE,
	arrayLayers := u32(1),
	mipLevels := u32(1),
	samples: vk.SampleCountFlags = {._1},
	tiling := vk.ImageTiling.OPTIMAL,
	initialLayout: vk.ImageLayout = .UNDEFINED,
	queueFamilyIndices: []u32 = {},
	label := "",
) -> (
	image: Image,
	result: vk.Result,
) {
	checkLabel(label)
	imageInfo: vk.ImageCreateInfo = {
		sType                 = .IMAGE_CREATE_INFO,
		format                = format,
		extent                = extent,
		usage                 = usage,
		imageType             = imageType,
		sharingMode           = sharingMode,
		arrayLayers           = arrayLayers,
		mipLevels             = mipLevels,
		samples               = samples,
		tiling                = tiling,
		initialLayout         = initialLayout,
		queueFamilyIndexCount = auto_cast len(queueFamilyIndices),
		pQueueFamilyIndices   = raw_data(queueFamilyIndices),
	}
	vk.CreateImage(device.device, &imageInfo, nil, &image.image) or_return
	image.format, image.extent, image.size, image.usage, image.type, image.sharingMode, image.arrayLayers, image.mipLevels, image.samples, image.tiling =
		format,
		extent,
		vk.DeviceSize(extent.width * extent.height * extent.depth * get_bytes_per_pixel(format)),
		usage,
		imageType,
		sharingMode,
		arrayLayers,
		mipLevels,
		samples,
		tiling
	if len(label) > 0 {
		name(device, image.image, label)
	}
	return
}

destroy_image :: proc(device: Device, image: Image) {
	vk.DestroyImage(device.device, image.image, nil)
}

@(require_results)
bind_image :: proc {
	bind_image_to_dedicated_memory,
	bind_image_to_dynamic_gpu_arena,
}

@(require_results)
bind_image_to_dedicated_memory :: proc(image: ^Image, device: Device, memoryType: u32, label := "") -> (memory: vk.DeviceMemory, result: vk.Result) {
	checkLabel(label)
	memoryRequirements := get_memory_requirements(device, image^)
	assert(bits.bitfield_extract(memoryRequirements.memoryTypeBits, auto_cast memoryType, 1) == 1)
	flags_info: vk.MemoryAllocateFlagsInfo
	alloc_info: vk.MemoryAllocateInfo = {
		sType           = .MEMORY_ALLOCATE_INFO,
		memoryTypeIndex = memoryType,
		allocationSize  = memoryRequirements.size,
	}
	if .BufferDeviceAddress in device.enabledCapabilities {
		flags_info = {
			sType = .MEMORY_ALLOCATE_FLAGS_INFO,
			flags = {.DEVICE_ADDRESS},
		}
		alloc_info.pNext = &flags_info
	}
	check(vk.AllocateMemory(device.device, &alloc_info, nil, &memory)) or_return
	check(vk.BindImageMemory(device.device, image.image, memory, 0)) or_return
	image.deviceMemory, image.memoryType, image.memoryProps = memory, memoryType, get_memory_properties(device.physicalDevice, memoryType)
	if .HOST_VISIBLE in image.memoryProps && image.tiling == .LINEAR {
		check(vk.MapMemory(device.device, image.deviceMemory, image.offset, image.size, {}, &image.mappedData)) or_return
	}
	if len(label) > 0 {
		name(device, image.deviceMemory, label)
	}
	return
}

@(require_results)
bind_image_to_dynamic_gpu_arena :: proc(image: ^Image, arena: ^DynamicGpuArena) -> (result: vk.Result) {
	memoryRequirements := get_memory_requirements(arena.device, image^)
	memory, offset, memoryType, mappedData := check(dynamic_gpu_arena_allocate_by_requirements(arena, memoryRequirements)) or_return
	check(vk.BindImageMemory(arena.device.device, image.image, memory, offset)) or_return
	image.deviceMemory, image.offset, image.memoryType, image.memoryProps, image.mappedData =
		memory, offset, memoryType, get_memory_properties(arena.device.physicalDevice, memoryType), mappedData

	return
}

@(require_results)
create_image_view :: proc(
	device: Device,
	image: Image,
	format := vk.Format.UNDEFINED,
	aspectMask: vk.ImageAspectFlags = {.COLOR},
	components: vk.ComponentMapping = {},
	layer: u32 = 0,
	label := "",
) -> (
	view: ImageView,
	result: vk.Result,
) {
	checkLabel(label)
	createInfo: vk.ImageViewCreateInfo = {
		sType = .IMAGE_VIEW_CREATE_INFO,
		flags = {},
		image = image.image,
		viewType = image.type == .D1 ? .D1 : (image.type == .D2 ? .D2 : .D3),
		format = (format != .UNDEFINED) ? format : image.format,
		components = components,
		subresourceRange = {aspectMask = aspectMask, baseArrayLayer = layer, layerCount = 1, baseMipLevel = 0, levelCount = vk.REMAINING_MIP_LEVELS},
	}
	vk.CreateImageView(device.device, &createInfo, nil, &view.view) or_return
	if len(label) > 0 {
		name(device, view.view, label)
	}
	return
}

destroy_image_view :: proc(device: Device, view: ImageView) {
	vk.DestroyImageView(device.device, view.view, nil)
}

@(private = "package")
checkLabel :: #force_inline proc(label: string, loc := #caller_location) {
	when REQUIRE_RESOURCE_LABELS {
		if !EXCUSE_RESOURCE_LABELS {
			assert(len(label) > 0, "Resource label required when REQUIRE_RESOURCE_LABELS is enabled", loc)
		}
	}
}
