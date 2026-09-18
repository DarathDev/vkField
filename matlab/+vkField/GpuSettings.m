classdef GpuSettings
    properties
        Backend(1,1) vkField.GpuBackend = vkField.GpuBackend.Vulkan;
        EnableDriverDebugMessages(1,1) logical = false;
    end
end
