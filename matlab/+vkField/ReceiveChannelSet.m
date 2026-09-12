classdef ReceiveChannelSet
    properties
        Count(1,1) uint32 = 0;
        ElementCounts(1, :) uint32
        Indices(1, :) int32
        Apodizations(1, :) single
        Delays(1, :) single
        Impulse(1, :) uint16
    end
end
