#+vet using-param

package vkField_vulkan

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import win32 "core:sys/windows"
import vk "vendor:vulkan"
import util "vkField:util"

/* -------------------- */
/* ----- Instance ----- */
/* -------------------- */

AppInfo :: struct {
	appName:       string,
	appVersion:    util.SemanticVersion,
	engineName:    string,
	engineVersion: util.SemanticVersion,
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
CreateInstance :: proc(
	appInfo: AppInfo,
	requiredExtensions: []string = {},
	optionalExtensions: []string = {},
	debugUserData: ^DebugUserData = nil,
	allocator := context.allocator,
) -> (
	instance: Instance,
	result: vk.Result,
) {
	using util

	instanceCreateInfo := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pNext            = nil,
		pApplicationInfo = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pNext = nil,
			pApplicationName = strings.clone_to_cstring(appInfo.appName, allocator),
			applicationVersion = vk.MAKE_VERSION(auto_cast appInfo.appVersion.major, auto_cast appInfo.appVersion.minor, auto_cast appInfo.appVersion.patch),
			pEngineName = strings.clone_to_cstring(appInfo.engineName, allocator),
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
		presentExtensions := GetRequiredInstancePresentationExtensions()
		extensions = slice.clone_to_dynamic(presentExtensions, context.temp_allocator)
	}

	when ODIN_OS == .Darwin {
		instanceCreateInfo.flags |= {.ENUMERATE_PORTABILITY_KHR}
		append(&extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
	}

	availableExtensionCount: u32
	for result = check(vk.EnumerateInstanceExtensionProperties(nil, &availableExtensionCount, nil)); result == .INCOMPLETE; {  }
	availableExtensions := make([]vk.ExtensionProperties, availableExtensionCount)
	for result = check(vk.EnumerateInstanceExtensionProperties(nil, &availableExtensionCount, raw_data(availableExtensions))); result == .INCOMPLETE; {  }

	when ENABLE_VALIDATION_LAYERS {
		validationLayer :: cstring("VK_LAYER_KHRONOS_validation")

		append(&instance.enabledLayers, validationLayer)
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

DestroyInstance :: proc(instance: ^Instance) {
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
CreateDebugMessenger :: proc(instance: Instance, userData: ^DebugUserData, allocator := context.allocator) -> (dbgMsg: DebugMessenger, result: vk.Result) {
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
	util.check(vk.CreateDebugUtilsMessengerEXT(instance.instance, &createInfo, nil, &dbgMsg.debugMessenger)) or_return
	return
}

DestroyDebugMessenger :: proc(instance: vk.Instance, dbgMsg: ^DebugMessenger) {
	vk.DestroyDebugUtilsMessengerEXT(instance, dbgMsg.debugMessenger, nil)
}

/* ------------------- */
/* ----- Surface ----- */
/* ------------------- */

CreateSurface :: proc {
	CreateWin32Surface,
}

CreateWin32Surface :: proc(instance: vk.Instance, window: win32.HWND, hInstance: win32.HINSTANCE) -> (surface: vk.SurfaceKHR, ok: vk.Result) {
	createInfo: vk.Win32SurfaceCreateInfoKHR = {
		sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
		flags     = {},
		hwnd      = window,
		hinstance = hInstance,
	}
	util.check(vk.CreateWin32SurfaceKHR(instance, &createInfo, nil, &surface)) or_return
	return
}

DestroySurface :: proc(instance: vk.Instance, surface: vk.SurfaceKHR) {
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
	// Swapchain Maintenance
	SwapchainMaintenance,
	// Shader Object
	ShaderObject,
	// Extensions
	Swapchain,
	FifoLatestReady,
}

DeviceCapabilities :: bit_set[DeviceCapability]

PhysicalDevice :: struct {
	name:           string,
	physicalDevice: vk.PhysicalDevice,
	properties:     vk.PhysicalDeviceProperties,
	capabilities:   DeviceCapabilities,
	queueFamilies:  []vk.QueueFamilyProperties,
}

@(require_results)
GetPhysicalDevices :: proc(instance: vk.Instance, allocator := context.allocator) -> (devices: #soa[]PhysicalDevice, result: vk.Result) {
	using util

	deviceCount: u32
	check(vk.EnumeratePhysicalDevices(instance, &deviceCount, nil)) or_return
	devices, _ = make(#soa[]PhysicalDevice, deviceCount, allocator)
	check(vk.EnumeratePhysicalDevices(instance, &deviceCount, devices.physicalDevice)) or_return

	features := MakeDeviceFeatures({}, context.temp_allocator)

	for &device in devices {
		vk.GetPhysicalDeviceProperties(device.physicalDevice, &device.properties)
		device.name = strings.clone_from_ptr(&device.properties.deviceName[0], len(device.properties.deviceName), allocator)
		queueFamilyCount: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(device.physicalDevice, &queueFamilyCount, nil)
		device.queueFamilies = make([]vk.QueueFamilyProperties, queueFamilyCount, allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(device.physicalDevice, &queueFamilyCount, raw_data(device.queueFamilies))
		extensionCount: u32

		vk.GetPhysicalDeviceFeatures2(device.physicalDevice, &features)
		check(vk.EnumerateDeviceExtensionProperties(device.physicalDevice, nil, &extensionCount, nil)) or_return
		extensions := make([]vk.ExtensionProperties, extensionCount, context.temp_allocator)
		check(vk.EnumerateDeviceExtensionProperties(device.physicalDevice, nil, &extensionCount, raw_data(extensions))) or_return
		device.capabilities = DeduceDeviceCapabilities(features, extensions)
	}
	return
}

FreePhysicalDevices :: proc(devices: #soa[]PhysicalDevice, allocator := context.allocator) {
	for device in devices {
		free(&device.queueFamilies, allocator)
	}
	free(devices, allocator)
}

/* ------------------ */
/* ----- Device ----- */
/* ------------------ */

Device :: struct {
	using PhysicalDevice: PhysicalDevice,
	device:               vk.Device,
	gpuAllocator:         vma.Allocator,
	multiQueueIndex:      u32,
	computeQueueIndex:    u32,
	transferQueueIndex:   u32,
	headlessQueueIndex:   u32,
	presentQueueIndex:    u32,
	queues:               map[u32]vk.Queue,
	enabledCapabilities:  DeviceCapabilities,
}

@(require_results)
CreateDevice :: proc(
	instance: Instance,
	physicalDevice: PhysicalDevice,
	criteria: DeviceCriteria,
	allocator := context.allocator,
) -> (
	device: Device,
	result: vk.Result,
) {
	using util
	context.allocator = allocator

	defer check(result != .SUCCESS || device.device != {})

	queueIndices := make(map[u32]u32)

	computeQueueIndex: u32
	computeQueueIndex = GetComputeQueue(physicalDevice.physicalDevice, physicalDevice.queueFamilies)
	queueIndices[computeQueueIndex] = 1

	transferQueueIndex: u32
	transferQueueIndex = GetTransferQueue(physicalDevice.physicalDevice, physicalDevice.queueFamilies)
	queueIndices[transferQueueIndex] = 1

	headlessQueueIndex: Maybe(u32)
	if criteria.graphics {
		headlessQueueIndex = GetHeadlessQueue(physicalDevice.physicalDevice, physicalDevice.queueFamilies)
		queueIndices[headlessQueueIndex.(u32)] = 1
	}

	presentQueueIndex: Maybe(u32)
	if criteria.present {
		presentQueueIndex = assert(GetPresentQueue(physicalDevice.physicalDevice, physicalDevice.queueFamilies))
		queueIndices[presentQueueIndex.(u32)] = 1
	}

	multiQueueIndex: Maybe(u32)
	if criteria.graphics && criteria.present {
		multiQueueIndex = assert(GetMultiQueue(physicalDevice.physicalDevice, physicalDevice.queueFamilies))
		queueIndices[multiQueueIndex.(u32)] = 1
	}

	queueCreateInfos := make([]vk.DeviceQueueCreateInfo, len(queueIndices))
	totalQueueCount: u32
	for _, queueCount in queueIndices {
		totalQueueCount += queueCount
	}

	queuePriorities := make([]f32, totalQueueCount)
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

	device.enabledCapabilities = criteria.requiredCapabilities + (criteria.optionalCapabilities & device.capabilities)
	enabledExtensions := make([dynamic]cstring, context.temp_allocator)
	AddCapabilityExtensions(&enabledExtensions, device.enabledCapabilities)

	deviceFeatures := MakeDeviceFeatures(device.enabledCapabilities)

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
	device.PhysicalDevice = physicalDevice

	device.queues = make(map[u32]vk.Queue, allocator)
	for queueIndex, _ in queueIndices {
		queue: vk.Queue
		vk.GetDeviceQueue(device.device, queueIndex, 0, &queue)
		device.queues[queueIndex] = queue
	}

	device.gpuAllocator = check(CreateAllocator(instance, device)) or_return
	return
}

DestroyDevice :: proc(device: ^Device) {
	vk.DestroyDevice(device.device, nil)
}

/* ------------------------ */
/* ----- VmaAllocator ----- */
/* ------------------------ */

CreateAllocator :: proc(instance: Instance, device: Device) -> (gpuAllocator: vma.Allocator, result: vk.Result) {
	vulkanFunctions: vma.VulkanFunctions = vma.create_vulkan_functions() // TODO: Move to initialize function
	createInfo: vma.AllocatorCreateInfo = {
		vulkanApiVersion = instance.apiVersion,
		flags            = {},
		instance         = instance.instance,
		physicalDevice   = device.physicalDevice,
		device           = device.device,
		pVulkanFunctions = &vulkanFunctions,
	}
	util.check(vma.CreateAllocator(&createInfo, &gpuAllocator)) or_return
	return
}

DestroyAllocator :: proc(allocator: vma.Allocator) {
	vma.DestroyAllocator(allocator)
	return
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
CreateSwapchain :: proc(
	device: ^Device,
	surface: vk.SurfaceKHR,
	criteria: SwapCriteria,
	label: string = "",
	allocator := context.allocator,
) -> (
	swapchain: Swapchain,
	result: vk.Result,
) {
	using util

	defer check(result != .SUCCESS || swapchain.swapchain != {})
	defer check(result != .SUCCESS || swapchain.surface != {})

	swapchain.support = QuerySwapchainSupport(device.physicalDevice, surface, allocator) or_return
	surfaceFormat, formatOk := ChooseSwapSurfaceFormat(swapchain.support.formats, criteria)
	presentMode := ChooseSwapPresentMode(swapchain.support.presentModes, criteria)
	extent := ChooseSwapExtent(swapchain.support.capabilities, criteria)
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

	MakeSwapchain(device^, &createInfo, &swapchain, label)
	return
}

RecreateSwapchain :: proc(
	device: Device,
	oldSwapchain: Swapchain,
	criteria: SwapCriteria,
	allocator := context.allocator,
	label: string = "",
) -> (
	swapchain: Swapchain,
	result: vk.Result,
) {
	using util

	swapchain.support = QuerySwapchainSupport(device.physicalDevice, oldSwapchain.surface, allocator) or_return
	surfaceFormat, formatOk := check(ChooseSwapSurfaceFormat(swapchain.support.formats, criteria))
	if !formatOk do return {}, .ERROR_FORMAT_NOT_SUPPORTED
	presentMode := ChooseSwapPresentMode(swapchain.support.presentModes, criteria)
	extent := ChooseSwapExtent(swapchain.support.capabilities, criteria)

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
	MakeSwapchain(device, &createInfo, &swapchain, label) or_return
	return
}

@(private)
MakeSwapchain :: proc(device: Device, createInfo: ^vk.SwapchainCreateInfoKHR, swapchain: ^Swapchain, label: string = "") -> (result: vk.Result) {
	using util

	check(swapchain.swapchain == {} || swapchain.swapchain == createInfo.oldSwapchain)
	defer check(len(swapchain.images) >= auto_cast createInfo.minImageCount)
	defer check(len(swapchain.images) == len(swapchain.views))
	defer check(len(swapchain.images) == len(swapchain.semaphores))

	check(vk.CreateSwapchainKHR(device.device, createInfo, nil, &swapchain.swapchain)) or_return
	name(device, swapchain.swapchain, fmt.tprintf("Swapchain %s", label))

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
		image.sampleCount = {._1}

		swapchain.views[index] = check(CreateImageView(device, image)) or_return
		swapchain.semaphores[index] = CreateBinarySemaphore(device) or_return
		name(device, swapchain.images.image[index], fmt.tprintf("Swapchain %s Image %d", label, index))
		name(device, swapchain.views.view[index], fmt.tprintf("Swapchain %s Image View %d", label, index))
		name(device, cast(vk.Semaphore)swapchain.semaphores[index], fmt.tprintf("Swapchain %s Binary Semaphore %d", label, index))
	}
	return
}

DestroySwapchain :: proc(device: Device, swapchain: Swapchain) {
	delete(swapchain.views)
	for &view in swapchain.views {
		v := view
		DestroyImageView(device, v)
		view = v
	}
	for &sempahore in swapchain.semaphores {
		s := sempahore
		DestroySemaphore(device, auto_cast s)
		sempahore = s
	}
	vk.DestroySwapchainKHR(device.device, swapchain.swapchain, nil)
}

SwapLength :: proc(swapchain: Swapchain) -> int {
	return len(swapchain.images)
}

/* ----------------- */
/* ----- Fence ----- */
/* ----------------- */

CreateFence :: proc(device: Device, signaled: bool = false) -> (fence: vk.Fence, result: vk.Result) {
	info: vk.FenceCreateInfo = {
		sType = .FENCE_CREATE_INFO,
		flags = signaled ? {.SIGNALED} : {},
	}
	vk.CreateFence(device.device, &info, nil, &fence) or_return
	return
}

DestroyFence :: proc(device: Device, fence: vk.Fence) {
	vk.DestroyFence(device.device, fence, nil)
}

/* --------------------- */
/* ----- Semaphore ----- */
/* --------------------- */

TimelineSemaphore :: distinct vk.Semaphore

BinarySemaphore :: distinct vk.Semaphore

CreateBinarySemaphore :: proc(device: Device) -> (semaphore: BinarySemaphore, result: vk.Result) {
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
	util.check(vk.CreateSemaphore(device.device, &createInfo, nil, auto_cast &semaphore)) or_return
	return
}

CreateTimelineSemaphore :: proc(device: Device, initialValue: u64 = 0) -> (semaphore: TimelineSemaphore, result: vk.Result) {
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
	util.check(vk.CreateSemaphore(device.device, &createInfo, nil, auto_cast &semaphore)) or_return
	return
}

DestroySemaphore :: proc {
	DestroyBinarySemaphore,
	DestroyTimelineSemaphore,
}

DestroyBinarySemaphore :: proc(device: Device, semaphore: BinarySemaphore) {
	vk.DestroySemaphore(device.device, auto_cast semaphore, nil)
}

DestroyTimelineSemaphore :: proc(device: Device, semaphore: TimelineSemaphore) {
	vk.DestroySemaphore(device.device, auto_cast semaphore, nil)
}

/* ------------------ */
/* ----- Events ----- */
/* ------------------ */

Event :: struct {
	event:      vk.Event,
	deviceOnly: bool,
}

CreateEvent :: proc(device: Device, deviceOnly: bool) -> (event: vk.Event, result: vk.Result) {
	eventCreateInfo: vk.EventCreateInfo = {
		sType = .EVENT_CREATE_INFO,
		flags = deviceOnly ? {.DEVICE_ONLY} : {},
	}

	util.check(vk.CreateEvent(device.device, &eventCreateInfo, nil, &event)) or_return
	return
}

DestroyEvent :: proc(device: Device, event: Event) {
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

CreateCommandPool :: proc(
	device: Device,
	queueIndex: u32,
	resetCommandBuffers := false,
	allocator := context.allocator,
) -> (
	commandPool: CommandPool,
	result: vk.Result,
) {
	createInfo: vk.CommandPoolCreateInfo = {
		sType            = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = queueIndex,
		flags            = resetCommandBuffers ? {.RESET_COMMAND_BUFFER} : {},
	}
	util.check(vk.CreateCommandPool(device.device, &createInfo, nil, &commandPool.commandPool)) or_return
	commandPool.commandBuffers = make([dynamic]vk.CommandBuffer, allocator)
	commandPool.usedCommandBuffers = make([dynamic]vk.CommandBuffer, allocator)
	commandPool.resetCommandBuffers = .RESET_COMMAND_BUFFER in createInfo.flags
	return
}

GetCommandBuffer :: proc(device: Device, commandPool: ^CommandPool) -> (commandBuffer: vk.CommandBuffer, result: vk.Result) {
	result = GetCommandBuffers(device, commandPool, slice.from_ptr(&commandBuffer, 1))
	return
}

GetCommandBuffers :: proc(device: Device, commandPool: ^CommandPool, commandBuffers: []vk.CommandBuffer) -> (result: vk.Result) {
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
		util.check(AllocateCommandBuffers(device, commandPool.commandPool, commandBuffers[available:])) or_return
	}

	append_elems(&commandPool.usedCommandBuffers, ..commandBuffers)
	return
}

AllocateCommandBuffers :: proc(device: Device, commandPool: vk.CommandPool, commandBuffers: []vk.CommandBuffer) -> (result: vk.Result) {
	allocInfo: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = commandPool,
		commandBufferCount = u32(len(commandBuffers)),
		level              = .PRIMARY,
	}
	util.check(vk.AllocateCommandBuffers(device.device, &allocInfo, raw_data(commandBuffers))) or_return
	return
}

ResetCommandPool :: proc(device: Device, commandPool: ^CommandPool) -> (result: vk.Result) {
	util.check(vk.ResetCommandPool(device.device, commandPool.commandPool, {})) or_return
	append(&commandPool.commandBuffers, ..commandPool.usedCommandBuffers[:])
	clear(&commandPool.usedCommandBuffers)
	return
}

ResetCommandBuffer :: proc(device: Device, commandPool: ^CommandPool, commandBuffer: vk.CommandBuffer) {
	util.check(commandPool.resetCommandBuffers)
	index, found := util.check(slice.linear_search(commandPool.usedCommandBuffers[:], commandBuffer))
	util.check(vk.ResetCommandBuffer(commandBuffer, {}))
	unordered_remove(&commandPool.usedCommandBuffers, index)
	append(&commandPool.commandBuffers, commandBuffer)
	return
}

DestroyCommandPool :: proc(device: Device, commandPool: CommandPool) {
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

CreateDescriptorSetLayout :: proc(
	device: Device,
	bindings: []vk.DescriptorSetLayoutBinding,
	allocator := context.allocator,
) -> (
	layout: DescriptorSetLayout,
	result: vk.Result,
) {
	bindingFlags := make([]vk.DescriptorBindingFlags, len(bindings), context.temp_allocator)
	bindingInfo: vk.DescriptorSetLayoutBindingFlagsCreateInfo = {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(bindings)),
		pBindingFlags = raw_data(bindingFlags),
	}
	for &binding in bindingFlags {
		binding = {.UPDATE_AFTER_BIND, .PARTIALLY_BOUND, .UPDATE_UNUSED_WHILE_PENDING}
	}
	createInfo: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		flags        = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
		pNext        = &bindingInfo,
	}
	vk.CreateDescriptorSetLayout(device.device, &createInfo, nil, &layout.layout) or_return
	layout.bindings = slice.clone(bindings, allocator)
	return
}

DestroyDescriptorSetLayout :: proc(device: Device, layout: DescriptorSetLayout) -> (result: vk.Result) {
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

CreateDescriptorPool :: proc(
	device: Device,
	#any_int maxSets: u32,
	layout: DescriptorSetLayout,
	allocator := context.allocator,
) -> (
	pool: DescriptorPool,
	result: vk.Result,
) {
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

	pool.capacity = make(map[vk.DescriptorType]u32, allocator)
	pool.available = make(map[vk.DescriptorType]u32, allocator)
	pool.setCapacity = maxSets
	pool.setAvailable = maxSets

	return
}

DestroyDescriptorPool :: proc(device: Device, pool: DescriptorPool) -> (result: vk.Result) {
	vk.DestroyDescriptorPool(device.device, pool.pool, nil)
	delete(pool.capacity)
	delete(pool.available)
	return
}

ResetDescriptorPool :: proc(device: Device, pool: ^DescriptorPool) -> (result: vk.Result) {
	vk.ResetDescriptorPool(device.device, pool.pool, {}) or_return
	for key, &value in pool.available {
		value = pool.capacity[key]
	}
	pool.setAvailable = pool.setCapacity
	return
}

AllocateDescriptorSet :: proc(device: Device, pool: DescriptorPool, layout: DescriptorSetLayout) -> (descriptorSet: vk.DescriptorSet, result: vk.Result) {
	setLayout := layout.layout
	allocInfo: vk.DescriptorSetAllocateInfo = {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = pool.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &setLayout,
	}
	vk.AllocateDescriptorSets(device.device, &allocInfo, &descriptorSet) or_return
	return
}

UpdateDescriptorSets :: proc(device: Device, writes: []vk.WriteDescriptorSet = {}, copies: []vk.CopyDescriptorSet = {}) {
	vk.UpdateDescriptorSets(device.device, u32(len(writes)), raw_data(writes), u32(len(copies)), raw_data(copies))
}

/* ------------------- */
/* ----- Shaders ----- */
/* ------------------- */

shaderInfo :: struct {
	code:       []byte,
	entryPoint: string,
	stage:      vk.ShaderStageFlags,
}

CreateShaderModule :: proc(device: Device, code: []byte) -> (module: vk.ShaderModule, result: vk.Result) {
	moduleInfo: vk.ShaderModuleCreateInfo = {
		sType    = .SHADER_MODULE_CREATE_INFO,
		flags    = {},
		codeSize = len(code),
		pCode    = cast(^u32)raw_data(code),
	}
	vk.CreateShaderModule(device.device, &moduleInfo, nil, &module) or_return
	return
}
DestroyShaderModule :: proc(device: Device, module: vk.ShaderModule) {
	vk.DestroyShaderModule(device.device, module, nil)
}

CreateShaderObject :: proc(
	device: Device,
	shaderModule: rdm_shdr.ShaderModule,
	setLayouts: []vk.DescriptorSetLayout = {},
	pushConstantRanges: []vk.PushConstantRange = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	shaders: []vk.ShaderEXT,
	stages: []vk.ShaderStageFlags,
	result: vk.Result,
) {
	shaderCount := len(shaderModule.entryPoints)
	if shaderCount == 0 do return

	shaderCreateInfos, _ := make([]vk.ShaderCreateInfoEXT, shaderCount, context.temp_allocator)
	shaders, _ = make([]vk.ShaderEXT, shaderCount, allocator, loc)
	stages, _ = make([]vk.ShaderStageFlags, shaderCount, allocator, loc)

	stageOrder :: [?]vk.ShaderStageFlag{.VERTEX, .TESSELLATION_CONTROL, .TESSELLATION_EVALUATION, .GEOMETRY, .FRAGMENT}

	presentStages := make(map[vk.ShaderStageFlag]struct{}, context.temp_allocator)
	for entryPoint in shaderModule.entryPoints {
		presentStages[rdm_shdr.convertStage(entryPoint.stage)] = {}
	}

	for entryPoint, index in shaderModule.entryPoints {
		name := strings.clone_to_cstring(entryPoint.name, context.temp_allocator)
		stage := rdm_shdr.convertStage(entryPoint.stage)
		shaderCreateInfos[index] = {
			sType                  = .SHADER_CREATE_INFO_EXT,
			flags                  = len(shaderModule.entryPoints) > 1 ? {.LINK_STAGE} : {},
			stage                  = {stage},
			nextStage              = {},
			codeType               = .SPIRV,
			codeSize               = len(shaderModule.code),
			pCode                  = raw_data(shaderModule.code),
			pName                  = name,
			setLayoutCount         = u32(len(setLayouts)),
			pSetLayouts            = raw_data(setLayouts),
			pushConstantRangeCount = u32(len(pushConstantRanges)),
			pPushConstantRanges    = raw_data(pushConstantRanges),
		}
		if entryPoint.stage == .MESH && .TASK_EXT not_in presentStages {
			shaderCreateInfos[index].flags |= {.NO_TASK_SHADER}
		}
		stageIndex: int
		for order, ind in stageOrder {
			(order == stage) or_continue
			stageIndex = ind
			break
		}
		for order, ind in stageOrder {
			if ind > stageIndex && order in presentStages {
				shaderCreateInfos[index].nextStage |= {order}
			}
		}
		stages[index] = {stage}
	}

	vk.CreateShadersEXT(device.device, u32(shaderCount), raw_data(shaderCreateInfos), nil, raw_data(shaders)) or_return
	return
}

DestroyShaderObject :: proc(device: Device, shader: vk.ShaderEXT) {
	vk.DestroyShaderEXT(device.device, shader, nil)
}

/* --------------------- */
/* ----- Pipelines ----- */
/* --------------------- */

CreatePipelineLayout :: proc(
	device: Device,
	descriptorSetLayouts: []vk.DescriptorSetLayout = {},
	pushConstantRanges: []vk.PushConstantRange = {},
) -> (
	layout: vk.PipelineLayout,
	result: vk.Result,
) {
	createInfo: vk.PipelineLayoutCreateInfo = {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		flags                  = {},
		setLayoutCount         = u32(len(descriptorSetLayouts)),
		pSetLayouts            = raw_data(descriptorSetLayouts),
		pushConstantRangeCount = u32(len(pushConstantRanges)),
		pPushConstantRanges    = raw_data(pushConstantRanges),
	}

	vk.CreatePipelineLayout(device.device, &createInfo, nil, &layout) or_return
	return
}

DestroyPipelineLayout :: proc(device: Device, layout: vk.PipelineLayout) {
	vk.DestroyPipelineLayout(device.device, layout, nil)
}

DestroyPipeline :: proc(device: Device, pipeline: vk.Pipeline) {
	vk.DestroyPipeline(device.device, pipeline, nil)
}

GraphicsTechnique :: struct {
	using rasterizationOptions: RasterizationOptions,
	using blendOptions:         BlendOptions,
	multisample:                vk.SampleCountFlags,
	shaderModule:               rdm_shdr.ShaderModule,
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

CreateGraphicsPipeline :: proc(device: Device, shaderModule: vk.ShaderModule, technique: GraphicsTechnique) -> (pipeline: vk.Pipeline, ok: vk.Result) {
	CreateGraphicsPipeline(device, shaderModule, slice.from_ptr(&technique, 1), slice.from_ptr(&pipeline, 1))
}

CreateGraphicsPipelines :: proc(device: Device, shaderModule: vk.ShaderModule, techniques: []GraphicsTechnique, pipelines: []vk.Pipeline) -> (ok: vk.Result) {
	pipelineCount := len(techniques)
	makePipelineInfo :: #force_inline proc($T: typeid, count: int, loc := #caller_location) -> (array: []T, result: vk.Result) {
		arrayOk: mem.Allocator_Error
		if array, arrayOk = make([]T, count, context.temp_allocator); arrayOk != .None {
			log.warn("Allocation failed", loc)
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
		for entryPoint in techniques[i].shaderModule.entryPoints {
			name := strings.clone_to_cstring(entryPoint.name, context.temp_allocator)
			stageInfo: vk.PipelineShaderStageCreateInfo = {
				sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage  = {shader.convertStage(entryPoint.stage)},
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

	vk.CreateGraphicsPipelines(device.device, {}, u32(pipelineCount), raw_data(pipelineInfos), nil, raw_data(pipelines))
	return
}

/* --------------------- */
/* ----- Resources ----- */
/* --------------------- */

ResourceProperty :: enum int {
	Dedicated,
	HostAccessible,
	Uploadable,
	Downloadable,
	DevicePreferred,
	HostPreferred,
	Aliased,
	HighPriority,
}

ResourceProperties :: bit_set[ResourceProperty]

GpuResource :: struct {
	allocation:         vma.Allocation,
	deviceMemory:       vk.DeviceMemory,
	memoryProps:        vk.MemoryPropertyFlags,
	offset:             vk.DeviceSize,
	size:               vk.DeviceSize,
	sharingMode:        vk.SharingMode,
	resourceProperties: ResourceProperties,
	data:               rawptr,
}

/* ------------------ */
/* ----- Buffer ----- */
/* ------------------ */

Buffer :: struct {
	buffer:            vk.Buffer,
	usage:             vk.BufferUsageFlags,
	using gpuResource: GpuResource,
}

CreateBuffer :: proc(
	gpuAllocator: vma.Allocator,
	bufferInfo: ^vk.BufferCreateInfo,
	resourceProperties: ResourceProperties,
) -> (
	buffer: Buffer,
	result: vk.Result,
) {
	allocCreateInfo := MakeAllocationInfo(resourceProperties)

	if NeedsStaging(resourceProperties) {
		bufferInfo.usage |= .Uploadable in resourceProperties ? {.TRANSFER_DST} : {}
		bufferInfo.usage |= .Downloadable in resourceProperties ? {.TRANSFER_SRC} : {}
	}

	allocInfo: vma.AllocationInfo

	vma.CreateBuffer(gpuAllocator, bufferInfo, &allocCreateInfo, &buffer.buffer, &buffer.allocation, &allocInfo) or_return
	vma.GetAllocationMemoryProperties(gpuAllocator, buffer.allocation, &buffer.memoryProps)

	buffer.deviceMemory = allocInfo.deviceMemory
	buffer.offset = allocInfo.offset
	buffer.size = allocInfo.size
	buffer.sharingMode = bufferInfo.sharingMode
	buffer.resourceProperties = resourceProperties

	buffer.usage = bufferInfo.usage
	if !NeedsStaging(buffer) {
		buffer.data = allocInfo.pMappedData
	}
	return
}

DestroyBuffer :: proc(device: Device, gpuAllocator: vma.Allocator, buffer: Buffer) {
	if buffer.allocation != {} {
		vma.DestroyBuffer(gpuAllocator, buffer.buffer, buffer.allocation)
	} else {
		vk.DestroyBuffer(device.device, buffer.buffer, nil)
	}
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
	sampleCount:       vk.SampleCountFlags,
	mipLevels:         u32,
	arrayLayers:       u32,
	using gpuResource: GpuResource,
	stagingImage:      ^Image,
}

ImageView :: struct {
	view: vk.ImageView,
}

CreateImage :: proc(gpuAllocator: vma.Allocator, imageInfo: ^vk.ImageCreateInfo, resourceProperties: ResourceProperties) -> (image: Image, result: vk.Result) {
	allocCreateInfo := MakeAllocationInfo(resourceProperties)

	if NeedsStaging(resourceProperties) {
		imageInfo.usage |= .Uploadable in resourceProperties ? {.TRANSFER_DST} : {}
		imageInfo.usage |= .Downloadable in resourceProperties ? {.TRANSFER_SRC} : {}
	}

	allocInfo: vma.AllocationInfo

	vma.CreateImage(gpuAllocator, imageInfo, &allocCreateInfo, &image.image, &image.allocation, &allocInfo) or_return
	vma.GetAllocationMemoryProperties(gpuAllocator, image.allocation, &image.memoryProps)

	image.deviceMemory = allocInfo.deviceMemory
	image.offset = allocInfo.offset
	image.size = allocInfo.size
	image.type = imageInfo.imageType
	image.sharingMode = imageInfo.sharingMode
	image.resourceProperties = resourceProperties
	image.mipLevels = imageInfo.mipLevels
	image.arrayLayers = imageInfo.arrayLayers

	image.format = imageInfo.format
	image.extent = imageInfo.extent
	image.usage = imageInfo.usage
	image.sampleCount = imageInfo.samples
	if !NeedsStaging(image) {
		image.data = allocInfo.pMappedData
	}
	return
}

DestroyImage :: proc(device: Device, gpuAllocator: vma.Allocator, image: Image) {
	if image.allocation != {} {
		vma.DestroyImage(gpuAllocator, image.image, image.allocation)
	} else {
		vk.DestroyImage(device.device, image.image, nil)
	}
}

CreateImageView :: proc(
	device: Device,
	image: Image,
	format := vk.Format.UNDEFINED,
	aspectMask: vk.ImageAspectFlags = {.COLOR},
	components: vk.ComponentMapping = {},
	layer: u32 = 0,
) -> (
	view: ImageView,
	result: vk.Result,
) {
	createInfo: vk.ImageViewCreateInfo = {
		sType = .IMAGE_VIEW_CREATE_INFO,
		flags = {},
		image = image.image,
		viewType = image.type == .D1 ? .D1 : (image.type == .D2 ? .D2 : .D3),
		format = image.format,
		components = components,
		subresourceRange = {aspectMask = aspectMask, baseArrayLayer = layer, layerCount = 1, baseMipLevel = 0, levelCount = vk.REMAINING_MIP_LEVELS},
	}
	vk.CreateImageView(device.device, &createInfo, nil, &view.view) or_return
	return
}

DestroyImageView :: proc(device: Device, view: ImageView) {
	vk.DestroyImageView(device.device, view.view, nil)
}
