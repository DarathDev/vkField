scriptDirectory = fileparts(mfilename("fullpath"));
repoDirectory = fileparts(scriptDirectory);
addpath(repoDirectory);
addpath(scriptDirectory);
addpath(fullfile(repoDirectory, "matlab"));
addpath(fullfile(repoDirectory, "extern", "ornot", "matlab"));
ornot.LoadLibraries();

plotting = true;
plotVolume = true;
plotGeometry = false;

fs = single(100e6);
c = single(1540);
fc = single(5e6);
cycleCount = 2;

rowCount = 32;
columnCount = 32;
elementWidth = single([2.2e-4, 2.2e-4]);
elementKerf = single([3e-5, 3e-5]);

[scatterX, scatterZ] = meshgrid(0, linspace(20e-3, 100e-3, 20));
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
bp.transducer_element_pitch = array.Pitch([2, 1]);
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

tTh = createFieldIILinearArray(array, receiveOrientation);
receiveLineCount = double(array.ElementCount(int32(receiveOrientation)));
rTh = createFieldIILinearArray(array, receiveOrientation);
fieldII.xdc_impulse(tTh, double(impulseResponse));
fieldII.xdc_impulse(rTh, double(impulseResponse));
fieldII.xdc_excitation(tTh, double(excitation));
fieldIIRf = cell(transmitCount, 1);
fieldIIStartTime = zeros(transmitCount, 1);
fieldIIEndTime = zeros(transmitCount, 1);
fieldIITimer = tic();
for eventIndex = 1:transmitCount
    [isActive, fieldIIScatterPosition] = updateFieldIILinearArray(tTh, rTh, array, biasPattern(eventIndex, :), ...
        transmitApodization(eventIndex, :), transmitDelays(eventIndex, :), ...
        receiveApodization(eventIndex, :), receiveOrientation, scatterPosition);
    if isActive
        [fieldIIRf{eventIndex}, fieldIIStartTime(eventIndex)] = ...
            fieldII.calc_scat_multi(tTh, rTh, fieldIIScatterPosition', double(scatterAmplitude));
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

%% Ekhos Simulation
simulator = ekhos.Simulation();
simulator.Cumulative = false;
simulator.SimulatorType = ekhos.SimulatorType.CPU;
simulator.SamplingFrequency = fs;
simulator.SpeedOfSound = c;
simulator.Impulses = {single(impulseResponse)};
simulator.Excitations = {single(excitation)};
fieldIITransmitElements = fieldIIArrayToEkhosArray(tTh);
fieldIIReceiveElements = fieldIIArrayToEkhosArray(rTh);
[sequenceElements, sequenceTransmissions, sequenceReceiveChannels] = ...
    sequenceToElementSets(array, biasPattern, transmitApodization, transmitDelays, receiveApodization);
simulator.Elements = sequenceElements;
if plotting && plotGeometry
    plot_element_geometry(fieldIITransmitElements, fieldIIReceiveElements, ...
        sequenceElements.Positions, sequenceElements.Sizes, ...
        sequenceElements.Positions, sequenceElements.Sizes, ...
        'HERCULES physical elements');
end
simulator.Scatters = ekhos.ScatterSet();
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
    simulator.ReceiveChannels = receive;
    vkPulseEcho{eventIndex} = ekhosMex(simulator);
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

fprintf("Field II samples == %d, Ekhos samples == %d\n", size(fieldIIRf, 1), size(vkPulseEcho, 1));
fprintf("Field II start time == %.9g, Ekhos start time == %.9g\n", ...
    min(fieldIIStartTime), simulator.StartTime);
fprintf("Field II simulation time == %.6f s\n", fieldIITime);
fprintf("Ekhos simulation time == %.6f s\n", vkTime);
fprintf("Simulation speed-up == %.3fx\n", fieldIITime / vkTime);

fieldIIData = stackEventData(fieldIIRf);
vkData = stackEventData(vkPulseEcho);
responseSampleCount = min(size(fieldIIData, 1), size(vkData, 1));
responseChannelCount = min(size(fieldIIData, 2), size(vkData, 2));
responseMetrics = signal_metrics( ...
    vkData(1:responseSampleCount, 1:responseChannelCount), ...
    fieldIIData(1:responseSampleCount, 1:responseChannelCount));
fprintf("Field II/Ekhos response correlation == %.6f (RMS error == %.2f%%, peak ratio == %.6f)\n", ...
    responseMetrics.correlation, responseMetrics.rmsErrorPercent, responseMetrics.peakRatio);

fieldIIBp = bp;
fieldIIBp.transducer_element_pitch = [
    array.Pitch(2), ...
    array.GetSize(ZBP.RCAOrientation.Rows) / single(array.ElementCount(1))
    ];
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
yRange = [-8, 8] * 1e-3;
zRange = [15, 105] * 1e-3;
volumeResolution = uint16([128, 128, 512]);
beamformSettings.regions = ornot.Region.CreateAxisAlignedVolume(volumeResolution, ...
    single(xRange), single(yRange), single(zRange));
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
fprintf("Ekhos beamform time == %.6f s\n", vkBeamformTime);

if plotting
    if plotVolume
        volumeViewer(abs(vkImage{1}));
    end

    planeResolution = uint16([128, 512]);
    xzSettings = ornot.BeamformSettings();
    xzSettings.regions = ornot.Region.CreateXZPlane(planeResolution, ...
        single(xRange), single(zRange));
    xzSettings.interpolation_mode = beamformSettings.interpolation_mode;
    xzSettings.receive_fnumber = beamformSettings.receive_fnumber;
    xzSettings.coherency_weighting = beamformSettings.coherency_weighting;
    xzSettings.decimation_rate = beamformSettings.decimation_rate;
    xzSettings.compute_stages = beamformSettings.compute_stages;

    yzSettings = ornot.BeamformSettings();
    yzSettings.regions = ornot.Region.CreateYZPlane(planeResolution, ...
        single(yRange), single(zRange));
    yzSettings.interpolation_mode = beamformSettings.interpolation_mode;
    yzSettings.receive_fnumber = beamformSettings.receive_fnumber;
    yzSettings.coherency_weighting = beamformSettings.coherency_weighting;
    yzSettings.decimation_rate = beamformSettings.decimation_rate;
    yzSettings.compute_stages = beamformSettings.compute_stages;

    fieldIIImageXZ = ornot.beamform(fieldIIBp, xzSettings);
    vkImageXZ = ornot.beamform(vkBp, xzSettings);
    fieldIIImageYZ = ornot.beamform(fieldIIBp, yzSettings);
    vkImageYZ = ornot.beamform(vkBp, yzSettings);

    imageX = linspace(xRange(1), xRange(2), size(fieldIIImageXZ{1}, 1));
    imageY = linspace(yRange(1), yRange(2), size(fieldIIImageYZ{1}, 1));
    imageZ = linspace(zRange(1), zRange(2), size(fieldIIImageXZ{1}, 2));
    fieldIIImageXZDb = 20 * log10(abs(fieldIIImageXZ{1}) / max(abs(fieldIIImageXZ{1}), [], 'all'));
    vkImageXZDb = 20 * log10(abs(vkImageXZ{1}) / max(abs(vkImageXZ{1}), [], 'all'));
    fieldIIImageYZDb = 20 * log10(abs(fieldIIImageYZ{1}) / max(abs(fieldIIImageYZ{1}), [], 'all'));
    vkImageYZDb = 20 * log10(abs(vkImageYZ{1}) / max(abs(vkImageYZ{1}), [], 'all'));
    xzMetrics = signal_metrics(vkImageXZ{1}, fieldIIImageXZ{1});
    yzMetrics = signal_metrics(vkImageYZ{1}, fieldIIImageYZ{1});
    fprintf("HERCULES XZ image correlation == %.6f; YZ image correlation == %.6f\n", ...
        xzMetrics.correlation, yzMetrics.correlation);

    figure();
    colormap(gray);
    tiledlayout(1, 4, 'TileSpacing', 'none', 'Padding', 'none');
    nexttile();
    imagesc(imageX * 1e3, imageZ * 1e3, fieldIIImageXZDb');
    axis image;
    clim([-40, 0]);
    title("Field II HERCULES XZ");
    xlabel("x (mm), dB");
    ylabel("z (mm)");
    colorbar;
    nexttile();
    imagesc(imageX * 1e3, imageZ * 1e3, vkImageXZDb');
    axis image;
    clim([-40, 0]);
    title("Ekhos HERCULES XZ");
    xlabel("x (mm), dB");
    ylabel("z (mm)");
    colorbar;
    nexttile();
    imagesc(imageY * 1e3, imageZ * 1e3, fieldIIImageYZDb');
    axis image;
    clim([-40, 0]);
    title("Field II HERCULES YZ");
    xlabel("y (mm), dB");
    ylabel("z (mm)");
    colorbar;
    nexttile();
    imagesc(imageY * 1e3, imageZ * 1e3, vkImageYZDb');
    axis image;
    clim([-40, 0]);
    title("Ekhos HERCULES YZ");
    xlabel("y (mm), dB");
    ylabel("z (mm)");
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



