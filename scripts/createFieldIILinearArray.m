function aperture = createFieldIILinearArray(array, orientation)
arguments
    array(1, 1) tobe.RowColumnArray
    orientation(1, 1) ZBP.RCAOrientation
end

orientationIndex = int32(orientation);
otherOrientation = ZBP.RCAOrientation(3 - orientationIndex);
lineCount = double(array.ElementCount(orientationIndex));
lineLength = double(array.ElementCount(int32(otherOrientation)));
lineWidth = double(array.GetWidth(orientation));
lineHeight = double(array.GetSize(otherOrientation));
lineKerf = double(array.Kerf(orientationIndex));

aperture = fieldII.xdc_linear_array(lineCount, lineWidth, lineHeight, ...
    lineKerf, 1, lineLength, [0, 0, 1e10]);
end
