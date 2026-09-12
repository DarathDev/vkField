addpath("matlab");

plotting = false;
%% Simulation Settings
fs = 100e6;
c = 1540;
dt = 1/fs;

rowCount = 1;
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

impulseResponse = GetImpulseResponse(fc, fs);
% impulseResponse = 1;
excitation = sin(2*pi*(0:1/fs:cycleCount/fc)*fc);
% excitation = 1;

nScatters = 16;
scatterPosition = rand(3, nScatters) .* [16e-3, 16e-3, 100e-3]' + [-8e-3, -8e-3, 0]';
scatterAmplitude = ones(size(scatterPosition, 2), 1);

diePositionT = [0, 0, 0]*1e-3;
diePositionR = [0, 0, 0]*1e-3;

%% Field II Simulation

fieldII.field_init(-1);

% fieldII.set_field('no_ascii_output', 1);

fieldII.set_field('c', c);
fieldII.set_field('fs', fs);

% tTh = fieldII.xdc_2d_array(columnCountT, rowCountT, dieWidthT(1), dieWidthT(2), dieKerfT, dieKerfT, ones(columnCountT, rowCountT)',1,1,[0, 0, 1e10]);
% rTh = fieldII.xdc_2d_array(columnCountR, rowCountR, dieWidthR(1), dieWidthR(2), dieKerfR, dieKerfR, ones(columnCountR, rowCountR)',1,1,[0, 0, 1e10]);
tTh = fieldII.xdc_linear_array(columnCountT, dieWidthT(1), dieWidthT(2)*rowCount, dieKerfT, 1, rowCount, [0, 0, 1e10]);
rTh = fieldII.xdc_linear_array(columnCountR, dieWidthR(1), dieWidthR(2)*rowCount, dieKerfR, 1, rowCount, [0, 0, 1e10]);

fieldII.xdc_impulse(tTh, double(impulseResponse));
fieldII.xdc_impulse(rTh, double(impulseResponse));
fieldII.xdc_excitation(tTh, double(excitation));


% fieldII.xdc_apodization(tTh, 0, ones(columnCount, rowCount)');
% fieldII.xdc_apodization(rTh, 0, ones(columnCount, rowCount)');
fieldII.xdc_apodization(tTh, 0, ones(1, columnCountT));
fieldII.xdc_apodization(rTh, 0, ones(1, columnCountR));

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
simulator.Cumulative = true;
simulator.SimulatorType = vkField.SimulatorType.CPU;
simulator.SamplingFrequency = fs;
simulator.SpeedOfSound = c;
simulator.Impulses = {single(impulseResponse)};
simulator.Excitations = {single(excitation)};

simulator.Elements = vkField.RectangularElementSet();
simulator.Elements.Count = uint32(size(tData, 2) + size(rData, 2));
simulator.Elements.Positions = single([tData(8:10, :), rData(8:10, :)]);
simulator.Elements.Normals = single([tangentsToNormals(tData(8:10, :)), tangentsToNormals(rData(8:10, :))]);
simulator.Elements.Sizes = single([tData(3:4, :), rData(3:4, :)]);
simulator.Elements.Apodizations = single([tData(5, :), rData(5, :)]);
simulator.Elements.Delays = single([tData(23, :), rData(23, :)]);

transmit = vkField.TransmissionSet();
transmit.Count = uint32(1);
transmit.ElementCounts = uint32(size(tData, 2));
transmit.Indices = int32(1:size(tData, 2));
transmit.Apodizations = single(tData(5, :));
transmit.Delays = single(tData(23, :));
transmit.Impulse = ones(1, transmit.Count, 'uint16');
transmit.Excitation = ones(1, transmit.Count, 'uint16');
simulator.Transmissions = transmit;

receiveChannels = vkField.ReceiveChannelSet();
receiveChannels.Count = uint32(columnCountR);
receiveChannels.ElementCounts = repmat(uint32(rowCountR), 1, columnCountR);
receiveChannels.Indices = int32(size(tData, 2) + (1:size(rData, 2)));
receiveChannels.Apodizations = single(rData(5, :));
receiveChannels.Delays = single(rData(23, :));
receiveChannels.Impulse = ones(1, receiveChannels.Count, 'uint16');
simulator.ReceiveChannels = receiveChannels;

simulator.Scatters = vkField.ScatterSet();
simulator.Scatters.Count = uint32(size(scatterPosition, 2));
simulator.Scatters.Positions = single(scatterPosition);
simulator.Scatters.Amplitudes = single(scatterAmplitude);


mex("matlab\vkField_lib.cpp", "matlab\vkField_lib.lib", "-g", "-R2018a", "-output", "matlab\vkField_mex");
vkTimer = tic();
pulseEcho = vkField_mex(simulator);
vkTime = toc(vkTimer);


fprintf("fieldII Time == %d\n", fieldTime);
fprintf("vkField Time == %d\n", vkTime);
fprintf("vkField Self Time == %d\n", simulator.Metrics.SimulationTime);
fprintf("Relative Speed Up == %.3fx\n", fieldTime / simulator.Metrics.SimulationTime);

pulseEcho = double(pulseEcho) * dt;
% pulseEcho = fliplr(pulseEcho);

vkTimes = simulator.StartTime + (0:(size(pulseEcho, 1)-1))/fs;
if plotting
    f1 = figure(); tl1 = tiledlayout(f1, 1, 2);
    ax1 = gobjects(1, 2);
    for j = 1:numel(ax1)
        ax1(j) = nexttile(tl1);
    end

    im1(1) = imagesc(ax1(1), 1:columnCountR, times*1e6, fullRF);
    im1(1) = imagesc(ax1(2), 1:columnCountR, vkTimes*1e6, pulseEcho);

    vw1 = VideoWriter(fullfile("figures", "linearArrayComparison" + ".mp4"), "MPEG-4");
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
end

function normals = tangentsToNormals(tangents)
normals = [tangents(2, :)./sqrt(1 + tangents(2, :).^2);
    tangents(1, :)./sqrt(1 + tangents(1, :).^2);
    sqrt(1 - (tangents(1, :).^2).*(tangents(2, :).^2))./sqrt(1 + tangents(1, :).^2)./sqrt(1 + tangents(2, :).^2)];
end
