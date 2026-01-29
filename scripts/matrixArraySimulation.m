addpath("matlab");
%% Simulation Settings
fs = 100e6;
c = 1540;
dt = 1/fs;

rowCount = 128;
columnCount = 128;

rowCountT = rowCount;
rowCountR = rowCount;
columnCountT = columnCount;
columnCountR = columnCount;

dieWidthT = [1, 1]*2.2e-4;
dieWidthR = [1, 1]*2.2e-4;
dieKerfT = 3e-5;
dieKerfR = 3e-5;

fc = 5e6;
cycleCount = 2;

% impulseResponse = GetImpulseResponse(fc, fs);
impulseResponse = 1;
% excitation = sin(2*pi*(0:1/fs:cycleCount/fc)*fc);
excitation = 1;

scatterPosition = [0, 0, 20e-3]'*1;
% scatterPosition = [0, 5e-3, 20e-3]'*1;
% scatterPosition = [5e-3, 5e-3, 20e-3]'*1;
% scatterPosition = [10e-3, 5e-3, 20e-3]'*1;
scatterAmplitude = ones(1, size(scatterPosition, 2));

diePositionT = [0, 0, 0]*1e-3;
diePositionR = [0, 0, 0]*1e-3;

%% Field II Simulation

fieldII.field_init(-1);

% fieldII.set_field('no_ascii_output', 1);

fieldII.set_field('c', c);
fieldII.set_field('fs', fs);

tTh = fieldII.xdc_2d_array(columnCountT, rowCountT, dieWidthT(1), dieWidthT(2), dieKerfT, dieKerfT, ones(columnCountT, rowCountT)',1,1,[0, 0, 1e10]);
rTh = fieldII.xdc_2d_array(columnCountR, rowCountR, dieWidthR(1), dieWidthR(2), dieKerfR, dieKerfR, ones(columnCountR, rowCountR)',1,1,[0, 0, 1e10]);

fieldII.xdc_impulse(tTh, double(impulseResponse));
fieldII.xdc_impulse(rTh, double(impulseResponse));
fieldII.xdc_excitation(tTh, double(excitation));


fieldII.xdc_apodization(tTh, 0, reshape(ones(columnCountT, rowCountT)', 1, []));
fieldII.xdc_apodization(rTh, 0, reshape(ones(columnCountR, rowCountR)', 1, []));

% fieldII.xdc_times_focus(tTh, 0, double(delays(:)'));
% fieldII.ele_delay(tTh, double(1:die.ColumnCount*die.RowCount)', double(delays(:)));

fieldTimer = tic();
[fullRF, fieldIIStartTime] = fieldII.calc_scat_multi(tTh, rTh, scatterPosition', scatterAmplitude);
fieldTime = toc(fieldTimer);

times = fieldIIStartTime + dt*(0:(size(fullRF, 1)-1));

tData = fieldII.xdc_get(tTh, 'rect');
rData = fieldII.xdc_get(rTh, 'rect');


%% vkField Simulation

simulator = vkField.Simulation();
simulator.SamplingFrequency = fs;
simulator.SpeedOfSound = c;

simulator.Scatters.Count = size(scatterPosition, 2);
simulator.Scatters.Positions = scatterPosition;
simulator.Scatters.Amplitudes = scatterAmplitude;

simulator.TransmitElements.Count = size(tData, 2);
simulator.TransmitElements.Positions = tData(8:10, :);
simulator.TransmitElements.Normals = tangentsToNormals(tData(8:10, :));
simulator.TransmitElements.Sizes = tData(3:4, :);
simulator.TransmitElements.PhysicalApodizations = tData(5, :);
simulator.TransmitElements.PhysicalDelays = tData(23, :);

simulator.ReceiveElements.Count = size(rData, 2);
simulator.ReceiveElements.Positions = rData(8:10, :);
simulator.ReceiveElements.Normals = tangentsToNormals(rData(8:10, :));
simulator.ReceiveElements.Sizes = rData(3:4, :);
simulator.ReceiveElements.PhysicalApodizations = rData(5, :);
simulator.ReceiveElements.PhysicalDelays = rData(23, :);


% mex("matlab\vkField_lib.cpp", "matlab\vkField_lib.lib", "-g", "-R2018a", "-output", "matlab\vkField_mex");
vkTimer = tic();
pulseEcho = vkField_mex(simulator);
vkTime = toc(vkTimer);

fprintf("fieldII Time == %d\n", fieldTime);
fprintf("vkField Time == %d\n", vkTime);

pulseEcho = double(pulseEcho) * dt^4;

vkTimes = simulator.StartTime + (0:(size(pulseEcho, 1)-1))/fs;

f1 = figure(); tl1 = tiledlayout(f1, 1, 2);
ax1 = gobjects(1, 2);
for j = 1:numel(ax1)
    ax1(j) = nexttile(tl1);
end

im1(1) = imagesc(ax1(1), 1:columnCountR, times*1e6, fullRF);
im1(1) = imagesc(ax1(2), 1:columnCountR, vkTimes*1e6, pulseEcho);

vw1 = VideoWriter(fullfile("figures", "matrixArrayComparison" + ".mp4"), "MPEG-4");
vw1.FrameRate = 30;
vw1.open();

f2 = figure(); ax2 = axes(f2); hold(ax2, "on");
for i = 1:size(fullRF, 2)
    hold(ax2, "off");
    p2(1) = plot(ax2, times*1e6, fullRF(:, i), '-'); hold(ax2, "on");
    p2(2) = plot(ax2, vkTimes*1e6, pulseEcho(:, i), '-');
    legend(ax2, "FieldII", "vkField");

    lineWidth = 16;
    for j = 1:numel(p2)
        p2(j).LineWidth = lineWidth;
        lineWidth = lineWidth * 0.50;
    end
    drawnow;
    vw1.writeVideo(getframe(f2));
end
vw1.close();

function normals = tangentsToNormals(tangents)
normals = [tangents(2, :)./sqrt(1 + tangents(2, :).^2);
    tangents(1, :)./sqrt(1 + tangents(1, :).^2);
    sqrt(1 - (tangents(1, :).^2).*(tangents(2, :).^2))./sqrt(1 + tangents(1, :).^2)./sqrt(1 + tangents(2, :).^2)];
end
