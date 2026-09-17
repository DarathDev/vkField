function [isActive, fieldIIScatterPosition] = updateFieldIILinearArray(tTh, rTh, array, biasPattern, transmitApodization, transmitDelays, receiveApodization, receiveOrientation, scatterPosition)
arguments
    tTh
    rTh
    array(1,1) tobe.RowColumnArray
    biasPattern(1, :) single
    transmitApodization(1, :) single
    transmitDelays(1, :) single
    receiveApodization(1, :) single
    receiveOrientation(1,1) ZBP.RCAOrientation
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
if receiveOrientation == ZBP.RCAOrientation.Columns
    physicalApodization = fliplr(physicalApodization).';
    physicalDelays = fliplr(physicalDelays).';
    fieldIIScatterPosition = [scatterPosition(2, :); -scatterPosition(1, :); scatterPosition(3, :)];
end

fieldII.xdc_apodization(tTh, 0, double(reshape(physicalApodization.', 1, [])));
fieldII.xdc_times_focus(tTh, 0, double(reshape(physicalDelays.', 1, [])));

receiveElements = array.GetElements(receiveOrientation);
fieldII.xdc_apodization(rTh, 0, double(receiveApodization(receiveElements)));
end
