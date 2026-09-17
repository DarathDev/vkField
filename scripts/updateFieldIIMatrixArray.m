function [isActive, fieldIIScatterPosition] = updateFieldIIMatrixArray(tTh, rTh, array, biasPattern, transmitApodization, transmitDelays, receiveApodization, scatterPosition)
arguments
    tTh
    rTh
    array(1,1) tobe.RowColumnArray
    biasPattern(1, :) single
    transmitApodization(1, :) single
    transmitDelays(1, :) single
    receiveApodization(1, :) single
    scatterPosition(:, :) double
end

rowCount = double(array.ElementCount(1));
columnCount = double(array.ElementCount(2));
rowElements = 1:rowCount;
columnElements = rowCount + (1:columnCount);

biasApodization = biasPattern(rowElements).' - biasPattern(columnElements);
transmitApodizationGrid = transmitApodization(rowElements).' ...
    + transmitApodization(columnElements);
physicalApodization = biasApodization .* transmitApodizationGrid;
physicalDelays = transmitDelays(rowElements).' .* single(transmitApodization(rowElements) ~= 0) ...
    + transmitDelays(columnElements) .* single(transmitApodization(columnElements) ~= 0);
isActive = any(transmitApodization ~= 0);

fieldIIScatterPosition = scatterPosition;
fieldII.xdc_apodization(tTh, 0, double(reshape(physicalApodization.', 1, [])));
fieldII.xdc_times_focus(tTh, 0, double(reshape(physicalDelays.', 1, [])));

receiveApodizationGrid = receiveApodization(rowElements).' ...
    + receiveApodization(columnElements);
fieldII.xdc_apodization(rTh, 0, double(reshape(receiveApodizationGrid.', 1, [])));
end
