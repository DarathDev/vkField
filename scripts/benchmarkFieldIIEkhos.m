%% Benchmark Field II against Ekhos CPU and GPU.
% The benchmark varies physical element count, scatter count, receive-channel
% grouping, and the number of transmissions. Results are written to a table
% and saved as a MAT file in the figures directory.

scriptDirectory = fileparts(mfilename("fullpath"));
repositoryDirectory = fileparts(scriptDirectory);
addpath(repositoryDirectory);
addpath(fullfile(repositoryDirectory, "matlab"));

%% Benchmark settings
fs = single(100e6);
c = single(1540);
fc = single(5e6);
cycleCount = 2;

% Keep these vectors short for a first run.     Extend them for a full scaling sweep.
linearElementCounts = [32, 64, 128];
linearReceiveGroupSizes = [1, 2, 4, 8];
matrixSideLengths = [4, 8, 16];
matrixReceiveGroupSizes = [1, 4, 16];
scatterCounts = [1, 8, 32, 128];
transmissionCounts = [1, 4];
repetitions = 1;

runCPU = true;
runGPU = true;
writeResults = true;
rng(0, "twister");

impulseResponse = GetImpulseResponse(fc, fs);
excitation = sin(2 * pi * (0:1 / double(fs):cycleCount / double(fc)) * double(fc));

results = table();
fieldII.field_init(-1);
fieldII.set_field('c', double(c));
fieldII.set_field('fs', double(fs));

for arrayKind = ["linear", "matrix"]
    if strcmp(arrayKind, "linear")
        arraySizes = linearElementCounts;
        receiveGroupSizes = linearReceiveGroupSizes;
    else
        arraySizes = matrixSideLengths;
        receiveGroupSizes = matrixReceiveGroupSizes;
    end

    for arraySize = arraySizes
        if arrayKind == "linear"
            elementCount = arraySize;
            rowCount = 1;
            columnCount = arraySize;
        else
            rowCount = arraySize;
            columnCount = arraySize;
            elementCount = rowCount * columnCount;
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

                    [fieldIIData, fieldIITime, fieldIIChannelCount] = runFieldII(...
                        arrayKind, rowCount, columnCount, scatterPositions, scatterAmplitudes, ...
                        transmissionCount, impulseResponse, excitation);
                    fieldIIGrouped = groupSignals(fieldIIData, receiveGroupSize);
                    assert(size(fieldIIGrouped, 2) == receiveChannelCount, ...
                        "Field II grouping produced an unexpected channel count.");

                    simulatorTypes = [ekhos.SimulatorType.CPU, ekhos.SimulatorType.GPU];
                    simulatorTypes = simulatorTypes([runCPU, runGPU]);
                    for simulatorType = simulatorTypes
                        simulation = makeVkSimulation(...
                            arrayKind, rowCount, columnCount, scatterPositions, scatterAmplitudes, ...
                            receiveGroupSize, transmissionCount, fs, c, impulseResponse, excitation);
                        timer = tic();
                        vkData = simulation.call();
                        wallTime = toc(timer);
                        vkData = double(vkData);
                        if ismatrix(vkData)
                            vkData = reshape(vkData, size(vkData, 1), size(vkData, 2), 1);
                        end
                        vkData = vkData * (1 / double(fs));

                        row = table(string(arrayKind), string(simulatorType), elementCount, ...
                            receiveGroupSize, receiveChannelCount, scatterCount, transmissionCount, ...
                            fieldIIChannelCount, fieldIITime, wallTime, simulation.Metrics.SimulationTime, ...
                            size(fieldIIGrouped, 1), size(vkData, 1), ...
                            "VariableNames", {"arrayKind", "simulator", "elementCount", ...
                            "receiveGroupSize", "receiveChannelCount", "scatterCount", ...
                            "transmissionCount", "fieldIIChannelCount", "fieldIISeconds", ...
                            "wallSeconds", "simulationSeconds", "fieldIISampleCount", "vkSampleCount"});
                        results = [results; row]; %#ok<AGROW>

                        fprintf("  %s FieldII=%.4fs wall=%.4fs simulation=%.4fs speedup=%.2fx\n", ...
                            string(simulatorType), fieldIITime, wallTime, ...
                            double(simulation.Metrics.SimulationTime), fieldIITime / wallTime);
                    end
                end
            end
        end
    end
end

if repetitions > 1
    warning("repetitions is currently reserved for a future repeated-run aggregation.");
end

if writeResults
    outputDirectory = fullfile(repositoryDirectory, "figures");
    if ~isfolder(outputDirectory)
        mkdir(outputDirectory);
    end
    timestamp = string(datetime("now", "Format", "yyyyMMdd-HHmmss"));
    writetable(results, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + ".csv"));
    save(fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + ".mat"), "results");
end

%% Local functions
function positions = makeScatterPositions(scatterCount)
positions = [
    rand(1, scatterCount, "single") * 16e-3 - 8e-3;
    rand(1, scatterCount, "single") * 4e-3 - 2e-3;
    rand(1, scatterCount, "single") * 80e-3 + 20e-3;
    ];
end

function [data, elapsed, channelCount] = runFieldII(...
    arrayKind, rowCount, columnCount, scatterPositions, scatterAmplitudes, ...
    transmissionCount, impulseResponse, excitation)
if strcmp(arrayKind, "linear")
    tAperture = fieldII.xdc_linear_array(columnCount, 2.2e-4, 2.2e-4, 3e-5, 1, 1, [0, 0, 1e10]);
    rAperture = fieldII.xdc_linear_array(columnCount, 2.2e-4, 2.2e-4, 3e-5, 1, 1, [0, 0, 1e10]);
else
    tAperture = fieldII.xdc_2d_array(columnCount, rowCount, 2.2e-4, 2.2e-4, ...
        3e-5, 3e-5, ones(rowCount, columnCount)', 1, 1, [0, 0, 1e10]);
    rAperture = fieldII.xdc_2d_array(columnCount, rowCount, 2.2e-4, 2.2e-4, ...
        3e-5, 3e-5, ones(rowCount, columnCount)', 1, 1, [0, 0, 1e10]);
end
fieldII.xdc_impulse(tAperture, double(impulseResponse));
fieldII.xdc_impulse(rAperture, double(impulseResponse));
fieldII.xdc_excitation(tAperture, double(excitation));
fieldII.xdc_apodization(tAperture, 0, ones(1, columnCount * rowCount));
fieldII.xdc_apodization(rAperture, 0, ones(1, columnCount * rowCount));

fieldIIData = cell(transmissionCount, 1);
timer = tic();
for transmissionIndex = 1:transmissionCount
    [fieldIIData{transmissionIndex}, ~] = ...
        fieldII.calc_scat_multi(tAperture, rAperture, scatterPositions', double(scatterAmplitudes));
end
elapsed = toc(timer);
channelCount = size(fieldIIData{1}, 2);
maxSamples = max(cellfun(@(value) size(value, 1), fieldIIData));
data = zeros(maxSamples, channelCount, transmissionCount);
for transmissionIndex = 1:transmissionCount
    data(1:size(fieldIIData{transmissionIndex}, 1), :, transmissionIndex) = fieldIIData{transmissionIndex};
end
end

function simulation = makeVkSimulation(...
    arrayKind, rowCount, columnCount, scatterPositions, scatterAmplitudes, ...
    receiveGroupSize, transmissionCount, fs, c, impulseResponse, excitation)
elementCount = rowCount * columnCount;
[elementPositions, elementSizes] = makeElementGeometry(arrayKind, rowCount, columnCount);
simulation = ekhos.Simulation();
simulation.Cumulative = false;
simulation.SamplingFrequency = fs;
simulation.SpeedOfSound = c;
simulation.Impulses = {single(impulseResponse)};
simulation.Excitations = {single(excitation)};
simulation.Elements = ekhos.RectangularElementSet();
simulation.Elements.Count = uint32(2 * elementCount);
simulation.Elements.Positions = single([elementPositions, elementPositions]);
simulation.Elements.Normals = repmat(single([0; 0; 1]), 1, 2 * elementCount);
simulation.Elements.Sizes = single([elementSizes, elementSizes]);
simulation.Elements.Apodizations = ones(1, 2 * elementCount, "single");
simulation.Elements.Delays = zeros(1, 2 * elementCount, "single");

transmissions = ekhos.TransmissionSet();
transmissions.Count = uint32(transmissionCount);
transmissions.ElementCounts = repmat(uint32(elementCount), 1, transmissionCount);
transmissions.Indices = repmat(int32(1:elementCount), 1, transmissionCount);
transmissions.Apodizations = ones(1, transmissionCount * elementCount, "single");
transmissions.Delays = zeros(1, transmissionCount * elementCount, "single");
transmissions.Impulse = ones(1, transmissionCount, "uint16");
transmissions.Excitation = ones(1, transmissionCount, "uint16");
simulation.Transmissions = transmissions;

receiveChannelCount = elementCount / receiveGroupSize;
receiveChannels = ekhos.ReceiveChannelSet();
receiveChannels.Count = uint32(receiveChannelCount);
receiveChannels.ElementCounts = repmat(uint32(receiveGroupSize), 1, receiveChannelCount);
receiveChannels.Indices = int32(elementCount + reshape(reshape(1:elementCount, receiveGroupSize, [])', 1, []));
receiveChannels.Apodizations = ones(1, elementCount, "single");
receiveChannels.Delays = zeros(1, elementCount, "single");
receiveChannels.Impulse = ones(1, receiveChannelCount, "uint16");
simulation.ReceiveChannels = receiveChannels;

simulation.Scatters = ekhos.ScatterSet();
simulation.Scatters.Count = uint32(size(scatterPositions, 2));
simulation.Scatters.Positions = single(scatterPositions);
simulation.Scatters.Amplitudes = single(scatterAmplitudes);
end

function [positions, sizes] = makeElementGeometry(arrayKind, rowCount, columnCount)
if strcmp(arrayKind, "linear")
    elementCount = columnCount;
    x = ((0:columnCount - 1) - (columnCount - 1) / 2) * (2.2e-4 + 3e-5);
    positions = [x; zeros(1, elementCount); zeros(1, elementCount)];
else
    [xGrid, yGrid] = meshgrid(((0:columnCount - 1) - (columnCount - 1) / 2) * (2.2e-4 + 3e-5), ...
        ((0:rowCount - 1) - (rowCount - 1) / 2) * (2.2e-4 + 3e-5));
    positions = [reshape(xGrid, 1, []); reshape(yGrid, 1, []); zeros(1, rowCount * columnCount)];
end
sizes = repmat(single([2.2e-4; 2.2e-4]), 1, size(positions, 2));
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
