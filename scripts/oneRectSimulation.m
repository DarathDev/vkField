%% Simulation Settings
fs = 100e6;
c = 1540;
dt = 1/fs;

rowCount = 1;
columnCount = 1;

dieWidthT = [1, 1]*2.2e-4;
dieWidthR = [1, 1]*2.2e-4;
dieKerf = 3e-5;

fc = 5e6;
cycleCount = 2;

% impulseResponse = GetImpulseResponse(fc, fs);
impulseResponse = 1;
% excitation = sin(2*pi*(0:1/fs:cycleCount/fc)*fc);
excitation = 1;

% scatterPosition = [0, 0, 20e-3]*4;
% scatterPosition = [0, 5e-3, 20e-3]*1;
scatterPosition = [5e-3, 5e-3, 20e-3]*1;
% scatterPosition = [10e-3, 5e-3, 20e-3]*1;

diePositionT = [0, 0, 0]*1e-3;
diePositionR = [0, 0, 0]*1e-3;

%% Field II Simulation

fieldII.field_init(-1);

% fieldII.set_field('no_ascii_output', 1);

fieldII.set_field('c', c);
fieldII.set_field('fs', fs);

tTh = fieldII.xdc_2d_array(columnCount, rowCount, dieWidthT(1), dieWidthT(2), dieKerf, dieKerf, ones(columnCount, rowCount)',1,1,[0, 0, 1e10]);
rTh = fieldII.xdc_2d_array(columnCount, rowCount, dieWidthR(1), dieWidthR(2), dieKerf, dieKerf, ones(columnCount, rowCount)',1,1,[0, 0, 1e10]);

fieldII.xdc_impulse(tTh, double(impulseResponse));
fieldII.xdc_impulse(rTh, double(impulseResponse));
fieldII.xdc_excitation(tTh, double(excitation));


fieldII.xdc_apodization(tTh, 0, ones(columnCount, rowCount)');
fieldII.xdc_apodization(rTh, 0, ones(columnCount, rowCount)');

% fieldII.xdc_times_focus(tTh, 0, double(delays(:)'));
% fieldII.ele_delay(tTh, double(1:die.ColumnCount*die.RowCount)', double(delays(:)));

[fullRF, fieldIIStartTime] = fieldII.calc_scat_multi(tTh, rTh, scatterPosition, 1);

times = fieldIIStartTime + dt*(0:(numel(fullRF)-1));

data = fieldII.xdc_get(rTh, 'rect');

%% Derived Values for Manual Simulation

addpath("matlab\")

settings = vkField.Settings;
settings.SamplingFrequency = fs;
settings.SpeedOfSound = c;
settings.TransmitElementCount = 1;
settings.ReceiveElementCount = 1;
settings.ScatterCount = 1;

transmitElements = vkField.RectangularElement;
transmitElements.Size = dieWidthT;
transmitElements.Position = diePositionT;
receiveElements = vkField.RectangularElement;
receiveElements.Size = dieWidthR;
receiveElements.Position = diePositionR;
scatters = vkField.Scatter;
scatters.Position = scatterPosition;
scatters.Amplitude = 1;

pT = scatters.Position - transmitElements.Position;
pR = scatters.Position - receiveElements.Position;
lT = norm(pT, 2);
lR = norm(pR, 2);
t0T = lT/settings.SpeedOfSound;
t0R = lR/settings.SpeedOfSound;

eT = transmitElements.Size.*pT(1:2);
eR = receiveElements.Size.*pR(1:2);
t1T = min(abs(eT))*t0T/lT^2;
t2T = max(abs(eT))*t0T/lT^2;
t1R = min(abs(eR))*t0R/lR^2;
t2R = max(abs(eR))*t0R/lR^2;

rectT = t0T + 0.5*(t1T*[-1, +1, -1, +1] + t2T*[-1, -1, +1, +1]);
rectR = t0R + 0.5*(t1R*[-1, +1, -1, +1] + t2R*[-1, -1, +1, +1]);
nRectT = rectT*fs;
nRectR = rectR*fs;

powerT = (prod(transmitElements.Size))/(2*pi*lT);
powerR = (prod(receiveElements.Size))/(2*pi*lR);
rectAreaT = (rectT(4) - rectT(1) <= dt)*dt + (rectT(4) - rectT(1) > dt)*(t2T);
rectAreaR = (rectR(4) - rectR(1) <= dt)*dt + (rectR(4) - rectR(1) > dt)*(t2R);
powerT = powerT/rectAreaT;
powerR = powerR/rectAreaR;


minTransmitDistance = inf;
maxTransmitDistance = 0;
minReceiveDistance = inf;
maxReceiveDistance = 0;

for i = 1:numel(scatters)
    for j= 1:numel(transmitElements)
        delta = norm(scatters(i).Position - transmitElements(j).Position, 2);
        elementDelta = norm(transmitElements(j).Size/2, 2);
        minTransmitDistance = min(minTransmitDistance, delta - elementDelta);
        maxTransmitDistance = max(maxTransmitDistance, delta + elementDelta);
    end

    for j= 1:numel(receiveElements)
        delta = norm(scatters(i).Position - receiveElements(j).Position, 2);
        elementDelta = norm(receiveElements(j).Size/2, 2);
        minReceiveDistance = min(minReceiveDistance, delta - elementDelta);
        maxReceiveDistance = max(maxReceiveDistance, delta + elementDelta);
    end
end

minDistance = minTransmitDistance + minReceiveDistance;
maxDistance = maxTransmitDistance + maxReceiveDistance;

minTransmitTime = minTransmitDistance/settings.SpeedOfSound;
maxTransmitTime = maxTransmitDistance/settings.SpeedOfSound;
minReceiveTime = minReceiveDistance/settings.SpeedOfSound;
maxReceiveTime = maxReceiveDistance/settings.SpeedOfSound;

manualStartTime = minDistance / settings.SpeedOfSound;

sampleCountPadding = 6; % There is little harm in padding by 6 samples to avoid edge cases


%% Far field Fraunhoffer Rectangular spatial impulse response

transmitSampleCount = ceil((maxTransmitTime - minTransmitTime)/dt);
transmitTimes = minTransmitTime - dt*sampleCountPadding/4 + dt*(0:(transmitSampleCount + sampleCountPadding));
transmitSamples = transmitTimes*fs;

receiveSampleCount = ceil((maxReceiveTime - minReceiveTime)/dt);
receiveTimes = minReceiveTime - dt*sampleCountPadding/4 + dt*(0:(receiveSampleCount + sampleCountPadding));
receiveSamples = receiveTimes*fs;

transmitValues = zeros(size(transmitSamples));
for i = 1:numel(transmitTimes)
    transmitValues(i) = sample_rect_aperture(transmitSamples(i), nRectT);
end

receiveValues = zeros(size(receiveSamples));
for i = 1:numel(receiveTimes)
    receiveValues(i) = sample_rect_aperture(receiveSamples(i), nRectR);
end

fraun = conv(transmitValues, receiveValues)*dt*(powerT * powerR * scatters(1).Amplitude);
fraun = conv(fraun, impulseResponse)*dt;
fraun = conv(fraun, impulseResponse)*dt;
fraun = conv(fraun, excitation)*dt;
fraunStartTime = min(transmitTimes) + min(receiveTimes);
fraunTimes = fraunStartTime + dt*(0:(numel(fraun)-1));


%% Manual Convolution

% manVkStartTime = fieldIIStartTime;

manVkSampleCount = ceil((maxDistance - minDistance) / c * fs);
manVkSampleCount = manVkSampleCount + sampleCountPadding;
manualStartTime = manualStartTime - sampleCountPadding/4/fs;

% Theoretical Ranges for N
minN = int32(floor((rectT(1) - manualStartTime) * fs) + floor(rectR(1) * fs));
maxN = int32(ceil((rectT(4) - manualStartTime) * fs) + ceil(rectR(4) * fs));

% Pratical Data Ranges for N
minN = int32(0);
maxN = int32(manVkSampleCount-1);

manualConvRf = zeros(1, manVkSampleCount, 'single');
manVkTimes = manualStartTime + (0:(manVkSampleCount-1))/fs;
nRectROff = nRectR - manualStartTime*fs;

for n = minN:maxN
    minK = int32(max(floor(nRectT(1) - 0.5), double(n) - ceil(nRectROff(4) + 0.5)));
    maxK = int32(min(ceil(nRectT(4) + 0.5), double(n) - floor(nRectROff(1) - 0.5)));

    summ = single(0);
    for j = minK:maxK
        tT = double(j);
        tR = double(n - j);
        vT = sample_rect_aperture(tT, nRectT);
        vR = sample_rect_aperture(tR, nRectROff);
        summ = summ  + single(vT*vR);
    end
    summ = summ * single(powerT * powerR * scatters(1).Amplitude*dt);
    if (n >= 0 && n < manVkSampleCount)
        manualConvRf(n + 1) = summ;
    end
end

function value = sample_rect_aperture(n, rectSamples)
qDelta = rectSamples(4) - rectSamples(1) < 1; % Delta
qRect = ~qDelta && (rectSamples(2) - rectSamples(1) < 1); % Rectangle
qTri = ~qDelta && (rectSamples(3) - rectSamples(2) < 1); % Triangle
qTrap = ~(qDelta | qRect | qTri); % Trapezoid

qRectLeft = (n >= rectSamples(2) - 0.5) & (n <= rectSamples(2) + 0.5); % Left Rectangle Edge
qRectCenter = (n > rectSamples(2) + 0.5) & (n <= rectSamples(3) - 0.5); % Rectangle
qRectRight = (n > rectSamples(3) - 0.5) & (n <= rectSamples(3) + 0.5); % Right Rectangle Edge

qTriLeft = (n >= rectSamples(1)) & (n <= rectSamples(2)); % Left Triangle
qTriRight = (n > rectSamples(3)) & (n <= rectSamples(4)); % Right Triangle

qTrapLeft = qTriLeft; % Left Trapezoid
qTrapCenter = (n > rectSamples(2)) & (n <= rectSamples(3)); % Center Trapezoid
qTrapRight = qTriRight; % Right Trapezoid


sDelta = 1 - abs(n - rectSamples(1)); % Delta

sRectLeft = n - (rectSamples(2) - 0.5); % Left Rectangle Edge
sRectCenter = 1; % Rectangle
sRectRight = 1 - (n - (rectSamples(3) - 0.5)); % Right Rectangle Edge

sTriLeft = (n - rectSamples(1)) ./ (rectSamples(2) - rectSamples(1) + eps); % Left Triangle
sTriRight = 1 - ((n - rectSamples(3)) ./ (rectSamples(4) - rectSamples(3) + eps)); % Right Triangle

sTrapLeft = sTriLeft; % Left Trapezoid
sTrapCenter = sRectCenter; % Center Trapezoid
sTrapRight = sTriRight; % Right Trapezoid

value = qDelta*sDelta + qRect*(qRectLeft*sRectLeft + qRectCenter*sRectCenter + qRectRight*sRectRight) + qTri*(qTriLeft*sTriLeft + qTriRight*sTriRight) +  qTrap*(qTrapLeft*sTrapLeft + qTrapCenter*sTrapCenter + qTrapRight*sTrapRight);
value = saturate(value);

    function v = saturate(a)
        v = min(1, max(0, a));
    end
end

manualConvRf = conv(manualConvRf, single(impulseResponse))*single(dt);
manualConvRf = conv(manualConvRf, single(impulseResponse))*single(dt);
manualConvRf = conv(manualConvRf, single(excitation))*single(dt);

%% Cumulative Loop

manualCumConvRf = zeros(1, manVkSampleCount, 'single');
for n = minN:maxN
    minK = int32(max(floor(nRectT(1) - 0.5), double(n) - ceil(nRectROff(4) + 0.5)));
    maxK = int32(min(ceil(nRectT(4) + 0.5), double(n) - floor(nRectROff(1) - 0.5)));

    summ = single(0);
    for j = minK:maxK
        tT = double(j);
        tR = double(n - j);
        vT = sample_rect_aperture_cum(tT, nRectT) - sample_rect_aperture_cum(tT - 1, nRectT);
        vR = sample_rect_aperture_cum(tR + 1, nRectROff) - sample_rect_aperture_cum(tR, nRectROff);
        summ = summ  + single(vT*vR);
    end
    summ = summ * single(powerT * powerR * scatters(1).Amplitude*dt);
    if (n >= 0 && n < manVkSampleCount)
        manualCumConvRf(n + 1) = summ;
    end
end

function value = sample_rect_aperture_cum(n, rectSamples)
qDelta = rectSamples(1) == rectSamples(4); % Delta
qRect = ~qDelta && (rectSamples(1) == rectSamples(2)); % Rectangle
qTri = ~qDelta && (rectSamples(2) == rectSamples(3)); % Triangle
qTrap = ~(qDelta | qRect | qTri); % Trapezoid

sDelta = n >= rectSamples(1); % Delta

sRect = (rectSamples(3) - rectSamples(2)) * saturate((n - rectSamples(2)) / (rectSamples(3) - rectSamples(2)));

sTriLeft = 0.5 * (rectSamples(2) - rectSamples(1)) * saturate((n - rectSamples(1)) / (rectSamples(2) - rectSamples(1)))^2;
sTriRight = 0.5 * (rectSamples(4) - rectSamples(3))*(1 - saturate((rectSamples(4) - n) / (rectSamples(4) - rectSamples(3)))^2);

value = qDelta * sDelta ...
    + qRect * sRect ...
    + qTri  * (sTriLeft + sTriRight) ...
    + qTrap * (sTriLeft + sRect + sTriRight);

    function v = saturate(a)
        v = min(1, max(0, a));
    end
end

manualCumConvRf = conv(manualCumConvRf, single(impulseResponse))*single(dt);
manualCumConvRf = conv(manualCumConvRf, single(impulseResponse))*single(dt);
manualCumConvRf = conv(manualCumConvRf, single(excitation))*single(dt);

%% vkField

mex("matlab\vkField_lib.c", "matlab\vkField_lib.lib", "-g", "-R2018a", "-output", "matlab\vkField_mex");

[pulseEcho, vkStartTime] = vkField_mex(settings.ToBytes, transmitElements.ToBytes, receiveElements.ToBytes, scatters.ToBytes);
% pulseEcho = double(pulseEcho) * 2^-106;
pulseEcho = double(pulseEcho) * dt^4;
% pulseEcho = double(pulseEcho);

vkTimes = vkStartTime + (0:(size(pulseEcho, 1)-1))/fs;

%% Plot

f1 = figure(); ax1 = axes(); hold(ax1, "on");
p1(1) = plot(ax1, times*1e6, fullRF, '-');
p1(2) = plot(ax1, fraunTimes*1e6, fraun, '-');
p1(3) = plot(ax1, manVkTimes*1e6, manualConvRf, '-');
p1(4) = plot(ax1, manVkTimes*1e6, manualCumConvRf, '-');
p1(5) = plot(ax1, vkTimes*1e6, pulseEcho, '-');
legend(ax1, "FieldII", "Manual Fraunhoffer", "Manual Fraounhoffer with Manual Convolution", "Manual Fraounhoffer Cumulative with Manual Convolution", "vkField");

lineWidth = 16;
for i = 1:numel(p1)
    p1(i).LineWidth = lineWidth;
    lineWidth = lineWidth * 0.75;
end

%% Measurements
distanceRatio = 1/(2*pi*lT)*(2*pi*lR);
fprintf("\n\n Sim to Distance Ratios\n")
fprintf("FieldII Energy to distance ratio %g\n", sum(abs(fullRF))/distanceRatio);
fprintf("Fraunhoffer Energy to distance ratio %g\n", double(sum(abs(fraun)))/distanceRatio);
fprintf("Manual Conv Energy to distance ratio %g\n", double(sum(abs(manualConvRf)))/distanceRatio);
fprintf("Manual Cumulative Energy to distance ratio %g\n", double(sum(abs(manualCumConvRf)))/distanceRatio);
fprintf("vkField Energy to distance ratio %g\n", double(sum(abs(pulseEcho)))/distanceRatio);

distanceRatio = 1/(2*pi*lT)*(2*pi*lR);
fprintf("\n\n Sim Energy Density to Distance Ratios\n")
fprintf("FieldII Energy Density to distance ratio %g\n", sum(abs(fullRF))/distanceRatio);
fprintf("Fraunhoffer Energy Density to distance ratio %g\n", double(sum(abs(fraun)))/distanceRatio);
fprintf("Manual Conv Energy Density to distance ratio %g\n", double(sum(abs(manualConvRf)))/distanceRatio);
fprintf("Manual Cumulative Energy Density to distance ratio %g\n", double(sum(abs(manualCumConvRf)))/distanceRatio);
fprintf("vkField Energy Density to distance ratio %g\n", double(sum(abs(pulseEcho)))/distanceRatio);

fprintf("\n\n Sim to Field II Ratios\n")
fprintf("Fraunhoffer to FieldII ratio %g\n", double(sum(abs(fraun)))/sum(abs(fullRF)));
fprintf("Manual Conv to FieldII ratio %g\n", double(sum(abs(manualConvRf)))/sum(abs(fullRF)));
fprintf("Manual Cumulative to FieldII ratio %g\n", double(sum(abs(manualCumConvRf)))/sum(abs(fullRF)));
fprintf("vkField to FieldII ratio %g\n", double(sum(abs(pulseEcho)))/sum(abs(fullRF)));

%%% Near field (Exact Analytic) Rectangle spatial impulse
%% Rectangle 2a wide (x) 2b long (y)

% d1 = x - a;
% d2 = y - b;
% d3 = x + a;
% d4 = y + b;
%
% taua = sqrt(d1^2 + d2^2 + z^2)/c;
% taub = sqrt(d2^2 + d3^2 + z^2)/c;
% tauc = sqrt(d1^2 + d4^2 + z^2)/c;
% taud = sqrt(d3^2 + d4^2 + z^2)/c;
%
% sigma = sqrt(c^2*t^2 - z^2);
%
% alpha1 = arcsin(d1/sigma);

%% Region 1, x >= a, y >= b

%% Region 2, x <= a, y >= b

%% Region 3, x >= a, y <= b

%% Region 4, x <= a, y <= b
