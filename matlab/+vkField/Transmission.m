classdef Transmission
    properties
        Count(1,1) uint32 = 0;
        Indices(1, :) int32
        Apodizations(1, :) single
        Delays(1, :) single
    end
end
