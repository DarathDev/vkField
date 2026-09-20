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

assert(receiveOrientation == ZBP.RCAOrientation.Columns, "Overlapping linear arrays require column-oriented receive channels");

rowCount = double(array.ElementCount(1));
columnCount = double(array.ElementCount(2));
rowElements = 1:rowCount;
columnElements = rowCount + (1:columnCount);

biasApodization = biasPattern(rowElements).' - biasPattern(columnElements);
transmitApodizationGrid = transmitApodization(rowElements).' ...
    + transmitApodization(columnElements);

fieldIIScatterPosition = scatterPosition;

transmitSubelementApodization = (biasApodization .* transmitApodizationGrid).';
isActive = any(transmitSubelementApodization ~= 0, 'all');

transmitDelaysGrid = transmitDelays(rowElements).' .* single(transmitApodization(rowElements) ~= 0).' ...
    + transmitDelays(columnElements) .* single(transmitApodization(columnElements) ~= 0);
transmitDelaysGrid = transmitDelaysGrid.';

receiveLineApodization = receiveApodization(columnElements);
receiveSubelementApodization = biasApodization.' .* repmat(receiveLineApodization, rowCount, 1).';

transmitLineCount = columnCount;
transmitLines = 1:transmitLineCount;

receiveLineCount = columnCount;
receiveLines = 1:receiveLineCount;

fieldII.xdc_apodization(tTh, 0, ones(1, transmitLineCount));
fieldII.ele_apodization(tTh, transmitLines.', double(transmitSubelementApodization));
fieldII.ele_delay(tTh, transmitLines.', double(transmitDelaysGrid));

fieldII.xdc_apodization(rTh, 0, ones(1, receiveLineCount));
fieldII.ele_apodization(rTh, receiveLines.', double(receiveSubelementApodization));
end
