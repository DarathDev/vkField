classdef GpuSettings
    properties
        Backend(1,1) ekhos.GpuBackend = ekhos.GpuBackend.Vulkan;
        EnableDriverDebugMessages(1,1) logical = false;
    end
end
