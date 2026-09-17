scriptDirectory = fileparts(mfilename("fullpath"));
repoDirectory = fileparts(scriptDirectory);
addpath(repoDirectory);
addpath(fullfile(repoDirectory, "matlab"));
addpath(fullfile(repoDirectory, "extern", "ornot", "matlab"));
ornot.LoadLibraries();

plotting = true;
useMatrixArray = false;

fs = single(100e6);
c = single(1540);
fc = single(5e6);
cycleCount = 2;

rowCount = 32;
columnCount = 32;
elementWidth = single([2.2e-4, 2.2e-4]);
elementKerf = single([3e-5, 3e-5]);

[scatterX, scatterZ] = meshgrid(linspace(-8e-3, 8e-3, 8), linspace(20e-3, 100e-3, 20));
scatterCount = numel(scatterX);
scatterPosition = [
    scatterX(:).';
    zeros(1, scatterCount);
    scatterZ(:).'
    ];
scatterAmplitude = ones(scatterCount, 1, 'single');

array = tobe.RowColumnArray();
array.ElementCount = uint16([rowCount, columnCount]);
array.Pitch = elementWidth + elementKerf;
array.Kerf = elementKerf;
array.CenterFrequency = fc;

transmitOrientation = ZBP.RCAOrientation.Rows;
receiveOrientation = ZBP.RCAOrientation.Columns;
transmitFocus = ZBP.RCATransmitFocus();
transmitFocus.focal_depth = -inf;
transmitFocus.origin_offset = single(0);
transmitFocus.transmit_receive_orientation = ...
    ornot.packTransmitReceiveOrientation(transmitOrientation, receiveOrientation);
herculesParameters = ZBP.HERCULESParameters();
herculesParameters.transmit_focus = transmitFocus;

[biasPattern, transmitApodization, transmitDelays, receiveApodization, bp] ...
    = tobe.createHerculesSequence(array, herculesParameters, c);
emissionParameters = ZBP.EmissionSineParameters();
emissionParameters.cycles = cycleCount;
emissionParameters.frequency = fc;
bp.emission_descriptors = uint8(1);
bp.emission_parameters = {emissionParameters};
transmitCount = size(biasPattern, 1);

impulseResponse = GetImpulseResponse(fc, fs);
excitation = sin(2*pi*(0:1/double(fs):cycleCount/double(fc))*double(fc));

%% Field II Simulation
fieldII.field_init(-1);
fieldII.set_field('c', double(c));
fieldII.set_field('fs', double(fs));

tTh = fieldII.xdc_2d_array(columnCount, rowCount, double(elementWidth(2)), ...
    double(elementWidth(1)), double(elementKerf(2)), double(elementKerf(1)), ...
    ones(columnCount, rowCount)', 1, 1, [0, 0, 1e10]);

receiveLineCount = double(array.ElementCount(int32(receiveOrientation)));
if useMatrixArray
    rTh = fieldII.xdc_2d_array(columnCount, rowCount, double(elementWidth(2)), ...
        double(elementWidth(1)), double(elementKerf(2)), double(elementKerf(1)), ...
        ones(columnCount, rowCount)', 1, 1, [0, 0, 1e10]);
else
    receiveLineLength = double(array.ElementCount(int32(transmitOrientation)));
    if receiveOrientation == ZBP.RCAOrientation.Columns
        receiveElementWidth = double(elementWidth(2));
        receiveElementHeight = double(receiveLineLength * elementWidth(1) ...
            + (receiveLineLength - 1) * elementKerf(1));
        receiveKerf = double(elementKerf(2));
    else
        receiveElementWidth = double(elementWidth(1));
        receiveElementHeight = double(receiveLineLength * elementWidth(2) ...
            + (receiveLineLength - 1) * elementKerf(2));
        receiveKerf = double(elementKerf(1));
    end
    rTh = fieldII.xdc_linear_array(receiveLineCount, receiveElementWidth, ...
        receiveElementHeight, receiveKerf, 1, receiveLineLength, [0, 0, 1e10]);
end
fieldII.xdc_impulse(tTh, double(impulseResponse));
fieldII.xdc_impulse(rTh, double(impulseResponse));
fieldII.xdc_excitation(tTh, double(excitation));
fieldIIRf = cell(transmitCount, 1);
fieldIIStartTime = zeros(transmitCount, 1);
fieldIIEndTime = zeros(transmitCount, 1);
fieldIITimer = tic();
for eventIndex = 1:transmitCount
    if useMatrixArray
        [isActive, fieldIIScatterPosition] = updateFieldIIMatrixArray(tTh, rTh, array, biasPattern(eventIndex, :), ...
            transmitApodization(eventIndex, :), transmitDelays(eventIndex, :), ...
            receiveApodization(eventIndex, :), scatterPosition);
    else
        [isActive, fieldIIScatterPosition] = updateFieldIILinearArray(tTh, rTh, array, biasPattern(eventIndex, :), ...
            transmitApodization(eventIndex, :), transmitDelays(eventIndex, :), ...
            receiveApodization(eventIndex, :), receiveOrientation, scatterPosition);
    end
    if isActive
        [fieldIIRf{eventIndex}, fieldIIStartTime(eventIndex)] = ...
            fieldII.calc_scat_multi(tTh, rTh, fieldIIScatterPosition', double(scatterAmplitude));
        if useMatrixArray
            fieldIIRf{eventIndex} = sum(reshape(fieldIIRf{eventIndex}, ...
                size(fieldIIRf{eventIndex}, 1), rowCount, columnCount), 2);
            fieldIIRf{eventIndex} = reshape(fieldIIRf{eventIndex}, ...
                size(fieldIIRf{eventIndex}, 1), columnCount);
        end
        fieldIIEndTime(eventIndex) = fieldIIStartTime(eventIndex) ...
            + size(fieldIIRf{eventIndex}, 1) / double(fs);
    end
end
templateEvent = find(~cellfun(@isempty, fieldIIRf), 1);
assert(~isempty(templateEvent), "HERCULES sequence contains no active transmit events");
for eventIndex = 1:transmitCount
    if isempty(fieldIIRf{eventIndex})
        fieldIIRf{eventIndex} = zeros(size(fieldIIRf{templateEvent}), 'like', fieldIIRf{templateEvent});
        fieldIIStartTime(eventIndex) = fieldIIStartTime(templateEvent);
        fieldIIEndTime(eventIndex) = fieldIIEndTime(templateEvent);
    end
end
[fieldIIRf, fieldIIStartTime, fieldIIEndTime] = ...
    padEventData(fieldIIRf, fieldIIStartTime, fieldIIEndTime, fs);
fieldIIRf = cat(3, fieldIIRf{:});
fieldIITime = toc(fieldIITimer);

%% vkField Simulation
simulator = vkField.Simulation();
simulator.Cumulative = true;
simulator.SimulatorType = vkField.SimulatorType.CPU;
simulator.SamplingFrequency = fs;
simulator.SpeedOfSound = c;
simulator.Impulses = {single(impulseResponse)};
simulator.Excitations = {single(excitation)};
tData = fieldII.xdc_get(tTh, 'rect');
[sequenceElements, sequenceTransmissions, sequenceReceiveChannels] = ...
    sequenceToElementSets(array, biasPattern, transmitApodization, transmitDelays, receiveApodization);
simulator.Elements = vkField.RectangularElementSet();
transmitElementCount = size(tData, 2);
simulator.Elements.Count = uint32(transmitElementCount + sequenceElements.Count);
simulator.Elements.Positions = single([tData(8:10, :), sequenceElements.Positions]);
simulator.Elements.Normals = single([tangentsToNormals(tData(8:10, :)), sequenceElements.Normals]);
simulator.Elements.Sizes = single([tData(3:4, :), sequenceElements.Sizes]);
simulator.Elements.Apodizations = single([tData(5, :), sequenceElements.Apodizations]);
simulator.Elements.Delays = single([tData(23, :), sequenceElements.Delays]);
simulator.Scatters = vkField.ScatterSet();
simulator.Scatters.Count = uint32(scatterCount);
simulator.Scatters.Positions = single(scatterPosition);
simulator.Scatters.Amplitudes = scatterAmplitude;

vkTimer = tic();
vkPulseEcho = cell(transmitCount, 1);
vkStartTime = zeros(transmitCount, 1);
vkEndTime = zeros(transmitCount, 1);
for eventIndex = 1:transmitCount
    simulator.Transmissions = sequenceTransmissions(eventIndex);
    receive = sequenceReceiveChannels(eventIndex);
    receive.Indices = receive.Indices + int32(transmitElementCount);
    simulator.ReceiveChannels = receive;
    vkPulseEcho{eventIndex} = vkField_mex(simulator);
    vkStartTime(eventIndex) = simulator.StartTime;
    vkEndTime(eventIndex) = vkStartTime(eventIndex) ...
        + size(vkPulseEcho{eventIndex}, 1) / double(fs);
end
if all(cellfun(@isempty, vkPulseEcho))
    error("HERCULES sequence contains no active transmit events");
end
[vkPulseEcho, vkStartTime, vkEndTime] = padEventData(vkPulseEcho, vkStartTime, vkEndTime, fs);
vkPulseEcho = cat(3, vkPulseEcho{:});
vkTime = toc(vkTimer);

fprintf("Field II samples == %d, vkField samples == %d\n", size(fieldIIRf, 1), size(vkPulseEcho, 1));
fprintf("Field II start time == %.9g, vkField start time == %.9g\n", ...
    min(fieldIIStartTime), simulator.StartTime);
fprintf("Field II simulation time == %.6f s\n", fieldIITime);
fprintf("vkField simulation time == %.6f s\n", vkTime);
fprintf("Simulation speed-up == %.3fx\n", fieldIITime / vkTime);

fieldIIData = stackEventData(fieldIIRf);
vkData = stackEventData(vkPulseEcho);

fieldIIBp = bp;
fieldIIBp.raw_data_dimension = uint32([size(fieldIIData, 1), receiveLineCount, 1, 1]);
fieldIIBp.raw_data_kind = ZBP.DataKind.Float32;
fieldIIBp.raw_data_compression_kind = ZBP.DataCompressionKind.None;
fieldIIBp.decode_mode = ZBP.DecodeMode.Hadamard;
fieldIIBp.sampling_mode = ZBP.SamplingMode.Standard;
fieldIIBp.sampling_frequency = fs;
fieldIIBp.demodulation_frequency = fc;
fieldIIBp.sample_count = uint32(size(fieldIIRf, 1));
fieldIIBp.channel_count = uint32(receiveLineCount);
fieldIIBp.receive_event_count = uint32(transmitCount);
fieldIIBp.time_offset = single(bp.time_offset - min(fieldIIStartTime));
fieldIIBp.data = single(fieldIIData * 1e30);

vkBp = bp;
vkBp.raw_data_dimension = uint32([size(vkData, 1), receiveLineCount, 1, 1]);
vkBp.raw_data_kind = ZBP.DataKind.Float32;
vkBp.raw_data_compression_kind = ZBP.DataCompressionKind.None;
vkBp.decode_mode = ZBP.DecodeMode.Hadamard;
vkBp.sampling_mode = ZBP.SamplingMode.Standard;
vkBp.sampling_frequency = fs;
vkBp.demodulation_frequency = fc;
vkBp.sample_count = uint32(size(vkPulseEcho, 1));
vkBp.channel_count = uint32(receiveLineCount);
vkBp.receive_event_count = uint32(transmitCount);
vkBp.time_offset = single(bp.time_offset - simulator.StartTime);
vkBp.data = single(vkData * (1 / double(fs)) * 1e30);

beamformSettings = ornot.BeamformSettings();
xRange = [-8, 8] * 1e-3;
zRange = [15, 105] * 1e-3;
resolution = [512, 1024];
beamformSettings.regions = ornot.Region.CreateXZPlane(resolution, xRange, zRange);
beamformSettings.interpolation_mode = OGLBeamformerInterpolationMode.Cubic;
beamformSettings.receive_fnumber = 0;
beamformSettings.coherency_weighting = false;
beamformSettings.decimation_rate = 1;
beamformSettings.compute_stages = [
    OGLBeamformerShaderStage.Demodulate, ...
    OGLBeamformerShaderStage.Decode, ...
    OGLBeamformerShaderStage.DAS
    ];

fieldIIBeamformTimer = tic();
fieldIIImage = ornot.beamform(fieldIIBp, beamformSettings);
fieldIIBeamformTime = toc(fieldIIBeamformTimer);
vkBeamformTimer = tic();
vkImage = ornot.beamform(vkBp, beamformSettings);
vkBeamformTime = toc(vkBeamformTimer);

fprintf("Field II beamform time == %.6f s\n", fieldIIBeamformTime);
fprintf("vkField beamform time == %.6f s\n", vkBeamformTime);

if plotting
    imageX = linspace(xRange(1), xRange(2), size(fieldIIImage{1}, 1));
    imageZ = linspace(zRange(1), zRange(2), size(fieldIIImage{1}, 2));
    figure();
    colormap(gray);
    tiledlayout(1, 2, 'TileSpacing', 'none', 'Padding', 'none');
    nexttile();
    imagesc(imageX * 1e3, imageZ * 1e3, abs(fieldIIImage{1})');
    axis image;
    title("Field II HERCULES");
    xlabel("x (mm)");
    ylabel("z (mm)");
    colorbar('westoutside');
    nexttile();
    imagesc(imageX * 1e3, imageZ * 1e3, abs(vkImage{1})');
    axis image;
    title("vkField HERCULES");
    xlabel("x (mm)");
    set(gca, 'YColor', 'none');
    colorbar;
end

function data = stackEventData(eventData)
arguments
    eventData(:, :, :)
end
sampleCount = size(eventData, 1);
receiveChannelCount = size(eventData, 2);
eventCount = size(eventData, 3);
data = reshape(permute(eventData, [1, 3, 2]), ...
    sampleCount * eventCount, receiveChannelCount);
end

function [data, startTimes, endTimes] = padEventData(data, startTimes, endTimes, samplingFrequency)
minStartTime = min(startTimes);
for eventIndex = 1:numel(data)
    prePadSize = floor((startTimes(eventIndex) - minStartTime) * double(samplingFrequency) + 0.01);
    data{eventIndex} = padarray(data{eventIndex}, double(prePadSize), 0, 'pre');
end
maxEndTime = max(endTimes);
for eventIndex = 1:numel(data)
    endTime = minStartTime + size(data{eventIndex}, 1) / double(samplingFrequency);
    postPadSize = ceil((maxEndTime - endTime) * double(samplingFrequency) + 0.01);
    data{eventIndex} = padarray(data{eventIndex}, double(postPadSize), 0, 'post');
end
end

function normals = tangentsToNormals(tangents)
normals = [tangents(2, :)./sqrt(1 + tangents(2, :).^2);
    tangents(1, :)./sqrt(1 + tangents(1, :).^2);
    sqrt(1 - (tangents(1, :).^2).*(tangents(2, :).^2))./sqrt(1 + tangents(1, :).^2)./sqrt(1 + tangents(2, :).^2)];
end

