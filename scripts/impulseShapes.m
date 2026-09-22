scriptDirectory = fileparts(mfilename('fullpath'));
addpath(fullfile(scriptDirectory, 'color'));

timeRanges = [
    5, 5, 5, 5;  % Delta
    3, 5, 5, 7;  % Triangle
    3, 3, 7, 7;  % Rectangle
    1, 3, 7, 9   % Trapezoid
    ];
shapeNames = ["Delta", "Triangle", "Rectangle", "Trapezoid"];

sampleTimes = linspace(0, 10, 2001);
shapeColors = colorcet('L16', 'N', size(timeRanges, 1) + 1);
figureHandle = figure('Name', 'Impulse shapes', 'Position', [100, 100, 1000, 900]);
layout = tiledlayout(2, 2, 'TileSpacing', 'none', 'Padding', 'none');
axesHandles = gobjects(size(timeRanges, 1), 1);

for shapeIndex = 1:size(timeRanges, 1)
    controlTimes = timeRanges(shapeIndex, :);
    times = unique([sampleTimes, controlTimes]);
    values = impulse_shape(times, controlTimes);

    axesHandle = nexttile(layout);
    axesHandles(shapeIndex) = axesHandle;
    if controlTimes(1) == controlTimes(4)
        stem(controlTimes(1), 1, 'filled', 'Color', shapeColors(shapeIndex, :), 'LineWidth', 3);
    else
        plot(times, values, 'Color', shapeColors(shapeIndex, :), 'LineWidth', 3);
        hold on;
        controlValues = impulse_shape(controlTimes, controlTimes);
        plot(controlTimes, controlValues, '.', 'Color', shapeColors(shapeIndex, :), 'MarkerSize', 24);
        if controlTimes(1) == controlTimes(2) && controlTimes(3) == controlTimes(4)
            discontinuityTimes = [controlTimes(1), controlTimes(1), controlTimes(4), controlTimes(4)];
            discontinuityValues = [0, 1, 1, 0];
            plot(discontinuityTimes, discontinuityValues, '.', ...
                'Color', shapeColors(shapeIndex, :), 'MarkerSize', 24);
        end
    end
    xlim([0, 10]);
    ylim([-0.05, 1.1]);
    grid on;
    xlabel(axesHandle, 'Time', 'FontSize', 16);
    if shapeIndex <= 2
        set(axesHandle, 'XTickLabel', []);
    end
    if shapeIndex == 1 || shapeIndex == 3
        ylabel(axesHandle, 'Amplitude', 'FontSize', 16);
    else
        ylabel(axesHandle, '');
        set(axesHandle, 'YTickLabel', []);
    end
    titleHandle = title(axesHandle, shapeNames(shapeIndex), ...
        'FontSize', 16, 'HorizontalAlignment', 'left');
    titleHandle.Units = 'normalized';
    titleHandle.Position = [0.02, 0.98, 0];
    titleHandle.VerticalAlignment = 'top';
end

xTickPositions = axesHandles(3).XTick;
set(axesHandles(1:2), 'XTick', xTickPositions, 'XTickLabel', []);
linkaxes(axesHandles, 'xy');

outputDirectory = fullfile(scriptDirectory, '..', 'figures');
if ~isfolder(outputDirectory)
    mkdir(outputDirectory);
end
pause(1);
exportgraphics(figureHandle, fullfile(outputDirectory, 'impulseShapes.png'), 'Resolution', 300);
close(figureHandle);

randomSampleTimes = 0:0.01:100;
randomImpulseCount = 64;
randomImpulseSignal = zeros(size(randomSampleTimes));
fs = single(100);
fc = single(5);
cycleCount = 2;
rng(7, 'twister');
for impulseIndex = 1:randomImpulseCount
    shapeIndex = randi(size(timeRanges, 1));
    centerTime = randi([10, 90]);
    controlTimes = random_control_times(shapeIndex, centerTime);
    amplitude = 0.4 + 0.6 * rand();
    randomImpulseSignal = randomImpulseSignal + amplitude * ...
        impulse_shape(randomSampleTimes, controlTimes);
end

impulseResponse = GetImpulseResponse(fc, fs);
excitation = sin(2 * pi * (0:1 / double(fs):cycleCount / double(fc)) * double(fc));
summedResponse = conv(randomImpulseSignal, impulseResponse);
summedResponse = conv(summedResponse, excitation);
summedResponseTimes = (0:numel(summedResponse) - 1) / double(fs);

randomFigure = figure('Name', 'Random impulse sum', 'Position', [100, 100, 1600, 500]);
plot(summedResponseTimes, summedResponse, 'Color', shapeColors(2, :), 'LineWidth', 2);
grid on;
xlabel('Time', 'FontSize', 16);
ylabel('Amplitude', 'FontSize', 16);
xlim([summedResponseTimes(1), summedResponseTimes(end)]);
exportgraphics(randomFigure, fullfile(outputDirectory, 'randomImpulseSum.png'), 'Resolution', 300);
close(randomFigure);

function values = impulse_shape(times, controlTimes)
t1 = controlTimes(1);
t2 = controlTimes(2);
t3 = controlTimes(3);
t4 = controlTimes(4);
values = zeros(size(times));

if t1 == t4
    values(times == t1) = 1;
    return
end

risingRamp = times >= t1 & times < t2;
values(risingRamp) = (times(risingRamp) - t1) / (t2 - t1);
values(times >= t2 & times <= t3) = 1;
fallingRamp = times > t3 & times <= t4;
values(fallingRamp) = (t4 - times(fallingRamp)) / (t4 - t3);
end

function controlTimes = random_control_times(shapeIndex, centerTime)
switch shapeIndex
    case 1 % Delta
        controlTimes = [centerTime, centerTime, centerTime, centerTime];
    case 2 % Triangle
        halfWidth = randi([10, 300]) / 100;
        controlTimes = [centerTime - halfWidth, centerTime, centerTime, centerTime + halfWidth];
    case 3 % Rectangle
        halfPlateauWidth = randi([50, 200]) / 100;
        controlTimes = [centerTime - halfPlateauWidth, centerTime - halfPlateauWidth, ...
            centerTime + halfPlateauWidth, centerTime + halfPlateauWidth];
    case 4 % Trapezoid
        rampWidth = randi([10, 100]) / 100;
        halfPlateauWidth = randi([50, 200]) / 100;
        controlTimes = [centerTime - halfPlateauWidth - rampWidth, centerTime - halfPlateauWidth, ...
            centerTime + halfPlateauWidth, centerTime + halfPlateauWidth + rampWidth];
end
end
