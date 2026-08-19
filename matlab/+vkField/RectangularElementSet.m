classdef RectangularElementSet
    properties
        Count(1,1) uint32 = 0;
        Positions(3, :) single
        Normals(3, :) single
        Sizes(2, :) single
        Apodizations(1, :) single
        Delays(1, :) single
    end
end
