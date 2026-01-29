classdef RectangularElementSet
    properties
        Count(1,1) uint32 = 0;
        Positions(3, :) single
        Normals(3, :) single
        Sizes(2, :) single
        PhysicalApodizations(1, :) single
        PhysicalDelays(1, :) single
    end
end
