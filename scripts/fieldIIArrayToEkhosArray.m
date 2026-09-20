function elements = fieldIIArrayToEkhosArray(aperture, apodizations, delays)
arguments
    aperture
    apodizations = []
    delays = []
end

rectData = fieldII.xdc_get(aperture, 'rect');
elementCount = size(rectData, 2);
if isempty(apodizations)
    apodizations = ones(1, elementCount, 'single');
else
    apodizations = single(reshape(apodizations, 1, []));
    assert(numel(apodizations) == elementCount, ...
        'apodizations must contain one value per Field II rectangle.');
end
if isempty(delays)
    delays = zeros(1, elementCount, 'single');
else
    delays = single(reshape(delays, 1, []));
    assert(numel(delays) == elementCount, ...
        'delays must contain one value per Field II rectangle.');
end

positions = single(rectData(8:10, :));
sizes = single(rectData(3:4, :));
normals = zeros(3, elementCount, 'single');
for elementIndex = 1:elementCount
    corners = reshape(rectData(11:22, elementIndex), 4, 3)';
    firstEdge = corners(:, 2) - corners(:, 1);
    secondEdge = corners(:, 3) - corners(:, 2);
    normal = cross(firstEdge, secondEdge);
    normals(:, elementIndex) = single(normal / norm(normal));
end

elements = ekhos.RectangularElementSet();
elements.Count = uint32(elementCount);
elements.Positions = positions;
elements.Normals = normals;
elements.Sizes = sizes;
elements.Apodizations = apodizations;
elements.Delays = delays;
end
