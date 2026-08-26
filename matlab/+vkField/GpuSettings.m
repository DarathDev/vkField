classdef GpuSettings
    properties
        Backend(1,1) vkField.GpuBackend = vkField.GpuBackend.Vulkan;
        DispatchWorkLimit(1,1) uint32 {mustBePositive} = bitshift(1, 24);
        EnableDriverDebugMessages(1,1) logical = false;
    end
end
