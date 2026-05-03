package vkField_vulkan

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/bits"
import "core:strings"
import vk "vendor:vulkan"
import vkField_util "vkField:utility"

@(private = "file")
assume :: vkField_util.assume
@(private = "file")
assert :: vkField_util.assert
@(private = "file")
check :: vkField_util.check

DEVICE_FEATURE_EXTENSIONS: [DeviceCapability][]cstring : #partial{
	.AtomicAddFloat32Buffer = {vk.EXT_SHADER_ATOMIC_FLOAT_EXTENSION_NAME},
	.Swapchain = {vk.KHR_SWAPCHAIN_EXTENSION_NAME},
	.SwapchainMaintenance = {vk.EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME},
	.MeshShader = {vk.EXT_MESH_SHADER_EXTENSION_NAME},
	.FifoLatestReady = {vk.EXT_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME},
	.ShaderObject = {vk.EXT_SHADER_OBJECT_EXTENSION_NAME},
	.ExternalMemoryHost = {vk.EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME},
}
@(rodata)
WINDOW_PRESENT_EXTENSIONS := []string{vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_WIN32_SURFACE_EXTENSION_NAME}
@(rodata)
DARWIN_PRESENT_EXTENSIONS := []string{vk.KHR_SURFACE_EXTENSION_NAME, vk.EXT_METAL_SURFACE_EXTENSION_NAME}
@(rodata)
LINUX_PRESENT_EXTENSIONS := []string {
	vk.KHR_SURFACE_EXTENSION_NAME,
	vk.KHR_XCB_SURFACE_EXTENSION_NAME,
	vk.KHR_XLIB_SURFACE_EXTENSION_NAME,
	vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME,
}
get_required_instance_presentation_extensions :: proc() -> []string {
	when ODIN_OS == .Windows {
		return WINDOW_PRESENT_EXTENSIONS
	} else when ODIN_OS == .Darwin {
		return DARWIN_PRESENT_EXTENSIONS
	} else when ODIN_OS == .Linux {
		return LINUX_PRESENT_EXTENSIONS
	}
}

deduce_device_capabilities :: proc(features2: vk.PhysicalDeviceFeatures2, extensions: []vk.ExtensionProperties) -> (capabilities: DeviceCapabilities) {
	// We start with all capabilities set as the unsetting operator allows for early exit if any requirements are unmet
	capabilities = ~{}

	if !features2.features.geometryShader { capabilities -= {.GeometryShaders} }
	if !features2.features.tessellationShader { capabilities -= {.TessellationShaders} }
	if !features2.features.sampleRateShading { capabilities -= {.SampleRateShading} }
	if !features2.features.logicOp { capabilities -= {.LogicOp} }
	if !features2.features.multiDrawIndirect { capabilities -= {.MultiDrawIndirect} }
	if !features2.features.depthClamp { capabilities -= {.DepthClamp} }
	if !features2.features.depthBounds { capabilities -= {.DepthBounds} }
	if !features2.features.wideLines { capabilities -= {.WideLines} }
	if !features2.features.largePoints { capabilities -= {.LargePoints} }
	if !features2.features.multiViewport { capabilities -= {.MultiViewport} }
	if !features2.features.samplerAnisotropy { capabilities -= {.SamplerAnisotropy} }
	if !features2.features.shaderFloat64 { capabilities -= {.ShaderFloat64} }
	if !features2.features.shaderInt64 { capabilities -= {.ShaderInt64} }
	if !features2.features.shaderInt16 { capabilities -= {.ShaderInt16} }
	pNext: ^vk.BaseInStructure = auto_cast features2.pNext
	for pNext != nil {
		#partial switch pNext.sType {
		case .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES:
			vulkan11Features := ((cast(^vk.PhysicalDeviceVulkan11Features)pNext)^)
			if !vulkan11Features.multiview { capabilities -= {.MultiView} }
			if !vulkan11Features.shaderDrawParameters { capabilities -= {.ShaderDrawParameters} }
		case .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES:
			vulkan12Features := ((cast(^vk.PhysicalDeviceVulkan12Features)pNext)^)
			if !vulkan12Features.drawIndirectCount { capabilities -= {.DrawIndirectCount} }
			if !vulkan12Features.shaderFloat16 { capabilities -= {.ShaderFloat16} }
			if !vulkan12Features.shaderInt8 { capabilities -= {.ShaderInt8} }
			if !vulkan12Features.descriptorIndexing { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingUniformBufferUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingSampledImageUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingStorageImageUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingStorageBufferUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingUniformTexelBufferUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingStorageTexelBufferUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingUpdateUnusedWhilePending { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingPartiallyBound { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.runtimeDescriptorArray { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.timelineSemaphore { capabilities -= {.TimelineSemaphore} }
			if !vulkan12Features.bufferDeviceAddress { capabilities -= {.BufferDeviceAddress} }
			if !vulkan12Features.descriptorBindingVariableDescriptorCount { capabilities -= {.VariableDescriptorCount} }
		case .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES:
			vulkan13Features := ((cast(^vk.PhysicalDeviceVulkan13Features)pNext)^)
			if !vulkan13Features.synchronization2 { capabilities -= {.Synchronization2} }
			if !vulkan13Features.dynamicRendering { capabilities -= {.DynamicRendering} }
			if !vulkan13Features.maintenance4 { capabilities -= {.Maintenance4} }
		case .PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT:
			atomicFloatFeatures := ((cast(^vk.PhysicalDeviceShaderAtomicFloatFeaturesEXT)pNext)^)
			if !atomicFloatFeatures.shaderBufferFloat32AtomicAdd { capabilities -= {.AtomicAddFloat32Buffer} }
		case .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT:
			swapchainMaintenance1 := ((cast(^vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT)pNext)^)
			if !swapchainMaintenance1.swapchainMaintenance1 { capabilities -= {.SwapchainMaintenance} }
		case .PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_EXT:
			presentModeFifoLatestReady := ((cast(^vk.PhysicalDevicePresentModeFifoLatestReadyFeaturesEXT)pNext)^)
			if !presentModeFifoLatestReady.presentModeFifoLatestReady { capabilities -= {.FifoLatestReady} }
		case .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT:
			shaderObject := ((cast(^vk.PhysicalDeviceShaderObjectFeaturesEXT)pNext)^)
			if !shaderObject.shaderObject { capabilities -= {.ShaderObject} }
		case .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT:
			meshShader := ((cast(^vk.PhysicalDeviceMeshShaderFeaturesEXT)pNext)^)
			if !meshShader.meshShader { capabilities -= {.MeshShader} }
		}
		pNext = auto_cast pNext.pNext
	}

	featureExtensions := DEVICE_FEATURE_EXTENSIONS
	for feature in DeviceCapability {
		if feature not_in capabilities {
			continue
		}
		extensionLoop: for extension in featureExtensions[feature] {
			pExtension := strings.clone_from_cstring_bounded(extension, vk.MAX_EXTENSION_NAME_SIZE, context.temp_allocator)
			for &extension in extensions {
				pDeviceExtension := byte_arr_str(&extension.extensionName)
				if strings.compare(pExtension, pDeviceExtension) == 0 {
					continue extensionLoop
				}
			}
			capabilities -= {feature}
		}
	}
	return
}

make_device_features :: proc(
	capabilities: DeviceCapabilities,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	features2: vk.PhysicalDeviceFeatures2,
) {
	features2 = {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		features = {
			geometryShader = .GeometryShaders in capabilities,
			tessellationShader = .TessellationShaders in capabilities,
			sampleRateShading = .SampleRateShading in capabilities,
			logicOp = .LogicOp in capabilities,
			multiDrawIndirect = .MultiDrawIndirect in capabilities,
			depthClamp = .DepthClamp in capabilities,
			depthBounds = .DepthBounds in capabilities,
			wideLines = .WideLines in capabilities,
			largePoints = .LargePoints in capabilities,
			multiViewport = .MultiViewport in capabilities,
			samplerAnisotropy = .SamplerAnisotropy in capabilities,
			shaderFloat64 = .ShaderFloat64 in capabilities,
			shaderInt64 = .ShaderInt64 in capabilities,
			shaderInt16 = .ShaderInt16 in capabilities,
		},
	}

	vk11Features := new(vk.PhysicalDeviceVulkan11Features, allocator, loc)
	vk11Features^ = {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		multiview            = .MultiView in capabilities,
		shaderDrawParameters = .ShaderDrawParameters in capabilities,
	}
	features2.pNext = vk11Features

	vk12Features := new(vk.PhysicalDeviceVulkan12Features, allocator, loc)
	vk12Features^ = {
		sType                                              = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		drawIndirectCount                                  = .DrawIndirectCount in capabilities,
		shaderFloat16                                      = .ShaderFloat16 in capabilities,
		shaderInt8                                         = .ShaderInt8 in capabilities,
		descriptorIndexing                                 = .DescriptorIndexing in capabilities,
		descriptorBindingUniformBufferUpdateAfterBind      = .DescriptorIndexing in capabilities,
		descriptorBindingSampledImageUpdateAfterBind       = .DescriptorIndexing in capabilities,
		descriptorBindingStorageImageUpdateAfterBind       = .DescriptorIndexing in capabilities,
		descriptorBindingStorageBufferUpdateAfterBind      = .DescriptorIndexing in capabilities,
		descriptorBindingUniformTexelBufferUpdateAfterBind = .DescriptorIndexing in capabilities,
		descriptorBindingStorageTexelBufferUpdateAfterBind = .DescriptorIndexing in capabilities,
		descriptorBindingUpdateUnusedWhilePending          = .DescriptorIndexing in capabilities,
		descriptorBindingPartiallyBound                    = .DescriptorIndexing in capabilities,
		runtimeDescriptorArray                             = .DescriptorIndexing in capabilities,
		descriptorBindingVariableDescriptorCount           = .VariableDescriptorCount in capabilities,
		timelineSemaphore                                  = .TimelineSemaphore in capabilities,
		bufferDeviceAddress                                = .BufferDeviceAddress in capabilities,
	}
	vk11Features.pNext = vk12Features

	vk13Features := new(vk.PhysicalDeviceVulkan13Features, allocator, loc)
	vk13Features^ = {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		synchronization2 = .Synchronization2 in capabilities,
		dynamicRendering = .DynamicRendering in capabilities,
		maintenance4     = .Maintenance4 in capabilities,
	}
	vk12Features.pNext = vk13Features

	atomicFloatFeatures := new(vk.PhysicalDeviceShaderAtomicFloatFeaturesEXT, allocator, loc)
	atomicFloatFeatures^ = {
		sType                        = .PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT,
		shaderBufferFloat32AtomicAdd = .AtomicAddFloat32Buffer in capabilities,
	}
	vk13Features.pNext = atomicFloatFeatures

	pNext: ^vk.BaseInStructure = auto_cast atomicFloatFeatures

	if .SwapchainMaintenance in capabilities {
		swapchainMaintenance := new(vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT, allocator, loc)
		swapchainMaintenance^ = {
			sType                 = .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT,
			swapchainMaintenance1 = .SwapchainMaintenance in capabilities,
		}
		pNext.pNext = auto_cast swapchainMaintenance
		pNext = auto_cast swapchainMaintenance
	}

	if .ShaderObject in capabilities {
		shaderObject := new(vk.PhysicalDeviceShaderObjectFeaturesEXT, allocator, loc)
		shaderObject^ = {
			sType        = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
			shaderObject = .ShaderObject in capabilities,
		}
		pNext.pNext = auto_cast shaderObject
		pNext = auto_cast shaderObject
	}

	if .FifoLatestReady in capabilities {
		presentModeFifoLatestReady := new(vk.PhysicalDevicePresentModeFifoLatestReadyFeaturesEXT, allocator, loc)
		presentModeFifoLatestReady^ = {
			sType                      = .PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_EXT,
			presentModeFifoLatestReady = .FifoLatestReady in capabilities,
		}
		pNext.pNext = auto_cast presentModeFifoLatestReady
		pNext = auto_cast presentModeFifoLatestReady
	}

	if .MeshShader in capabilities {
		meshShader := new(vk.PhysicalDeviceMeshShaderFeaturesEXT, allocator, loc)
		meshShader^ = {
			sType      = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
			meshShader = .MeshShader in capabilities,
		}
		pNext.pNext = auto_cast meshShader
		pNext = auto_cast meshShader
	}
	return
}

delete_device_features :: proc(features2: vk.PhysicalDeviceFeatures2, allocator := context.allocator) {
	cur: ^vk.BaseInStructure
	for pNext: ^vk.BaseInStructure = auto_cast features2.pNext;; pNext = pNext.pNext {
		if cur != nil do free(cur, allocator)
		if pNext == nil do break
		cur = pNext
	}
	if cur != nil do free(cur, allocator)
}

add_capability_extensions :: proc(extensions: ^[dynamic]cstring, capabilities: DeviceCapabilities) {
	featureExtensions := DEVICE_FEATURE_EXTENSIONS
	for feature in capabilities {
		for extension in featureExtensions[feature] {
			append(extensions, extension)
		}
	}
}

@(require_results)
pick_physical_device :: proc(instance: vk.Instance, devices: #soa[]PhysicalDevice, criteria: DeviceCriteria) -> (chosenDevice: PhysicalDevice, ok: bool) {
	if len(devices) == 0 { ok = false; return }

	bestDeviceScore := 0

	for &device in devices {
		d := device
		if score := scorePhysicalDevice(&d, criteria); score > bestDeviceScore {
			chosenDevice = d
			bestDeviceScore = score
		}
		device = d
	}

	ok = bestDeviceScore > 0
	return

	scorePhysicalDevice :: proc(device: ^PhysicalDevice, criteria: DeviceCriteria) -> (score: int) {
		name := byte_arr_str(&device.properties.deviceName) // Can't I use cString -> string casting?
		log.infof("vulkan: evaluating device %q", name)
		defer log.infof("vulkan: device %q scored %v", name, score)

		// Check Required Capabilities
		{
			if unavailableRequiredCapabilities := criteria.requiredCapabilities - device.capabilities; unavailableRequiredCapabilities != {} {
				log.infof("vulkan: device %q does not support required capabilities %q", name, unavailableRequiredCapabilities)
				return 0
			}

			optionalCapabilitiesWeight :: 10
			unavailableOptionalCapabilities := criteria.optionalCapabilities - device.capabilities
			if unavailableOptionalCapabilities != {} {
				log.infof("vulkan: device %q does not support optional capabilities %q", name, unavailableOptionalCapabilities)
			}
			score -= optionalCapabilitiesWeight * int(intrinsics.count_ones(transmute(u64)(unavailableOptionalCapabilities)))
		}

		if criteria.graphics {
			hasGraphics: bool
			for family in device.queueFamilies {
				if .GRAPHICS in family.queueFlags {
					hasGraphics = true
					break
				}
			}

			if !hasGraphics {
				log.infof("vulkan: device %q does not have a queue family that supports graphics", name)
				return 0
			}
		}

		if criteria.present {
			if .Swapchain not_in device.capabilities {
				log.infof("vulkan: device %q can not present as it does not have swapchain support", name)
				return 0
			}

			hasPresent: bool
			for _, index in device.queueFamilies {
				if CheckPresentSupport(device.physicalDevice, index) {
					hasPresent = true
					break
				}
			}

			if !hasPresent {
				log.infof("vulkan: device %q does not have a queue family that supports presenting", name)
				return 0
			}
		}

		// Favor GPUs.
		switch device.properties.deviceType {
		case .DISCRETE_GPU:
			score += 300_000
		case .INTEGRATED_GPU:
			score += 200_000
		case .VIRTUAL_GPU:
			score += 100_000
		case .CPU, .OTHER:
		}
		log.infof("vulkan: scored %i based on device type %v", score, device.properties.deviceType)

		// Maximum texture size.
		score += int(device.properties.limits.maxImageDimension2D)
		log.infof("vulkan: added the max 2D image dimensions (texture size) of %v to the score", device.properties.limits.maxImageDimension2D)
		return
	}
}

CheckPresentSupport :: #force_inline proc(physicalDevice: vk.PhysicalDevice, familyIndex: int) -> b32 {
	when ODIN_OS == .Windows {
		return vk.GetPhysicalDeviceWin32PresentationSupportKHR != nil && vk.GetPhysicalDeviceWin32PresentationSupportKHR(physicalDevice, u32(familyIndex))
	} else {
		vkField_util.throw_not_implemented()
		return false
	}
}

query_swapchain_support :: proc(
	device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	allocator := context.allocator,
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

	result = .SUCCESS
	return
}

get_compute_queue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> u32 {
	computeQueue: u32
	for family, index in families {
		if .COMPUTE in family.queueFlags {
			if .GRAPHICS not_in family.queueFlags {
				return u32(index)
			}
			computeQueue = u32(index)
		}
	}
	return computeQueue
}

get_transfer_queue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> u32 {
	transferQueue: u32
	for family, index in families {
		if .TRANSFER in family.queueFlags {
			if .GRAPHICS not_in family.queueFlags && .COMPUTE not_in family.queueFlags && !CheckPresentSupport(device, index) {
				return u32(index)
			}
			transferQueue = u32(index)
		}
	}
	return transferQueue
}

get_headless_queue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> u32 {
	headlessQueue: u32
	for family, index in families {
		if .GRAPHICS in family.queueFlags {
			if .COMPUTE not_in family.queueFlags && !CheckPresentSupport(device, index) {
				return u32(index)
			}
			headlessQueue = u32(index)
		}
	}
	return headlessQueue
}

get_present_queue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> (queueIndex: Maybe(u32), result: vk.Result) {
	for family, index in families {
		if CheckPresentSupport(device, index) {
			queueIndex = u32(index)
			if .COMPUTE not_in family.queueFlags {
				return
			}
		}
	}
	return
}

get_multi_queue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> (queueIndex: Maybe(u32), result: vk.Result) {
	for family, index in families {
		if .GRAPHICS in family.queueFlags && .COMPUTE in family.queueFlags && CheckPresentSupport(device, index) {
			queueIndex = u32(index)
			return
		}
	}
	return
}

choose_swap_surface_format :: proc(formats: []vk.SurfaceFormatKHR, criteria: SwapCriteria) -> (surfaceFormat: vk.SurfaceFormatKHR, ok: bool) {
	if criteria.supportHdr {
		log.panic("TODO: Support HDR")
	}

	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format, true
		}
	}
	if (len(formats) > 0) {
		return formats[0], true
	}
	return
}

choose_swap_present_mode :: proc(presentModes: []vk.PresentModeKHR, criteria: SwapCriteria) -> vk.PresentModeKHR {
	// Uncapped framerate via Triple Buffering
	if criteria.uncappedFrameRate {
		for presentMode in presentModes {
			if presentMode == .MAILBOX {
				return presentMode
			}
		}
	}

	// Allows for higher frequency updates
	// TODO: need to enable VK_EXT_present_mode_fifo_latest_ready
	// May cause tearing, but prevents large frame drops, if we miss the blanking period
	if criteria.supportsFifoLatestReady {
		for presentMode in presentModes {
			if presentMode == .FIFO_LATEST_READY_EXT {
				return presentMode
			}
		}
	}

	// VSync, frames can be missed, one update per display refresh
	return .FIFO
}

choose_swap_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR, criteria: SwapCriteria) -> vk.Extent2D {
	// Use the extent provided by the window
	if (capabilities.currentExtent.width != bits.U32_MAX) {
		return capabilities.currentExtent
	} else { 	// Estimate the best extent to use within capabilities
		return {
			width = clamp(criteria.framebufferSize.x, capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
			height = clamp(criteria.framebufferSize.y, capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
		}
	}
}

/* ------------------ */
/* ----- Memory ----- */
/* ------------------ */

find_memory_type_proc :: #type proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool)

// Finds memory for long term use on the GPU, with minimal direct interaction with the CPU.
find_private_memory_type :: proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool) {
	requiredProperties, preferrredProperties, unpreferrredProperties: vk.MemoryPropertyFlags
	requiredProperties += {.DEVICE_LOCAL}
	unpreferrredProperties += {.HOST_VISIBLE}
	#partial switch physicalDevice.properties.deviceType {
	case .INTEGRATED_GPU:
		requiredProperties -= {.DEVICE_LOCAL}
		preferrredProperties += {.DEVICE_LOCAL}
	}
	return find_best_memory_type(physicalDevice, memoryRequirements, requiredProperties, preferrredProperties, unpreferrredProperties)
}

// Finds memory suitable for constant CPU -> GPU upload and/or dynamic/transient GPU use. Typically corresponds to (Re)BAR Memory if it exists.
find_streaming_memory_type :: proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool) {
	requiredProperties, preferrredProperties, unpreferrredProperties: vk.MemoryPropertyFlags
	requiredProperties += {.DEVICE_LOCAL, .HOST_VISIBLE} // BAR Memory is characterized by being host visible despite being on the device
	preferrredProperties += {.HOST_COHERENT} // Host visible memory is basically always host coherent, but we should avoid the few exceptions
	unpreferrredProperties += {.HOST_CACHED} // Caching behaviour will be counterproductive for streaming
	#partial switch physicalDevice.properties.deviceType {
	case .INTEGRATED_GPU:
		requiredProperties -= {.DEVICE_LOCAL}
		preferrredProperties += {.DEVICE_LOCAL} // Arguable whether we should target device local memory on a iGPU, but as long as these are allocated after dedicated allocations it's not a big deal
	}
	return find_best_memory_type(physicalDevice, memoryRequirements, requiredProperties, preferrredProperties, unpreferrredProperties)
}

// Finds memory suitable for CPU -> GPU staging.
find_staging_memory_type :: proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool) {
	requiredProperties, preferrredProperties, unpreferrredProperties: vk.MemoryPropertyFlags
	requiredProperties += {.HOST_VISIBLE} // Memory of this type must be host visible
	preferrredProperties += {.HOST_COHERENT} // Host visible memory is basically always host coherent, but we should avoid the few exceptions
	unpreferrredProperties += {.HOST_CACHED, .DEVICE_LOCAL} // Caching isn't necessary for sequential writing and will only reduce performance.
	// Even if we can find device local memory that satisifies this, we shouldn't waste it on a staging buffer that doesn't need it
	return find_best_memory_type(physicalDevice, memoryRequirements, requiredProperties, preferrredProperties, unpreferrredProperties)
}

// Finds memory suitable for GPU -> CPU readback.
find_readback_memory_type :: proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool) {
	requiredProperties, preferrredProperties, unpreferrredProperties: vk.MemoryPropertyFlags
	requiredProperties += {.HOST_VISIBLE, .HOST_CACHED} // Memory of this type must be host visible, and for fast random access it is practically necessary that is is host cached
	preferrredProperties += {.HOST_COHERENT} // Host visible memory is basically always host coherent, but we should avoid the few exceptions

	#partial switch physicalDevice.properties.deviceType {
	case .INTEGRATED_GPU:
		// APUs' device local heaps are often only 256 MB
		// We shouldn't waste memory on readback uses
		unpreferrredProperties += {.DEVICE_LOCAL}
	}
	return find_best_memory_type(physicalDevice, memoryRequirements, requiredProperties, preferrredProperties, unpreferrredProperties)
}

find_best_memory_type :: proc(
	physicalDevice: PhysicalDevice,
	memoryRequirements: vk.MemoryRequirements,
	requiredProperties: vk.MemoryPropertyFlags = {},
	preferrredProperties: vk.MemoryPropertyFlags = {},
	unpreferrredProperties: vk.MemoryPropertyFlags = {},
) -> (
	typeIndex: u32 = bits.U32_MAX,
	ok := false,
) {
	budget, usage := get_memory_budget(physicalDevice)
	minScore: u32 = bits.U32_MAX
	for memoryType, index in physicalDevice.memoryTypes {
		if bits.bitfield_extract(memoryRequirements.memoryTypeBits, auto_cast index, 1) == 1 &&
		   requiredProperties <= memoryType.propertyFlags &&
		   budget[memoryType.heapIndex] - usage[memoryType.heapIndex] >= memoryRequirements.size + (memoryRequirements.alignment - 1) {
			ok = true
			typeScore :=
				transmute(u32)intrinsics.count_ones(preferrredProperties - memoryType.propertyFlags) +
				transmute(u32)intrinsics.count_ones(unpreferrredProperties & memoryType.propertyFlags)
			if typeScore < minScore {
				typeIndex = auto_cast index
				minScore = typeScore
			}
			if minScore == 0 do return
		}
	}
	return
}

get_memory_budget :: proc(physicalDevice: PhysicalDevice) -> (budget, usage: [dynamic; vk.MAX_MEMORY_HEAPS]vk.DeviceSize) {
	budgetInfo: vk.PhysicalDeviceMemoryBudgetPropertiesEXT = {
		sType = .PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT,
	}
	memoryProperties: vk.PhysicalDeviceMemoryProperties2 = {
		sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
		pNext = &budgetInfo,
	}
	vk.GetPhysicalDeviceMemoryProperties2(physicalDevice.physicalDevice, &memoryProperties)
	append(&budget, ..budgetInfo.heapBudget[:len(physicalDevice.memoryHeaps)])
	append(&usage, ..budgetInfo.heapUsage[:len(physicalDevice.memoryHeaps)])
	return
}

get_memory_properties :: proc(physicalDevice: PhysicalDevice, memoryType: u32) -> vk.MemoryPropertyFlags {
	return physicalDevice.memoryTypes[memoryType].propertyFlags
}

DYNAMIC_GPU_ARENA_STARTING_ALLOCATION_SIZE :: 256 * runtime.Megabyte
DYNAMIC_GPU_ARENA_BLOCK_COUNT :: 16
DYNAMIC_GPU_ARENA_GROW_RATE :: 1.25
DYNAMIC_GPU_ARENA_MAX_ALLOCATION_SIZE :: 2 * runtime.Gigabyte

DynamicGpuArena :: struct {
	label:            string,
	device:           Device,
	memoryTypes:      [dynamic; vk.MAX_MEMORY_TYPES]u32,
	blocks:           [dynamic; DYNAMIC_GPU_ARENA_BLOCK_COUNT]Memory,
	offsets:           [dynamic; DYNAMIC_GPU_ARENA_BLOCK_COUNT]vk.DeviceSize,
	currentBlockSize: vk.DeviceSize,
}

dynamic_gpu_arena_init :: proc(device: Device, memoryTypes: [dynamic; vk.MAX_MEMORY_TYPES]u32, label := "") -> (arena: DynamicGpuArena, ok := true) {
	assert(device.device != {})
	check(len(memoryTypes) > 0) or_return
	checkLabel(label)
	arena = {
		label            = label,
		device           = device,
		memoryTypes      = memoryTypes,
		currentBlockSize = DYNAMIC_GPU_ARENA_STARTING_ALLOCATION_SIZE,
	}
	return
}

dynamic_gpu_arena_allocate_by_requirements :: proc(
	arena: ^DynamicGpuArena,
	requirements: vk.MemoryRequirements,
) -> (
	memory: Memory,
	offset: vk.DeviceSize,
	result := vk.Result.ERROR_OUT_OF_DEVICE_MEMORY,
) {
	return dynamic_gpu_arena_allocate(arena, requirements.size, requirements.alignment, requirements.memoryTypeBits)
}

dynamic_gpu_arena_allocate :: proc(
	arena: ^DynamicGpuArena,
	size, alignment: vk.DeviceSize,
	validMemoryTypes: u32 = bits.U32_MAX,
) -> (
	memory: Memory,
	offset: vk.DeviceSize,
	result : vk.Result,
) {
	assert(size <= DYNAMIC_GPU_ARENA_MAX_ALLOCATION_SIZE)
	for index in 0..<len(arena.blocks) {
		memory = arena.blocks[index]
		if bits.bitfield_extract(validMemoryTypes, auto_cast memory.type, 1) != 1 do continue
		offset = auto_cast runtime.align_forward(cast(uint)arena.offsets[index], cast(uint)alignment)
		if memory.size >= size + offset {
			arena.offsets[index] = offset + size
			return
		}
	}

	if len(arena.blocks) < cap(arena.blocks) {
		for mt in arena.memoryTypes {
			if bits.bitfield_extract(validMemoryTypes, auto_cast mt, 1) != 1 do continue
			arena.currentBlockSize = cast(vk.DeviceSize)min(
				cast(f32)arena.currentBlockSize * DYNAMIC_GPU_ARENA_GROW_RATE,
				DYNAMIC_GPU_ARENA_MAX_ALLOCATION_SIZE,
			)
			label: string
			if len(arena.label) > 0 {
				label = fmt.tprintf("%s Block #%d", arena.label, len(arena.blocks))
			}
			memory = allocate_memory(arena.device, mt, arena.currentBlockSize, label) or_continue
			append(&arena.blocks, memory)
			return
		}
	}
	return {}, {}, vk.Result.ERROR_OUT_OF_DEVICE_MEMORY
}

dynamic_gpu_arena_clear :: proc(arena: ^DynamicGpuArena) {
	for &offset in arena.offsets {
		offset = 0
	}
}

dynamic_gpu_arena_free :: proc(arena: ^DynamicGpuArena) {
	for &block in arena.blocks {
		// if .HOST_VISIBLE in get_memory_properties(arena.device.physicalDevice, block.memoryTypeIndex) {
		// 	vk.UnmapMemory(arena.device.device, block.memory)
		// }
		vk.FreeMemory(arena.device.device, block.memory, nil)
	}
	clear(&arena.blocks)
	arena.currentBlockSize = DYNAMIC_GPU_ARENA_STARTING_ALLOCATION_SIZE
}

/* --------------------- */
/* ----- Resources ----- */
/* --------------------- */

// Get Resource Memory Management
get_memory_requirements :: proc {
	get_memory_requirements_buffer,
	get_memory_requirements_image,
}

get_memory_requirements_buffer :: proc(device: Device, buffer: Buffer) -> (memoryRequirements: vk.MemoryRequirements) {
	vk.GetBufferMemoryRequirements(device.device, buffer.buffer, &memoryRequirements)
	return
}

get_memory_requirements_image :: proc(device: Device, image: Image) -> (memoryRequirements: vk.MemoryRequirements) {
	vk.GetImageMemoryRequirements(device.device, image.image, &memoryRequirements)
	return
}

create_staging_buffer :: proc {
	create_staging_buffer_for_buffer,
	create_staging_buffer_for_image,
}

create_staging_buffer_for_buffer :: proc(arena: ^DynamicGpuArena, buffer: Buffer, label := "") -> (stagingBuffer: Buffer, result: vk.Result) {
	stagingBuffer = create_buffer(arena.device, buffer.size, {.TRANSFER_SRC}, .EXCLUSIVE, label = label) or_return
	bind_buffer_to_dynamic_gpu_arena(arena, &stagingBuffer) or_return
	return
}

create_staging_buffer_for_image :: proc(arena: ^DynamicGpuArena, image: Image, label := "") -> (stagingBuffer: Buffer, result: vk.Result) {
	stagingBuffer = create_buffer(arena.device, image.size, {.TRANSFER_SRC}, .EXCLUSIVE, label = label) or_return
	bind_buffer_to_dynamic_gpu_arena(arena, &stagingBuffer) or_return
	return
}

create_readback_buffer :: proc {
	create_readback_buffer_for_buffer,
	create_readback_buffer_for_image,
}

create_readback_buffer_for_buffer :: proc(arena: ^DynamicGpuArena, buffer: Buffer, label := "") -> (readbackBuffer: Buffer, result: vk.Result) {
	readbackBuffer = create_buffer(arena.device, buffer.size, {.TRANSFER_DST}, .EXCLUSIVE, label = label) or_return
	bind_buffer_to_dynamic_gpu_arena(arena, &readbackBuffer) or_return
	return
}

create_readback_buffer_for_image :: proc(arena: ^DynamicGpuArena, image: Image, label := "") -> (readbackBuffer: Buffer, result: vk.Result) {
	readbackBuffer = create_buffer(arena.device, image.size, {.TRANSFER_DST}, .EXCLUSIVE, label = label) or_return
	bind_buffer_to_dynamic_gpu_arena(arena, &readbackBuffer) or_return
	return
}

/* --------------------- */
/* ----- Commands ----- */
/* --------------------- */

WaitSemaphore :: struct {
	sempahore: vk.Semaphore,
	value:     u64,
}

wait_semaphores :: proc(
	device: Device,
	waitSemaphores: #soa[]WaitSemaphore,
	timeout: u64,
	flags: vk.SemaphoreWaitFlags = {},
	allocator := context.temp_allocator,
) -> vk.Result {
	waitInfo: vk.SemaphoreWaitInfo = {
		sType          = .SEMAPHORE_WAIT_INFO,
		pNext          = nil,
		flags          = {},
		semaphoreCount = u32(len(waitSemaphores)),
		pSemaphores    = waitSemaphores.sempahore,
		pValues        = waitSemaphores.value,
	}
	return vk.WaitSemaphores(device.device, &waitInfo, timeout)
}

read_from_buffer :: proc(buffer: Buffer, data: []byte, regions: []vk.BufferCopy2 = {}) {
	assert(.HOST_VISIBLE in buffer.memory.properties && .HOST_COHERENT in buffer.memory.properties)
	assume(.HOST_CACHED not_in buffer.memory.properties)

	regions := regions
	if len(regions) == 0 {
		regions = {{sType = .BUFFER_COPY_2, size = min(vk.DeviceSize(len(data)), buffer.size)}}
	}

	for region in regions {
		copy(data[region.dstOffset:][:region.size], get_buffer_mapped_data(buffer)[region.srcOffset:][:region.size])
	}
}

cmd_transition :: proc(commandBuffer: vk.CommandBuffer, transition: vk.ImageMemoryBarrier2) {
	cmd_pipeline_barrier(commandBuffer, imageBarriers = {transition})
}

cmd_pipeline_barrier :: proc(
	commandBuffer: vk.CommandBuffer,
	memoryBarriers: []vk.MemoryBarrier2 = {},
	bufferBarriers: []vk.BufferMemoryBarrier2 = {},
	imageBarriers: []vk.ImageMemoryBarrier2 = {},
) {
	for &barrier in memoryBarriers do barrier.sType = .MEMORY_BARRIER_2
	for &barrier in bufferBarriers do barrier.sType = .BUFFER_MEMORY_BARRIER_2
	for &barrier in imageBarriers do barrier.sType = .IMAGE_MEMORY_BARRIER_2
	dependencyInfo: vk.DependencyInfo = {
		sType                    = .DEPENDENCY_INFO,
		memoryBarrierCount       = u32(len(memoryBarriers)),
		pMemoryBarriers          = raw_data(memoryBarriers),
		bufferMemoryBarrierCount = u32(len(bufferBarriers)),
		pBufferMemoryBarriers    = raw_data(bufferBarriers),
		imageMemoryBarrierCount  = u32(len(imageBarriers)),
		pImageMemoryBarriers     = raw_data(imageBarriers),
	}
	vk.CmdPipelineBarrier2(commandBuffer, &dependencyInfo)
}

cmd_upload :: proc {
	cmd_upload_to_buffer,
	cmd_upload_to_image,
}

cmd_upload_to_buffer :: proc(commandBuffer: vk.CommandBuffer, data: []byte, buffer: Buffer, stagingBuffer: Buffer = {}, regions: []vk.BufferCopy2 = {}) {
	regions := regions
	if len(regions) == 0 {
		regions = {{sType = .BUFFER_COPY_2, size = min(vk.DeviceSize(len(data)), buffer.size)}}
	}

	staged := !buffer_is_mapped(buffer)
	if staged do assert(buffer_is_mapped(stagingBuffer))

	mappedBuffer := (!staged) ? buffer : stagingBuffer
	assert(.HOST_COHERENT in mappedBuffer.memory.properties)
	assume(.HOST_CACHED not_in mappedBuffer.memory.properties)

	for region in regions {
		copy(get_buffer_mapped_data(mappedBuffer)[region.dstOffset:][:region.size], data[region.srcOffset:][:region.size])
	}

	if staged {
		copyInfo: vk.CopyBufferInfo2 = {
			sType       = .COPY_BUFFER_INFO_2,
			srcBuffer   = stagingBuffer.buffer,
			dstBuffer   = buffer.buffer,
			regionCount = u32(len(regions)),
			pRegions    = raw_data(regions),
		}
		vk.CmdCopyBuffer2(commandBuffer, &copyInfo)
	}
}

cmd_upload_to_image :: proc(commandBuffer: vk.CommandBuffer, data: []byte, image: Image, stagingBuffer: Buffer) {
	assert(image.size == vk.DeviceSize(len(data)))
	assert(.HOST_VISIBLE in stagingBuffer.memory.properties && .HOST_COHERENT in stagingBuffer.memory.properties)
	assume(.HOST_CACHED not_in stagingBuffer.memory.properties)

	copy(get_buffer_mapped_data(stagingBuffer)[:len(data)], data)

	regionInfo: vk.BufferImageCopy2 = {
		sType = .BUFFER_IMAGE_COPY_2,
		imageExtent = image.extent,
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
	}
	copyInfo: vk.CopyBufferToImageInfo2 = {
		sType          = .COPY_BUFFER_TO_IMAGE_INFO_2,
		srcBuffer      = stagingBuffer.buffer,
		dstImage       = image.image,
		dstImageLayout = .TRANSFER_DST_OPTIMAL,
		regionCount    = 1,
		pRegions       = &regionInfo,
	}

	vk.CmdCopyBufferToImage2(commandBuffer, &copyInfo)
}

cmd_download :: proc {
	cmd_download_from_buffer,
	cmd_download_from_image,
}

cmd_download_from_buffer :: proc(commandBuffer: vk.CommandBuffer, buffer, readbackBuffer: Buffer, regions: []vk.BufferCopy2 = {}) {
	assert(is_mapped(readbackBuffer))
	assert(.HOST_VISIBLE in readbackBuffer.memory.properties && .HOST_COHERENT in readbackBuffer.memory.properties)
	assume(.HOST_CACHED in readbackBuffer.memory.properties)

	regions := regions
	if len(regions) == 0 {
		regions = {{sType = .BUFFER_COPY_2, size = min(buffer.size, readbackBuffer.size)}}
	}

	copyInfo: vk.CopyBufferInfo2 = {
		sType       = .COPY_BUFFER_INFO_2,
		srcBuffer   = buffer.buffer,
		dstBuffer   = readbackBuffer.buffer,
		regionCount = u32(len(regions)),
		pRegions    = raw_data(regions),
	}
	vk.CmdCopyBuffer2(commandBuffer, &copyInfo)
}

cmd_download_from_image :: proc(commandBuffer: vk.CommandBuffer, image: Image, readbackBuffer: Buffer) {
	assert(is_mapped(readbackBuffer))
	assert(.HOST_VISIBLE in readbackBuffer.memory.properties && .HOST_COHERENT in readbackBuffer.memory.properties)
	assume(.HOST_CACHED in readbackBuffer.memory.properties)

	regionInfo: vk.BufferImageCopy2 = {
		sType = .BUFFER_IMAGE_COPY_2,
		imageExtent = image.extent,
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
	}

	copyInfo: vk.CopyImageToBufferInfo2 = {
		sType          = .COPY_IMAGE_TO_BUFFER_INFO_2,
		srcImage       = image.image,
		srcImageLayout = .TRANSFER_SRC_OPTIMAL,
		dstBuffer      = readbackBuffer.buffer,
		regionCount    = 1,
		pRegions       = &regionInfo,
	}

	vk.CmdCopyImageToBuffer2(commandBuffer, &copyInfo)
}

cmd_populate_mip :: proc(commandBuffer: vk.CommandBuffer, image: Image) {
	unimplemented()
}

cmd_clear_buffer :: proc (commandBuffer: vk.CommandBuffer, buffer: Buffer) {
	cmd_fill_buffer(commandBuffer, buffer, 0)
}

cmd_fill_buffer :: proc (commandBuffer: vk.CommandBuffer, buffer: Buffer, value: u32) {
	vk.CmdFillBuffer(commandBuffer, buffer.buffer, buffer.offset, buffer.size, value)
}
