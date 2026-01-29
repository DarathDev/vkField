classdef Simulation < handle

    properties
        SamplingFrequency(1,1) single = 100e6;
        SpeedOfSound(1,1) single = 1540;
        StartTime(1,1) single = NaN;
        SampleCount(1,1) uint32 = 0;
        Headless(1,1) logical = true;
    end

    properties (Dependent)
        EndTime(1,1) single
    end

    properties
        TransmitElements(1,1) vkField.RectangularElementSet
        ReceiveElements(1,1) vkField.RectangularElementSet
        Scatters(1,1) vkField.ScatterSet
    end

    methods
        function call(simulation)
            arguments
                simulation(1,1) vkField.Simulation
            end
            mex("matlab\vkField_lib.c", "matlab\vkField_lib.lib", "-g", "-R2018a", "-output", "matlab\vkField_mex");
            vkField_mex(simulation);
        end
    end

    methods
        function endTime = get.EndTime(simulation)
            endTime = simulation.StartTime + simulation.SampleCount / simulation.SamplingFrequency;
        end
    end
end
