%% Compare one tilted transmit/receive rectangle against Field II
scriptDirectory = fileparts(mfilename('fullpath'));
repositoryDirectory = fileparts(scriptDirectory);
addpath(repositoryDirectory);
addpath(scriptDirectory);
addpath(fullfile(repositoryDirectory, 'matlab'));
addpath(fullfile(repositoryDirectory, 'scripts', 'color'));

fs = 100e6;
c = 1540;
fc = 5e6;
cycleCount = 2;
dt = 1 / fs;
% impulseResponse = GetImpulseResponse(single(fc), single(fs));
% excitation = sin(2 * pi * (0:dt:cycleCount / fc) * fc);
impulseResponse = 1;
excitation = 1;
% impulseResponse = 1;
% excitation = 1;
rectangleSize = [2.2e-4; 2.2e-4];
caseCount = 64;
plotting = true;
plotCorrelationThreshold = 0.99;
originApertures = true;
geometryTolerance = 1e-9;
angleTolerance = 1e-6;

scatterRangeMin = [-25e-3; -25e-3; 10e-3];
scatterRangeMax = [25e-3; 25e-3; 100e-3];

% Fixed seed makes every reported case reproducible.
rng(1, 'twister');

fieldII.field_init(-1);
fieldII.set_field('c', c);
fieldII.set_field('fs', fs);

results = repmat(struct( ...
    'caseIndex', 0, ...
    'scatterPosition', zeros(3, 1), ...
    'transmitPosition', zeros(3, 1), ...
    'receivePosition', zeros(3, 1), ...
    'transmitEuler', zeros(3, 1), ...
    'receiveEuler', zeros(3, 1), ...
    'fieldCpuRmsErrorPercent', 0, ...
    'compareTimes', [], ...
    'fieldAligned', [], ...
    'cpuAligned', [], ...
    'gpuAligned', []), 1, caseCount);

for caseIndex = 1:caseCount
    scatterPosition = random_position(scatterRangeMin, scatterRangeMax);
    if originApertures
        transmitPosition = [0; 0; 0];
        receivePosition = [0; 0; 0];
        transmitEuler = [0; 0; 0];
        receiveEuler = [0; 0; 0];
    else
        transmitPosition = random_position([-5e-3; -5e-3; -2e-3], [5e-3; 5e-3; 2e-3]);
        receivePosition = random_position([-5e-3; -5e-3; -2e-3], [5e-3; 5e-3; 2e-3]);
        transmitEuler = [rand_range(-pi, pi); rand_range(-pi / 9, pi / 9); rand_range(-pi / 9, pi / 9)];
        receiveEuler = [rand_range(-pi, pi); rand_range(-pi / 9, pi / 9); rand_range(-pi / 9, pi / 9)];
    end
    transmitFrame = make_frame(transmitEuler);
    receiveFrame = make_frame(receiveEuler);

    fprintf(['case=%d scatter=[%.3f %.3f %.3f] mm tx=[%.4g %.4g %.4g] ', ...
        'rx=[%.4g %.4g %.4g] txEuler=[%.4g %.4g %.4g] ', ...
        'rxEuler=[%.4g %.4g %.4g]\n'], caseIndex, scatterPosition * 1e3, ...
        transmitPosition, receivePosition, transmitEuler, receiveEuler);

    if originApertures
        transmitAperture = fieldII.xdc_2d_array(1, 1, rectangleSize(1), rectangleSize(2), 3e-5, 3e-5, 1, 1, 1, [0, 0, 1e10]);
        receiveAperture = fieldII.xdc_2d_array(1, 1, rectangleSize(1), rectangleSize(2), 3e-5, 3e-5, 1, 1, 1, [0, 0, 1e10]);
    else
        transmitAperture = make_field_ii_rectangle(transmitPosition, transmitFrame, rectangleSize);
        receiveAperture = make_field_ii_rectangle(receivePosition, receiveFrame, rectangleSize);
    end
    transmitRectData = fieldII.xdc_get(transmitAperture, 'rect');
    receiveRectData = fieldII.xdc_get(receiveAperture, 'rect');
    if originApertures
        validate_fieldii_axis(transmitRectData, transmitPosition, transmitFrame, angleTolerance);
        validate_fieldii_axis(receiveRectData, receivePosition, receiveFrame, angleTolerance);
    else
        validate_fieldii_rectangle(transmitRectData, transmitPosition, transmitFrame, rectangleSize, geometryTolerance, angleTolerance);
        validate_fieldii_rectangle(receiveRectData, receivePosition, receiveFrame, rectangleSize, geometryTolerance, angleTolerance);
    end
    fieldII.xdc_impulse(transmitAperture, 1);
    fieldII.xdc_impulse(receiveAperture, 1);
    fieldII.xdc_excitation(transmitAperture, 1);
    fieldII.xdc_apodization(transmitAperture, 0, 1);
    fieldII.xdc_apodization(receiveAperture, 0, 1);
    [fieldData, fieldStartTime] = fieldII.calc_scat_multi(transmitAperture, receiveAperture, scatterPosition', 1);
    fieldData = applyResponseFilters(double(fieldData) / dt^4, impulseResponse, excitation, dt);
    fieldTimes = fieldStartTime + (0:size(fieldData, 1) - 1) / fs;

    elementPositions = single([transmitPosition, receivePosition]);
    elementNormals = single([transmitFrame(:, 3), receiveFrame(:, 3)]);
    elementSizes = single(repmat(rectangleSize, 1, 2));
    elementApodizations = single([1, 1]);
    elementDelays = single([0, 0]);

    [cpuData, cpuStartTime] = run_vkfield(vkField.SimulatorType.CPU, elementPositions, elementNormals, elementSizes, ...
        elementApodizations, elementDelays, scatterPosition, fs, c, impulseResponse, excitation);
    [gpuData, gpuStartTime] = run_vkfield(vkField.SimulatorType.GPU, elementPositions, elementNormals, elementSizes, ...
        elementApodizations, elementDelays, scatterPosition, fs, c, impulseResponse, excitation);

    [fieldAligned, cpuAligned, gpuAligned, compareTimes] = align_signals(...
        cpuData, cpuStartTime, gpuData, gpuStartTime, fieldData, fieldStartTime, fs);
    difference = cpuAligned - gpuAligned;
    cpuGpuMetrics = signal_metrics(cpuAligned, gpuAligned);
    fieldCpuDifference = cpuAligned - fieldAligned;
    fieldGpuDifference = gpuAligned - fieldAligned;
    fieldCpuMetrics = signal_metrics(cpuAligned, fieldAligned);
    fieldGpuMetrics = signal_metrics(gpuAligned, fieldAligned);

    results(caseIndex).caseIndex = caseIndex;
    results(caseIndex).scatterPosition = scatterPosition;
    results(caseIndex).transmitPosition = transmitPosition;
    results(caseIndex).receivePosition = receivePosition;
    results(caseIndex).transmitEuler = transmitEuler;
    results(caseIndex).receiveEuler = receiveEuler;
    results(caseIndex).cpuGpuMaxRelativeDifference = cpuGpuMetrics.maxRelativeDifference;
    results(caseIndex).fieldCpuRmsErrorPercent = fieldCpuMetrics.rmsErrorPercent;
    results(caseIndex).compareTimes = compareTimes;
    results(caseIndex).fieldAligned = fieldAligned;
    results(caseIndex).cpuAligned = cpuAligned;
    results(caseIndex).gpuAligned = gpuAligned;
    fprintf(['  FieldII/CPU energyRatio=%.4g peakRatio=%.4g corr=%.6f maxRelDiff=%.2f%% rmsErr=%.2f%%\n'], ...
        fieldCpuMetrics.differenceEnergyRatio, fieldCpuMetrics.peakRatio, fieldCpuMetrics.correlation, ...
        fieldCpuMetrics.maxRelativeDifference, fieldCpuMetrics.rmsErrorPercent);
    fprintf(['  FieldII/GPU energyRatio=%.4g peakRatio=%.4g corr=%.6f maxRelDiff=%.2f%% rmsErr=%.2f%%\n'], ...
        fieldGpuMetrics.differenceEnergyRatio, fieldGpuMetrics.peakRatio, fieldGpuMetrics.correlation, ...
        fieldGpuMetrics.maxRelativeDifference, fieldGpuMetrics.rmsErrorPercent);
    fprintf(['  CPU/GPU energyRatio=%.4g peakRatio=%.4g corr=%.6f maxRelDiff=%.2f%% rmsErr=%.2f%%\n'], ...
        cpuGpuMetrics.differenceEnergyRatio, cpuGpuMetrics.peakRatio, cpuGpuMetrics.correlation, ...
        cpuGpuMetrics.maxRelativeDifference, cpuGpuMetrics.rmsErrorPercent);

    if plotting && fieldCpuMetrics.correlation < plotCorrelationThreshold
        plot_case(compareTimes, fieldAligned, cpuAligned, gpuAligned, caseIndex, scatterPosition, ...
            transmitPosition, receivePosition, transmitEuler, receiveEuler);
    end

end

fprintf('Completed %d reproducible one-rectangle cases.\n', caseCount);
plot_scatter_errors(results, rectangleSize);
plot_rms_error_histogram(results);
[~, bestCaseIndex] = min([results.fieldCpuRmsErrorPercent]);
[~, worstCaseIndex] = max([results.fieldCpuRmsErrorPercent]);
plot_case(results(bestCaseIndex).compareTimes, results(bestCaseIndex).fieldAligned, ...
    results(bestCaseIndex).cpuAligned, results(bestCaseIndex).gpuAligned, ...
    results(bestCaseIndex).caseIndex, results(bestCaseIndex).scatterPosition, ...
    results(bestCaseIndex).transmitPosition, results(bestCaseIndex).receivePosition, ...
    results(bestCaseIndex).transmitEuler, results(bestCaseIndex).receiveEuler);
plot_case(results(worstCaseIndex).compareTimes, results(worstCaseIndex).fieldAligned, ...
    results(worstCaseIndex).cpuAligned, results(worstCaseIndex).gpuAligned, ...
    results(worstCaseIndex).caseIndex, results(worstCaseIndex).scatterPosition, ...
    results(worstCaseIndex).transmitPosition, results(worstCaseIndex).receivePosition, ...
    results(worstCaseIndex).transmitEuler, results(worstCaseIndex).receiveEuler);

function plot_scatter_errors(results, rectangleSize)
scatterPositions = [results.scatterPosition] * 1e3;
rmsErrors = [results.fieldCpuRmsErrorPercent];
rectangleSize = rectangleSize * 1e3;

figure('Name', 'Scatterer RMS errors');
hold on;
scatterHandle = scatter3(scatterPositions(1, :), scatterPositions(2, :), scatterPositions(3, :), ...
    64, rmsErrors, 'filled');
scatterHandle.MarkerFaceAlpha = 0.65;
scatterHandle.MarkerEdgeColor = 'flat';
scatterHandle.MarkerEdgeAlpha = 0.9;
scatterHandle.LineWidth = 0.75;
patch('Vertices', [-rectangleSize(1) / 2, -rectangleSize(2) / 2, 0; ...
    -rectangleSize(1) / 2,  rectangleSize(2) / 2, 0; ...
    rectangleSize(1) / 2,  rectangleSize(2) / 2, 0; ...
    rectangleSize(1) / 2, -rectangleSize(2) / 2, 0], ...
    'Faces', [1, 2, 3, 4], ...
    'FaceColor', [0.35, 0.35, 0.35], ...
    'FaceAlpha', 0.2, ...
    'EdgeColor', [0.15, 0.15, 0.15], ...
    'LineWidth', 1.5);
axis equal;
view(3);
grid on;
xlabel('Scatterer x (mm)');
ylabel('Scatterer y (mm)');
zlabel('Scatterer z (mm)');
title('Field II/CPU RMS error by scatterer position');
colormap(colorcet('L08', 'N', 256));
colorbarHandle = colorbar;
ylabel(colorbarHandle, 'RMS error (%)');
end

function plot_rms_error_histogram(results)
rmsErrors = [results.fieldCpuRmsErrorPercent];
histogramColorMap = colorcet('L16', 'N', 256);

figure('Name', 'RMS error histogram');
histogram(rmsErrors, 'FaceColor', histogramColorMap(round(size(histogramColorMap, 1) * 0.65), :));
grid on;
xlabel('Field II/CPU RMS error (%)');
ylabel('Case count');
title('Distribution of Field II/CPU RMS errors');
end

function [data, startTime] = run_vkfield(simulatorType, positions, normals, sizes, apodizations, delays, scatterPosition, fs, c, impulseResponse, excitation)
simulation = vkField.Simulation();
simulation.SimulatorType = simulatorType;
simulation.Cumulative = true;
simulation.GpuSettings.EnableDriverDebugMessages = false;
simulation.SamplingFrequency = single(fs);
simulation.SpeedOfSound = single(c);
simulation.Impulses = {single(impulseResponse)};
simulation.Excitations = {single(excitation)};
simulation.Elements = vkField.RectangularElementSet();
simulation.Elements.Count = uint32(2);
simulation.Elements.Positions = positions;
simulation.Elements.Normals = normals;
simulation.Elements.Sizes = sizes;
simulation.Elements.Apodizations = apodizations;
simulation.Elements.Delays = delays;
transmission = vkField.TransmissionSet();
transmission.Count = uint32(1);
transmission.ElementCounts = uint32(1);
transmission.Indices = int32(1);
transmission.Apodizations = single(1);
transmission.Delays = single(0);
transmission.Impulse = ones(1, transmission.Count, 'uint16');
transmission.Excitation = ones(1, transmission.Count, 'uint16');
simulation.Transmissions = transmission;
receiveChannel = vkField.ReceiveChannelSet();
receiveChannel.Count = uint32(1);
receiveChannel.ElementCounts = uint32(1);
receiveChannel.Indices = int32(2);
receiveChannel.Apodizations = single(1);
receiveChannel.Delays = single(0);
receiveChannel.Impulse = ones(1, receiveChannel.Count, 'uint16');
simulation.ReceiveChannels = receiveChannel;
simulation.Scatters = vkField.ScatterSet();
simulation.Scatters.Count = uint32(1);
simulation.Scatters.Positions = single(scatterPosition);
simulation.Scatters.Amplitudes = single(1);
data = squeeze(double(vkField_mex(simulation)));
simulatorLabel = 'CPU';
if simulatorType == vkField.SimulatorType.GPU
    simulatorLabel = 'GPU';
end
fprintf('raw %s peak=%e\n', simulatorLabel, max(abs(data), [], 'all'));
startTime = double(simulation.StartTime);
end

function rectangle = make_field_ii_rectangle(position, frame, size)
halfWidth = size(1) / 2;
halfHeight = size(2) / 2;
u = frame(:, 1) * halfWidth;
v = frame(:, 2) * halfHeight;
corners = [position - u - v, position - u + v, position + u + v, position + u - v];
rectangle = [1, reshape(corners', 1, []), 1, size(1), size(2), position'];
rectangle = fieldII.xdc_rectangles(rectangle, position', [0, 0, 1e10]);
end

function frame = make_frame(euler)
% Intrinsic roll, pitch, yaw frame; columns are local width, height, normal.
roll = euler(1);
pitch = euler(2);
yaw = euler(3);
rx = [1, 0, 0; 0, cos(roll), -sin(roll); 0, sin(roll), cos(roll)];
ry = [cos(pitch), 0, sin(pitch); 0, 1, 0; -sin(pitch), 0, cos(pitch)];
rz = [cos(yaw), -sin(yaw), 0; sin(yaw), cos(yaw), 0; 0, 0, 1];
frame = rz * ry * rx;
end

function position = random_position(lower, upper)
position = lower + rand(3, 1) .* (upper - lower);
end

function value = rand_range(lower, upper)
value = lower + rand() * (upper - lower);
end

function filtered = applyResponseFilters(data, impulseResponse, excitation, dt)
data = double(data);
wasVector = isvector(data);
if wasVector
    data = data(:);
end
filtered = zeros(size(data, 1) + numel(impulseResponse) * 2 + numel(excitation) - 3, size(data, 2));
for channelIndex = 1:size(data, 2)
    response = conv(data(:, channelIndex), double(impulseResponse)) * dt;
    response = conv(response, double(impulseResponse)) * dt;
    response = conv(response, double(excitation)) * dt;
    filtered(:, channelIndex) = response;
end
if wasVector
    filtered = filtered(:, 1);
end
end

function validate_fieldii_rectangle(rectData, expectedPosition, expectedFrame, expectedSize, tolerance, angleTolerance)
actualPosition = rectData(8:10, 1);
actualCorners = reshape(rectData(11:22, 1), 4, 3)';
actualSize = [norm(actualCorners(:, 2) - actualCorners(:, 1)); norm(actualCorners(:, 3) - actualCorners(:, 2))];
halfWidth = expectedSize(1) / 2;
halfHeight = expectedSize(2) / 2;
u = expectedFrame(:, 1) * halfWidth;
v = expectedFrame(:, 2) * halfHeight;
expectedCorners = [expectedPosition - u - v, expectedPosition - u + v, ...
    expectedPosition + u + v, expectedPosition + u - v];
actualNormal = cross(actualCorners(:, 2) - actualCorners(:, 1), actualCorners(:, 3) - actualCorners(:, 2));
actualNormal = actualNormal / norm(actualNormal);
expectedNormal = expectedFrame(:, 3);
assert(norm(actualPosition - expectedPosition) <= tolerance, ...
    'Field II rectangle center differs beyond tolerance.');
assert(norm(actualSize - expectedSize) <= tolerance, ...
    'Field II rectangle size differs beyond tolerance.');
assert(max(vecnorm(actualCorners - expectedCorners, 2, 1)) <= tolerance, ...
    'Field II rectangle corners differ beyond tolerance.');
assert(abs(dot(actualNormal, expectedNormal)) >= cos(angleTolerance), ...
    'Field II rectangle normal axis differs beyond angular tolerance.');
end

function validate_fieldii_axis(rectData, expectedPosition, expectedFrame, angleTolerance)
actualPosition = rectData(8:10, 1);
assert(norm(actualPosition - expectedPosition) <= 1e-9, ...
    'Field II array rectangle center differs beyond tolerance.');
end

function [fieldAligned, cpuAligned, gpuAligned, times] = align_signals(cpuData, cpuStartTime, gpuData, gpuStartTime, fieldData, fieldStartTime, fs)
commonStart = max([cpuStartTime, gpuStartTime, fieldStartTime]);
commonEnd = min([cpuStartTime + (size(cpuData, 1) - 1) / fs, ...
    gpuStartTime + (size(gpuData, 1) - 1) / fs, fieldStartTime + (size(fieldData, 1) - 1) / fs]);
times = (commonStart:1 / fs:commonEnd)';
fieldAligned = interp1(fieldStartTime + (0:size(fieldData, 1) - 1) / fs, fieldData, times, 'linear', 0);
cpuAligned = interp1(cpuStartTime + (0:size(cpuData, 1) - 1) / fs, cpuData, times, 'linear', 0);
gpuAligned = interp1(gpuStartTime + (0:size(gpuData, 1) - 1) / fs, gpuData, times, 'linear', 0);
end

function plot_case(times, fieldData, cpuData, gpuData, caseIndex, scatterPosition, transmitPosition, receivePosition, transmitEuler, receiveEuler)
times = times(:);
fieldData = fieldData(:);
cpuData = cpuData(:);
gpuData = gpuData(:);
sampleCount = min([numel(times), numel(fieldData), numel(cpuData), numel(gpuData)]);
times = times(1:sampleCount);
fieldData = fieldData(1:sampleCount);
cpuData = cpuData(1:sampleCount);
gpuData = gpuData(1:sampleCount);
fprintf('plot case=%d peak FieldII=%e CPU=%e GPU=%e\n', caseIndex, ...
    max(abs(fieldData)), max(abs(cpuData)), max(abs(gpuData)));
figure('Name', sprintf('One rectangle case %d', caseIndex));
colororder(colorcet('L16', 'N', 4));
plotHandles = plot(times * 1e6, fieldData, '-', times * 1e6, cpuData, '--', times * 1e6, gpuData, ':');
plotHandles(1).LineWidth = 4*3.0;
plotHandles(2).LineWidth = 4*2.0;
plotHandles(3).LineWidth = 4*1.0;
legend('Field II', 'vkField CPU', 'vkField GPU');
title(sprintf('case %d scatter=[%.3f %.3f %.3f] mm tx=[%g %g %g] rx=[%g %g %g]', ...
    caseIndex, scatterPosition * 1e3, transmitPosition, receivePosition));
xlabel('Time (us)');
end

function freeApertures(transmitAperture, receiveAperture)
fieldII.xdc_free(transmitAperture);
fieldII.xdc_free(receiveAperture);
end
