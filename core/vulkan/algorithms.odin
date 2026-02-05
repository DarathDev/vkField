package vkField_vulkan

import "base:intrinsics"
import "core:log"
import "core:math/bits"
import "core:slice"
import "core:strings"
import "core:vma"
import vk "vendor:vulkan"

DEVICE_FEATURE_EXTENSIONS: [DeviceCapability][]cstring : #partial{
	.Swapchain = {vk.KHR_SWAPCHAIN_EXTENSION_NAME},
	.SwapchainMaintenance = {vk.EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME},
	.FifoLatestReady = {vk.EXT_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME},
	.ShaderObject = {vk.EXT_SHADER_OBJECT_EXTENSION_NAME},
}

GetRequiredInstancePresentationExtensions :: proc() -> (extensions: []string) {
	when ODIN_OS == .Windows {
		extensions = {vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_WIN32_SURFACE_EXTENSION_NAME}
	} else when ODIN_OS == .Darwin {
		extensions = {vk.KHR_SURFACE_EXTENSION_NAME, vk.EXT_METAL_SURFACE_EXTENSION_NAME}
	} else when ODIN_OS == .Linux {
		extensions = {
			vk.KHR_SURFACE_EXTENSION_NAME,
			vk.KHR_XCB_SURFACE_EXTENSION_NAME,
			vk.KHR_XLIB_SURFACE_EXTENSION_NAME,
			vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME,
		}
	}
	return slice.clone(extensions)
}

DeduceDeviceCapabilities :: proc(features2: vk.PhysicalDeviceFeatures2, extensions: []vk.ExtensionProperties) -> (capabilities: DeviceCapabilities) {
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
			if !vulkan12Features.timelineSemaphore { capabilities -= {.TimelineSemaphore} }
			if !vulkan12Features.bufferDeviceAddress { capabilities -= {.BufferDeviceAddress} }
			if !vulkan12Features.descriptorBindingVariableDescriptorCount { capabilities -= {.VariableDescriptorCount} }
		case .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES:
			vulkan13Features := ((cast(^vk.PhysicalDeviceVulkan13Features)pNext)^)
			if !vulkan13Features.synchronization2 { capabilities -= {.Synchronization2} }
			if !vulkan13Features.dynamicRendering { capabilities -= {.DynamicRendering} }
			if !vulkan13Features.maintenance4 { capabilities -= {.Maintenance4} }
		case .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT:
			swapchainMaintenance1 := ((cast(^vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT)pNext)^)
			if !swapchainMaintenance1.swapchainMaintenance1 { capabilities -= {.SwapchainMaintenance} }
		case .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT:
			shaderObject := ((cast(^vk.PhysicalDeviceShaderObjectFeaturesEXT)pNext)^)
			if !shaderObject.shaderObject { capabilities -= {.ShaderObject} }
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

MakeDeviceFeatures :: proc(capabilities: DeviceCapabilities, allocator := context.allocator) -> (features2: vk.PhysicalDeviceFeatures2) {
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

	vk11Features := new(vk.PhysicalDeviceVulkan11Features, allocator)
	vk11Features^ = {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		multiview            = .MultiView in capabilities,
		shaderDrawParameters = .ShaderDrawParameters in capabilities,
	}
	features2.pNext = vk11Features

	vk12Features := new(vk.PhysicalDeviceVulkan12Features, allocator)
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
		descriptorBindingVariableDescriptorCount           = .VariableDescriptorCount in capabilities,
		timelineSemaphore                                  = .TimelineSemaphore in capabilities,
		bufferDeviceAddress                                = .BufferDeviceAddress in capabilities,
	}
	vk11Features.pNext = vk12Features

	vk13Features := new(vk.PhysicalDeviceVulkan13Features, allocator)
	vk13Features^ = {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		synchronization2 = .Synchronization2 in capabilities,
		dynamicRendering = .DynamicRendering in capabilities,
		maintenance4     = .Maintenance4 in capabilities,
	}
	vk12Features.pNext = vk13Features

	pNext: ^vk.BaseInStructure = auto_cast vk13Features

	if .SwapchainMaintenance in capabilities {
		swapchainMaintenance := new(vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT, allocator)
		swapchainMaintenance^ = {
			sType                 = .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT,
			swapchainMaintenance1 = .SwapchainMaintenance in capabilities,
		}
		pNext.pNext = auto_cast swapchainMaintenance
		pNext = auto_cast swapchainMaintenance
	}

	if .ShaderObject in capabilities {
		shaderObject := new(vk.PhysicalDeviceShaderObjectFeaturesEXT, allocator)
		shaderObject^ = {
			sType        = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
			shaderObject = .ShaderObject in capabilities,
		}
		pNext.pNext = auto_cast shaderObject
		pNext = auto_cast shaderObject
	}
	return
}

AddCapabilityExtensions :: proc(extensions: ^[dynamic]cstring, capabilities: DeviceCapabilities) {
	featureExtensions := DEVICE_FEATURE_EXTENSIONS
	for feature in capabilities {
		for extension in featureExtensions[feature] {
			append(extensions, extension)
		}
	}
}

@(require_results)
PickPhysicalDevice :: proc(instance: vk.Instance, devices: #soa[]PhysicalDevice, criteria: DeviceCriteria) -> (chosenDevice: PhysicalDevice, ok: bool) {
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
			score -= optionalCapabilitiesWeight * int(intrinsics.count_ones(transmute(i32)(unavailableOptionalCapabilities)))
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
		return vk.GetPhysicalDeviceWin32PresentationSupportKHR(physicalDevice, u32(familyIndex))
	}
}

QuerySwapchainSupport :: proc(
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

GetComputeQueue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> u32 {
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

GetTransferQueue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> u32 {
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

GetHeadlessQueue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> u32 {
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

GetPresentQueue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> (queueIndex: Maybe(u32), result: vk.Result) {
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

GetMultiQueue :: proc(device: vk.PhysicalDevice, families: []vk.QueueFamilyProperties) -> (queueIndex: Maybe(u32), result: vk.Result) {
	for family, index in families {
		if .GRAPHICS in family.queueFlags && .COMPUTE in family.queueFlags && CheckPresentSupport(device, index) {
			queueIndex = u32(index)
			return
		}
	}
	return
}

ChooseSwapSurfaceFormat :: proc(formats: []vk.SurfaceFormatKHR, criteria: SwapCriteria) -> (surfaceFormat: vk.SurfaceFormatKHR, ok: bool) {
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

ChooseSwapPresentMode :: proc(presentModes: []vk.PresentModeKHR, criteria: SwapCriteria) -> vk.PresentModeKHR {
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

ChooseSwapExtent :: proc(capabilities: vk.SurfaceCapabilitiesKHR, criteria: SwapCriteria) -> vk.Extent2D {
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

NeedsStaging :: proc {
	PropertiesImplyNeedsStaging,
	ResourceNeedsStaging,
}

ResourceNeedsStaging :: proc(gpuResource: GpuResource) -> bool {
	return NeedsStaging(gpuResource.resourceProperties) && .HOST_VISIBLE not_in gpuResource.memoryProps
}

PropertiesImplyNeedsStaging :: proc(resourceProperties: ResourceProperties) -> bool {
	return .HostAccessible not_in resourceProperties && (.Uploadable in resourceProperties || .Downloadable in resourceProperties)
}

MakeAllocationInfo :: proc(resourceProperties: ResourceProperties) -> (createInfo: vma.AllocationCreateInfo) {
	usage: vma.MemoryUsage =
		(.DevicePreferred in resourceProperties && .HostPreferred not_in resourceProperties) ? .AUTO_PREFER_DEVICE : (.HostPreferred in resourceProperties && .DevicePreferred not_in resourceProperties) ? .AUTO_PREFER_HOST : .AUTO
	createInfo.usage = usage
	createInfo.priority = .HighPriority in resourceProperties ? 5 : 1
	createInfo.flags |= .Dedicated in resourceProperties ? {.DEDICATED_MEMORY} : {}
	createInfo.flags |= .Aliased in resourceProperties ? {.CAN_ALIAS} : {}
	createInfo.flags |= NeedsStaging(resourceProperties) ? {.HOST_ACCESS_ALLOW_TRANSFER_INSTEAD} : {}
	createInfo.flags |= .Uploadable in resourceProperties ? {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED} : {}
	createInfo.flags |= .Downloadable in resourceProperties ? {.HOST_ACCESS_RANDOM, .MAPPED} : {}
	return
}

CreateStagingBuffer :: proc {
	CreateBufferStagingBuffer,
	CreateImageStagingBuffer,
}

CreateBufferStagingBuffer :: proc(gpuAllocator: vma.Allocator, buffer: Buffer) -> (stagingBuffer: Buffer, result: vk.Result) {
	resourceProperties: ResourceProperties = {.HostAccessible}
	bufferInfo: vk.BufferCreateInfo = {
		sType       = .BUFFER_CREATE_INFO,
		sharingMode = .EXCLUSIVE,
		size        = buffer.size,
	}
	if .Uploadable in buffer.resourceProperties {
		resourceProperties |= {.Uploadable}
		bufferInfo.usage |= {.TRANSFER_SRC}
	}
	if .Downloadable in buffer.resourceProperties {
		resourceProperties |= {.Downloadable}
		bufferInfo.usage |= {.TRANSFER_DST}
	}

	return CreateBuffer(gpuAllocator, &bufferInfo, resourceProperties)
}

CreateImageStagingBuffer :: proc(gpuAllocator: vma.Allocator, image: Image) -> (stagingBuffer: Buffer, result: vk.Result) {
	resourceProperties: ResourceProperties = {.HostAccessible}
	bufferInfo: vk.BufferCreateInfo = {
		sType       = .BUFFER_CREATE_INFO,
		sharingMode = .EXCLUSIVE,
		size        = getImageSize(image),
	}
	if .Uploadable in image.resourceProperties {
		resourceProperties |= {.Uploadable}
		bufferInfo.usage |= {.TRANSFER_SRC}
	}
	if .Downloadable in image.resourceProperties {
		resourceProperties |= {.Downloadable}
		bufferInfo.usage |= {.TRANSFER_DST}
	}

	return CreateBuffer(gpuAllocator, &bufferInfo, resourceProperties)
}

CmdTransition :: proc(commandBuffer: vk.CommandBuffer, transition: vk.ImageMemoryBarrier2) {
	transition := transition
	transition.sType = .IMAGE_MEMORY_BARRIER_2
	transitionInfo: vk.DependencyInfo = {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &transition,
	}
	vk.CmdPipelineBarrier2(commandBuffer, &transitionInfo)
}

CmdUploadToBuffer :: proc(commandBuffer: vk.CommandBuffer, buffer: Buffer, data: []byte, regions: []vk.BufferCopy2, stagingBuffer: Buffer = {}) {
	log.assert(.Uploadable in buffer.resourceProperties)
	log.assert(!NeedsStaging(buffer) || stagingBuffer != {})

	if (!NeedsStaging(buffer)) {
		for region in regions {
			copy(([^]byte)(buffer.data)[region.dstOffset:][:region.size], data[region.srcOffset:][:region.size])
		}
	} else {
		for region in regions {
			copy(([^]byte)(stagingBuffer.data)[region.dstOffset:][:region.size], data[region.srcOffset:][:region.size])
		}
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

CmdUploadToImage :: proc(commandBuffer: vk.CommandBuffer, image: Image, stagingBuffer: Buffer, data: []byte) {
	log.assert(.Uploadable in image.resourceProperties)
	log.assert(getImageSize(image) == vk.DeviceSize(len(data)))

	copy(([^]byte)(stagingBuffer.data)[:len(data)], data)

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

CmdPopulateMip :: proc(commandBuffer: vk.CommandBuffer, image: Image) {
	unimplemented()
}
