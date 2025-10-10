classdef Scatter
    %UNTITLED Summary of this class goes here
    %   Detailed explanation goes here

    properties (Constant)
        SizeOf = 16;
    end

    properties
        Position(1,3) single = [0, 0, 0];
        Amplitude(1,1) single = 1;
    end

    methods
        function bytes = ToBytes(elements)
            bytes = zeros(1, numel(elements)*vkField.Scatter.SizeOf, 'uint8');
            for i = 1:numel(elements)
                bytes((i-1) + (1:vkField.Scatter.SizeOf)) = [ ...
                typecast(elements.Position, 'uint8'),...
                typecast(elements.Amplitude, 'uint8'),...
                ];
            end
        end
    end
end