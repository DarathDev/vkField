classdef Element < matlab.mixin.Heterogeneous
    properties (Abstract, Constant)
        ApertureType(1,1) vkField.ApertureType
    end

    properties
        Apodization(1,1) single = 1;
        Delay(1,1) single = 0;
        Active(1,1) logical = true;
    end

    methods (Static,Sealed,Access=protected)
        function default_object = getDefaultScalarElement
            default_object = vkField.RectangularElement;
        end
    end
end
