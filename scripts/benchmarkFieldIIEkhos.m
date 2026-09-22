%% Benchmark Field II against Ekhos CPU and GPU.
% The benchmark varies physical element count, scatter count, receive-channel
% grouping, and the number of transmissions. Results are written to a table
% and saved as a MAT file in the figures directory.

scriptDirectory = fileparts(mfilename("fullpath"));
repositoryDirectory = fileparts(scriptDirectory);
addpath(repositoryDirectory);
addpath(fullfile(repositoryDirectory, "matlab"));
addpath(fullfile(scriptDirectory, "color"));

%% Benchmark settings
fs = single(100e6);
c = single(1540);
fc = single(5e6);
cycleCount = 2;

% Compare linear and matrix arrays with the same row and column counts.
linearSideLengths = [128];
matrixSideLengths = [32];
matrixReceiveGroupSizes = 1;
scatterCounts = 2.^(7:18);
transmissionCounts = [1];
repetitions = 1;
minimumCorrelation = 0.98;

runCPU = true;
runGPU = true;
writeResults = true;
quickMode = logical(str2double("0"));
rng(0, "twister");
hardware = getHardwareInfo();

if quickMode
    linearSideLengths = [32, 64];
    matrixSideLengths = [8, 16];
    matrixReceiveGroupSizes = 1;
    scatterCounts = [128, 1024];
    transmissionCounts = 1;
end

impulseResponse = GetImpulseResponse(fc, fs);
excitation = sin(2 * pi * (0:1 / double(fs):cycleCount / double(fc)) * double(fc));

results = table();
fieldII.field_init(-1);
fieldII.set_field('c', double(c));
fieldII.set_field('fs', double(fs));

for arrayKind = ["linear", "matrix"]
    if strcmp(arrayKind, "linear")
        arraySizes = linearSideLengths;
    else
        arraySizes = matrixSideLengths;
    end

    for arraySize = arraySizes
        rowCount = arraySize;
        columnCount = arraySize;
        elementCount = rowCount * columnCount;
        if arrayKind == "linear"
            receiveGroupSizes = rowCount;
        else
            receiveGroupSizes = matrixReceiveGroupSizes;
        end

        allScatterPositions = makeScatterPositions(max(scatterCounts));
        allScatterAmplitudes = ones(max(scatterCounts), 1, "single");

        for scatterCount = scatterCounts
            scatterPositions = allScatterPositions(:, 1:scatterCount);
            scatterAmplitudes = allScatterAmplitudes(1:scatterCount);
            for receiveGroupSize = receiveGroupSizes
                if mod(elementCount, receiveGroupSize) ~= 0
                    continue;
                end
                receiveChannelCount = elementCount / receiveGroupSize;
                for transmissionCount = transmissionCounts
                    fprintf("%s elements=%d group=%d scatters=%d transmissions=%d\n", ...
                        arrayKind, elementCount, receiveGroupSize, scatterCount, transmissionCount);

                    for repetitionIndex = 1:repetitions
                        [fieldIIData, fieldIITime, fieldIIChannelCount, fieldIIStartTimes, transmitGeometry, receiveGeometry] = runFieldII(...
                            arrayKind, rowCount, columnCount, scatterPositions, scatterAmplitudes, ...
                            transmissionCount, impulseResponse, excitation);
                        if arrayKind == "linear"
                            fieldIIGrouped = fieldIIData;
                        else
                            fieldIIGrouped = groupSignals(fieldIIData, receiveGroupSize);
                        end
                        assert(size(fieldIIGrouped, 2) == receiveChannelCount, ...
                            "Field II grouping produced an unexpected channel count.");

                        simulatorTypes = [ekhos.SimulatorType.CPU, ekhos.SimulatorType.GPU];
                        simulatorTypes = simulatorTypes([runCPU, runGPU]);
                        for simulatorType = simulatorTypes
                            simulation = makeVkSimulation(...
                                transmitGeometry, receiveGeometry, scatterPositions, scatterAmplitudes, ...
                                receiveGroupSize, transmissionCount, simulatorType, fs, c, impulseResponse, excitation);
                            timer = tic();
                            vkData = simulation.call();
                            wallTime = toc(timer);
                            vkData = double(vkData);
                            if ismatrix(vkData)
                                vkData = reshape(vkData, size(vkData, 1), size(vkData, 2), 1);
                            end
                            vkData = vkData * (1 / double(fs));
                            fieldIIDataScaled = fieldIIGrouped * (1 / double(fs));
                            outputCorrelation = compareSimulationOutputs(...
                                fieldIIDataScaled, fieldIIStartTimes, vkData, ...
                                simulation.StartTime, fs);
                            assert(outputCorrelation >= minimumCorrelation, ...
                                "Field II and %s outputs have correlation %.4f, below the %.2f threshold.", ...
                                string(simulatorType), outputCorrelation, minimumCorrelation);

                            row = table(string(arrayKind), string(simulatorType), elementCount, ...
                                receiveGroupSize, receiveChannelCount, scatterCount, transmissionCount, ...
                                fieldIIChannelCount, fieldIITime, wallTime, simulation.Metrics.SimulationTime, ...
                                outputCorrelation, ...
                                size(fieldIIGrouped, 1), size(vkData, 1), repetitionIndex, ...
                                "VariableNames", {"arrayKind", "simulator", "elementCount", ...
                                "receiveGroupSize", "receiveChannelCount", "scatterCount", ...
                                "transmissionCount", "fieldIIChannelCount", "fieldIISeconds", ...
                                "wallSeconds", "simulationSeconds", "outputCorrelation", "fieldIISampleCount", ...
                                "vkSampleCount", "repetition"});
                            results = [results; row]; %#ok<AGROW>

                            fprintf("  repetition=%d %s FieldII=%.4fs wall=%.4fs simulation=%.4fs speedup=%.2fx\n", ...
                                repetitionIndex, string(simulatorType), fieldIITime, wallTime, ...
                                double(simulation.Metrics.SimulationTime), fieldIITime / wallTime);
                        end
                    end
                end
            end
        end
    end
end

if writeResults
    outputDirectory = fullfile(repositoryDirectory, "figures");
    if ~isfolder(outputDirectory)
        mkdir(outputDirectory);
    end
    timestamp = string(datetime("now", "Format", "yyyyMMdd-HHmmss"));
    writetable(results, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + ".csv"));
    save(fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + ".mat"), "results", "hardware");
    saveBenchmarkFigures(results, hardware, outputDirectory, timestamp);
end

%% Local functions
function positions = makeScatterPositions(scatterCount)
positions = [
    rand(1, scatterCount, "single") * 16e-3 - 8e-3;
    rand(1, scatterCount, "single") * 4e-3 - 2e-3;
    rand(1, scatterCount, "single") * 80e-3 + 20e-3;
    ];
end

function [data, elapsed, channelCount, startTimes, transmitGeometry, receiveGeometry] = runFieldII(...
    arrayKind, rowCount, columnCount, scatterPositions, scatterAmplitudes, ...
    transmissionCount, impulseResponse, excitation)
if strcmp(arrayKind, "linear")
    tAperture = fieldII.xdc_linear_array(columnCount, 2.2e-4, 2.2e-4 * rowCount, 3e-5, 1, rowCount, [0, 0, 1e10]);
    rAperture = fieldII.xdc_linear_array(columnCount, 2.2e-4, 2.2e-4 * rowCount, 3e-5, 1, rowCount, [0, 0, 1e10]);
else
    tAperture = fieldII.xdc_2d_array(columnCount, rowCount, 2.2e-4, 2.2e-4, ...
        3e-5, 3e-5, ones(rowCount, columnCount)', 1, 1, [0, 0, 1e10]);
    rAperture = fieldII.xdc_2d_array(columnCount, rowCount, 2.2e-4, 2.2e-4, ...
        3e-5, 3e-5, ones(rowCount, columnCount)', 1, 1, [0, 0, 1e10]);
end
cleanup = onCleanup(@() freeApertures(tAperture, rAperture));
fieldII.xdc_impulse(tAperture, double(impulseResponse));
fieldII.xdc_impulse(rAperture, double(impulseResponse));
fieldII.xdc_excitation(tAperture, double(excitation));
if strcmp(arrayKind, "linear")
    fieldII.xdc_apodization(tAperture, 0, ones(1, columnCount));
    fieldII.xdc_apodization(rAperture, 0, ones(1, columnCount));
else
    fieldII.xdc_apodization(tAperture, 0, reshape(ones(columnCount, rowCount)', 1, []));
    fieldII.xdc_apodization(rAperture, 0, reshape(ones(columnCount, rowCount)', 1, []));
end
    transmitGeometry = fieldII.xdc_get(tAperture, 'rect');
    receiveGeometry = fieldII.xdc_get(rAperture, 'rect');

fieldIIData = cell(transmissionCount, 1);
startTimes = zeros(transmissionCount, 1);
timer = tic();
for transmissionIndex = 1:transmissionCount
    [fieldIIData{transmissionIndex}, startTimes(transmissionIndex)] = ...
    fieldII.calc_scat_multi(tAperture, rAperture, double(scatterPositions'), double(scatterAmplitudes));
end
elapsed = toc(timer);
channelCount = size(fieldIIData{1}, 2);
maxSamples = max(cellfun(@(value) size(value, 1), fieldIIData));
data = zeros(maxSamples, channelCount, transmissionCount);
for transmissionIndex = 1:transmissionCount
    data(1:size(fieldIIData{transmissionIndex}, 1), :, transmissionIndex) = fieldIIData{transmissionIndex};
end
end

function minimumCorrelation = compareSimulationOutputs(...
    fieldIIData, fieldIIStartTimes, vkData, vkStartTime, samplingFrequency)
transmissionCount = min(size(fieldIIData, 3), size(vkData, 3));
correlations = zeros(transmissionCount, 1);
for transmissionIndex = 1:transmissionCount
    fieldIITimes = fieldIIStartTimes(transmissionIndex) + ...
        (0:size(fieldIIData, 1) - 1) / double(samplingFrequency);
    vkTimes = double(vkStartTime) + ...
        (0:size(vkData, 1) - 1) / double(samplingFrequency);
    bestCorrelation = -1;
    for sampleOffset = -4:4
        shiftedVkTimes = vkTimes + sampleOffset / double(samplingFrequency);
        commonStart = max(fieldIITimes(1), shiftedVkTimes(1));
        commonEnd = min(fieldIITimes(end), shiftedVkTimes(end));
        commonTimes = (commonStart:1 / double(samplingFrequency):commonEnd)';
        vkAligned = interp1(shiftedVkTimes, vkData(:, :, transmissionIndex), commonTimes, 'linear');
        fieldIIAligned = interp1(fieldIITimes, fieldIIData(:, :, transmissionIndex), commonTimes, 'linear');
        metrics = signal_metrics(vkAligned, fieldIIAligned);
        bestCorrelation = max(bestCorrelation, metrics.correlation);
    end
    correlations(transmissionIndex) = bestCorrelation;
end
minimumCorrelation = min(correlations);
end

function simulation = makeVkSimulation(...
    transmitGeometry, receiveGeometry, scatterPositions, scatterAmplitudes, ...
    receiveGroupSize, transmissionCount, simulatorType, fs, c, impulseResponse, excitation)
elementCount = size(transmitGeometry, 2);
simulation = ekhos.Simulation();
simulation.Cumulative = true;
simulation.SimulatorType = simulatorType;
simulation.SamplingFrequency = fs;
simulation.SpeedOfSound = c;
simulation.Impulses = {single(impulseResponse)};
simulation.Excitations = {single(excitation)};
simulation.Elements = ekhos.RectangularElementSet();
simulation.Elements.Count = uint32(2 * elementCount);
simulation.Elements.Positions = single([transmitGeometry(8:10, :), receiveGeometry(8:10, :)]);
simulation.Elements.Normals = single([tangentsToNormals(transmitGeometry(8:10, :)), ...
    tangentsToNormals(receiveGeometry(8:10, :))]);
simulation.Elements.Sizes = single([transmitGeometry(3:4, :), receiveGeometry(3:4, :)]);
simulation.Elements.Apodizations = single([transmitGeometry(5, :), receiveGeometry(5, :)]);
simulation.Elements.Delays = single([transmitGeometry(23, :), receiveGeometry(23, :)]);

transmissions = ekhos.TransmissionSet();
transmissions.Count = uint32(transmissionCount);
transmissions.ElementCounts = repmat(uint32(elementCount), 1, transmissionCount);
transmissions.Indices = repmat(int32(1:elementCount), 1, transmissionCount);
transmissions.Apodizations = repmat(single(transmitGeometry(5, :)), 1, transmissionCount);
transmissions.Delays = repmat(single(transmitGeometry(23, :)), 1, transmissionCount);
transmissions.Impulse = ones(1, transmissionCount, "uint16");
transmissions.Excitation = ones(1, transmissionCount, "uint16");
simulation.Transmissions = transmissions;

receiveChannelCount = elementCount / receiveGroupSize;
receiveChannels = ekhos.ReceiveChannelSet();
receiveChannels.Count = uint32(receiveChannelCount);
receiveChannels.ElementCounts = repmat(uint32(receiveGroupSize), 1, receiveChannelCount);
receiveChannels.Indices = int32(elementCount + makeReceiveIndices(...
    receiveGeometry, receiveGroupSize));
receiveChannels.Apodizations = single(receiveGeometry(5, :));
receiveChannels.Delays = single(receiveGeometry(23, :));
receiveChannels.Impulse = ones(1, receiveChannelCount, "uint16");
simulation.ReceiveChannels = receiveChannels;

simulation.Scatters = ekhos.ScatterSet();
simulation.Scatters.Count = uint32(size(scatterPositions, 2));
simulation.Scatters.Positions = single(scatterPositions);
simulation.Scatters.Amplitudes = single(scatterAmplitudes);
end

function normals = tangentsToNormals(tangents)
normals = [tangents(2, :)./sqrt(1 + tangents(2, :).^2);
    tangents(1, :)./sqrt(1 + tangents(1, :).^2);
    sqrt(1 - (tangents(1, :).^2).*(tangents(2, :).^2))./sqrt(1 + tangents(1, :).^2)./sqrt(1 + tangents(2, :).^2)];
end

function indices = makeReceiveIndices(receiveGeometry, receiveGroupSize)
if receiveGroupSize == 1
    indices = 1:size(receiveGeometry, 2);
    return;
end
xPositions = receiveGeometry(8, :);
uniqueXPositions = unique(xPositions, "stable");
indices = zeros(1, numel(uniqueXPositions) * receiveGroupSize);
writeIndex = 1;
for xPosition = uniqueXPositions
    group = find(abs(xPositions - xPosition) < eps(max(abs(xPosition), 1)));
    if numel(group) ~= receiveGroupSize
        error("Expected %d receive subelements at x=%g, found %d.", ...
            receiveGroupSize, xPosition, numel(group));
    end
    indices(writeIndex:writeIndex + receiveGroupSize - 1) = group;
    writeIndex = writeIndex + receiveGroupSize;
end
end

function grouped = groupSignals(data, groupSize)
channelCount = size(data, 2);
grouped = reshape(sum(reshape(data, size(data, 1), groupSize, channelCount / groupSize, size(data, 3)), 2), ...
    size(data, 1), channelCount / groupSize, size(data, 3));
end

function freeApertures(transmitAperture, receiveAperture)
fieldII.xdc_free(transmitAperture);
fieldII.xdc_free(receiveAperture);
end

function hardware = getHardwareInfo()
if ispc
    [~, cpuName] = system('powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)"');
    [~, gpuName] = system('powershell -NoProfile -Command "(Get-CimInstance Win32_VideoController | Select-Object -First 1 -ExpandProperty Name)"');
    if isempty(strtrim(cpuName))
        [~, cpuName] = system("wmic cpu get Name /value");
    end
    if isempty(strtrim(gpuName))
        [~, gpuName] = system("wmic path win32_VideoController get Name /value");
    end
elseif ismac
    [~, cpuName] = system("system_profiler SPHardwareDataType | sed -n 's/^[[:space:]]*\\(Chip\\|Processor Name\\):[[:space:]]*//p' | head -n 1");
    [~, gpuName] = system("system_profiler SPDisplaysDataType | sed -n 's/^[[:space:]]*Chipset Model:[[:space:]]*//p' | head -n 1");
else
    [~, cpuName] = system("lscpu 2>/dev/null | grep -m1 'Model name' | cut -d: -f2-");
    [~, gpuName] = system("vulkaninfo --summary 2>/dev/null | awk -F= '/deviceName[[:space:]]*=/{name=$2} /deviceType[[:space:]]*=.*DISCRETE_GPU/{print name; exit}' | sed -n 's/^[[:space:]]*//p'");
    if isempty(strtrim(gpuName))
        [~, gpuName] = system("vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceName[[:space:]]*[=:][[:space:]]*//p' | head -n 1");
    end
    if isempty(strtrim(gpuName))
        [~, gpuName] = system("nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -n 1");
    end
    if isempty(strtrim(gpuName))
        [~, gpuName] = system("lspci -nn 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' | head -n 1 | sed -E 's/.*: //; s/ \\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\\].*//' ");
    end
end

cpuName = strtrim(cpuName);
if isempty(cpuName)
    cpuName = strtrim(computer());
end
gpuName = strtrim(gpuName);
if isempty(gpuName)
    gpuName = "GPU unavailable";
end
gpuName = regexprep(gpuName, '\s*\([^)]*\)\s*$', '');
gpuName = regexprep(gpuName, '\s*\[[^]]*\]\s*$', '');
gpuTokens = regexp(gpuName, ...
    '(Radeon\s+[^\(\[]+|GeForce\s+[^\(\[]+|Quadro\s+[^\(\[]+|Tesla\s+[^\(\[]+|Arc\s+[^\(\[]+)', ...
    'tokens', 'once', 'ignorecase');
if ~isempty(gpuTokens)
    gpuName = gpuTokens{1};
end
gpuName = strtrim(gpuName);

hardware = struct("cpu", cpuName, "gpu", gpuName);
end

function saveBenchmarkFigures(results, hardware, outputDirectory, timestamp)
hardwareLabel = sprintf("CPU: %s\nGPU: %s", hardware.cpu, hardware.gpu);
resultArrayKinds = string(results{:, 1});
resultSimulators = string(results{:, 2});
resultElementCounts = results{:, 3};
resultReceiveGroupSizes = results{:, 4};
resultScatterCounts = results{:, 6};
resultTransmissionCounts = results{:, 7};
resultFieldIISeconds = results{:, 9};
resultWallSeconds = results{:, 10};
arrayKinds = unique(resultArrayKinds, "stable");
seriesNames = ["Field II", "Ekhos CPU", "Ekhos GPU"];
seriesSimulators = ["", "CPU", "GPU"];
seriesLineWidths = [5, 3.75, 2.5];
    colorcetColors = colorcet('L16', 'N', 5);
    seriesColors = colorcetColors(2:4, :);
panelCount = 0;
for arrayKind = arrayKinds'
    panelCount = panelCount + numel(unique(resultElementCounts(resultArrayKinds == arrayKind)));
end
panelRows = ceil(sqrt(panelCount));
panelColumns = ceil(panelCount / panelRows);
plotTransmissionCount = 1;

timingFigure = figure("Visible", "off", "Color", "w", "Name", "Ekhos benchmark timing");
panelIndex = 0;
for arrayKind = arrayKinds'
    elementCounts = unique(resultElementCounts(resultArrayKinds == arrayKind));
    for elementCount = elementCounts'
        panelIndex = panelIndex + 1;
        subplot(panelRows, panelColumns, panelIndex);
    axesHandle = gca;
    axesHandle.Color = "w";
    axesHandle.XColor = "k";
    axesHandle.YColor = "k";
    axesHandle.Title.Color = "k";
    axesHandle.XLabel.Color = "k";
    axesHandle.YLabel.Color = "k";
    axesHandle.GridColor = [0.7, 0.7, 0.7];
        colororder(axesHandle, seriesColors);
    hold on;
        if arrayKind == "linear"
            plotReceiveGroupSize = round(sqrt(elementCount));
        else
            plotReceiveGroupSize = 1;
        end
        baseMask = resultArrayKinds == arrayKind & ...
            resultElementCounts == elementCount & ...
            resultReceiveGroupSizes == plotReceiveGroupSize & ...
            resultTransmissionCounts == plotTransmissionCount;
        scatterValues = unique(resultScatterCounts(baseMask));
        for seriesIndex = 1:numel(seriesNames)
            seriesMask = baseMask;
            if seriesIndex > 1
                seriesMask = seriesMask & resultSimulators == seriesSimulators(seriesIndex);
            end
            [values, ~] = summarizeMeasurements(...
                resultScatterCounts, resultWallSeconds, seriesMask, scatterValues);
            plot(scatterValues, values, ":o", ...
                "Color", seriesColors(seriesIndex, :), "LineWidth", seriesLineWidths(seriesIndex), ...
                "MarkerFaceColor", seriesColors(seriesIndex, :), ...
                "MarkerEdgeColor", seriesColors(seriesIndex, :), ...
                "MarkerSize", 7, "DisplayName", seriesNames(seriesIndex));
        end
        set(axesHandle, "XScale", "log");
        axesHandle.XTick = scatterValues;
        axesHandle.XTickLabel = arrayfun(@(value) sprintf("2^{%d}", round(log2(value))), ...
            scatterValues, "UniformOutput", false);
        axesHandle.TickLabelInterpreter = "tex";
        grid on;
        xlabel("Scatter count");
        ylabel("Mean wall time (s)");
        title(sprintf("%s", arrayKind));
        subtitleHandle = subtitle(sprintf("%d \\times %d elements", ...
            round(sqrt(elementCount)), round(sqrt(elementCount))));
        subtitleHandle.Color = [0.25, 0.25, 0.25];
            legendHandle = legend("Location", "northwest");
            legendHandle.Color = "w";
            legendHandle.TextColor = "k";
    end
end
annotation(timingFigure, "textbox", [0.02, 0.92, 0.96, 0.06], ...
        "String", hardwareLabel, "Color", "k", "EdgeColor", "none", ...
        "HorizontalAlignment", "center");
saveas(timingFigure, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + "-timing.png"));
saveas(timingFigure, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + "-timing.fig"));
close(timingFigure);

speedupFigure = figure("Visible", "off", "Color", "w", "Name", "Ekhos benchmark speedup");
panelIndex = 0;
for arrayKind = arrayKinds'
    elementCounts = unique(resultElementCounts(resultArrayKinds == arrayKind));
    for elementCount = elementCounts'
        panelIndex = panelIndex + 1;
        subplot(panelRows, panelColumns, panelIndex);
    axesHandle = gca;
    axesHandle.Color = "w";
    axesHandle.XColor = "k";
    axesHandle.YColor = "k";
    axesHandle.Title.Color = "k";
    axesHandle.XLabel.Color = "k";
    axesHandle.YLabel.Color = "k";
    axesHandle.GridColor = [0.7, 0.7, 0.7];
        colororder(axesHandle, seriesColors(2:3, :));
    hold on;
        if arrayKind == "linear"
            plotReceiveGroupSize = round(sqrt(elementCount));
        else
            plotReceiveGroupSize = 1;
        end
        baseMask = resultArrayKinds == arrayKind & ...
            resultElementCounts == elementCount & ...
            resultReceiveGroupSizes == plotReceiveGroupSize & ...
            resultTransmissionCounts == plotTransmissionCount;
        scatterValues = unique(resultScatterCounts(baseMask));
        for seriesIndex = 2:3
            seriesMask = baseMask & resultSimulators == seriesSimulators(seriesIndex);
            [values, ~] = summarizeMeasurements(...
                resultScatterCounts, resultFieldIISeconds ./ resultWallSeconds, ...
                seriesMask, scatterValues);
            plot(scatterValues, values, ":o", ...
                "Color", seriesColors(seriesIndex, :), "LineWidth", seriesLineWidths(seriesIndex), ...
                "MarkerFaceColor", seriesColors(seriesIndex, :), ...
                "MarkerEdgeColor", seriesColors(seriesIndex, :), ...
                "MarkerSize", 7, "DisplayName", seriesNames(seriesIndex));
        end
        set(axesHandle, "XScale", "log");
        axesHandle.XTick = scatterValues;
        axesHandle.XTickLabel = arrayfun(@(value) sprintf("2^{%d}", round(log2(value))), ...
            scatterValues, "UniformOutput", false);
        axesHandle.TickLabelInterpreter = "tex";
        grid on;
        xlabel("Scatter count");
        ylabel("Field II / Ekhos wall-time ratio");
        title(sprintf("%s", arrayKind));
        subtitleHandle = subtitle(sprintf("%d \\times %d elements", ...
            round(sqrt(elementCount)), round(sqrt(elementCount))));
        subtitleHandle.Color = [0.25, 0.25, 0.25];
            legendHandle = legend("Location", "northwest");
            legendHandle.Color = "w";
            legendHandle.TextColor = "k";
    end
end
annotation(speedupFigure, "textbox", [0.02, 0.92, 0.96, 0.06], ...
    "String", hardwareLabel, "EdgeColor", "none", "HorizontalAlignment", "center");
saveas(speedupFigure, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + "-speedup.png"));
saveas(speedupFigure, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + "-speedup.fig"));
close(speedupFigure);
end

function [means, errors] = summarizeMeasurements(scatterCounts, measurements, mask, scatterValues)
means = nan(size(scatterValues));
errors = nan(size(scatterValues));
for scatterIndex = 1:numel(scatterValues)
    values = measurements(mask & scatterCounts == scatterValues(scatterIndex));
    if ~isempty(values)
        means(scatterIndex) = mean(values);
        errors(scatterIndex) = std(values, 0);
    end
end
end
