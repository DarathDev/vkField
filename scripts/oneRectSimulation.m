fs = 100e6;
c = 1540;

rowCount = 1;
columnCount = 1;

dieWidth = [1, 1]*2.2e-4;
dieKerf = 3e-5;

fc = 5e6;

% impulseResponse = GetImpulseResponse(fc, fs);
impulseResponse = 1;
excitation = 1;

phantomPosition = [0, 0, 20e-3];
% phantomPosition = [0, 5e-3, 20e-3]*2;
% phantomPosition = [5e-3, 5e-3, 20e-3];
% phantomPosition = [10e-3, 5e-3, 20e-3];
phantomDistance = norm(phantomPosition, 2);

transmitDiePosition = [0, 0, 0]*1e-3;
receiveDiePosition = [0, 0, 0]*1e-3;

fieldII.field_init(-1);

% fieldII.set_field('no_ascii_output', 1);

fieldII.set_field('c', c);
fieldII.set_field('fs', fs);

tTh = fieldII.xdc_2d_array(columnCount, rowCount, dieWidth(1), dieWidth(2), dieKerf, dieKerf, ones(columnCount, rowCount)',1,1,[0, 0, 1e10]);
rTh = fieldII.xdc_2d_array(columnCount, rowCount, dieWidth(1), dieWidth(2), dieKerf, dieKerf, ones(columnCount, rowCount)',1,1,[0, 0, 1e10]);

fieldII.xdc_impulse(tTh, double(impulseResponse));
fieldII.xdc_impulse(rTh, double(impulseResponse));
fieldII.xdc_excitation(tTh, double(excitation));


fieldII.xdc_apodization(tTh, 0 , ones(columnCount, rowCount)');
fieldII.xdc_apodization(rTh, 0, ones(columnCount, rowCount)');

% fieldII.xdc_times_focus(tTh, 0, double(delays(:)'));
% fieldII.ele_delay(tTh, double(1:die.ColumnCount*die.RowCount)', double(delays(:)));

[fullRF, startTime] = fieldII.calc_scat_multi(tTh, rTh, phantomPosition, 1);

times = startTime + (1/fs)*(0:(numel(fullRF)-1));

data = fieldII.xdc_get(rTh, 'rect');


%% Far field Fraunhoffer Rectangular spatial impulse response

l = phantomDistance;

t0 = l/c;

dieProjection = dieWidth.*phantomPosition(1:2);
deltaT1 = min(abs(dieProjection))*t0/l^2;
deltaT2 = max(abs(dieProjection))*t0/l^2;


t1 = t0 + (- deltaT1 - deltaT2)/2;
t2 = t0 + (+ deltaT1 - deltaT2)/2;
t3 = t0 + (- deltaT1 + deltaT2)/2;
t4 = t0 + (+ deltaT1 + deltaT2)/2;

power = prod(dieWidth)/(2*pi*l);

baseTimes = t1:(1/fs):t4;
if (deltaT1 == 0 && deltaT2 == 0)
    diffs = 1 - (abs(times - 2*t0)*fs); 
    diffs(diffs < 0) = 0;
    % Field II simply picks the closest sample to add all the energy to.
    % Also it sometimes appears to be off by 1 time sample, which should be
    % negligible
    % diffs = zeros(size(times));
    % delt = abs((times - 2*t0)*fs);
    % diffs(min(delt) == delt) = 1;
    manRF = power^2*diffs;
    manRF = conv(manRF, impulseResponse);
    manRF = conv(manRF, impulseResponse);
    manRF((numel(times)+1):end) = [];
else
    if (deltaT1 == 0)
        % manRF = (baseTimes >= t2 & baseTimes <= t3)*1;
        manRF = (baseTimes >= t2-(0.5/fs) & baseTimes <= t2+(0.5/fs)).*(baseTimes-(t2-(0.5/fs)))*fs + (baseTimes > t2+(0.5/fs) & baseTimes <= t3-(0.5/fs))*1 + (baseTimes > t3-(0.5/fs) & baseTimes <= t3+(0.5/fs)).*(1 - ((baseTimes-(t3-(0.5/fs)))*fs));
    elseif ((deltaT2 - deltaT1) == 0)
        manRF = (baseTimes >= t1 & baseTimes <= t2).*(baseTimes-t1)./(t2-t1) + (baseTimes > t3 & baseTimes <= t4).*(1 - ((baseTimes-t3)./(t4 - t3)));
    else
        manRF = (baseTimes >= t1 & baseTimes <= t2).*(baseTimes-t1)./(t2-t1) + (baseTimes > t2 & baseTimes <= t3)*1 + (baseTimes > t3 & baseTimes <= t4).*(1 - ((baseTimes-t3)./(t4 - t3)));
    end
    manRF = power*manRF/sum(abs(manRF));
    manRF = conv(manRF, manRF);
    manRF = conv(manRF, impulseResponse);
    manRF = conv(manRF, impulseResponse);
    convTimes = (2*t1) + (1/fs)*(0:(numel(manRF)-1));
    manRF = interp1(convTimes, manRF, times, "linear", 0);
end


% figure(); plot(times*1e6,fullRF/sum(abs(fullRF)), '-', times*1e6, manRF/sum(abs(manRF)), '--' );

%% Manual Convolution
addpath("matlab\")

settings = vkField.Settings;
settings.SamplingFrequency = fs;
settings.SpeedOfSound = c;
settings.TransmitElementCount = 1;
settings.ReceiveElementCount = 1;
settings.ScatterCount = 1;

transmitElements = vkField.RectangularElement;
transmitElements.Size = dieWidth;
receiveElements = transmitElements;
scatters = vkField.Scatter;
scatters.Position = phantomPosition;
scatters.Amplitude = 1;

minTransmitDistance = inf;
maxTransmitDistance = 0;
minReceiveDistance = inf;
maxReceiveDistance = 0;

for i = 1:numel(scatters)
    for j= 1:numel(transmitElements) 
        delta = abs(scatters(i).Position - transmitElements(j).Position);
        elementDelta = dot(abs(transmitElements(j).Size)/2, delta(1:2))/norm(delta);
        minTransmitDistance = min(minTransmitDistance, norm(delta - elementDelta));
        maxTransmitDistance = max(maxTransmitDistance, norm(delta + elementDelta));
    end

    for j= 1:numel(receiveElements) 
        delta = abs(scatters(i).Position - receiveElements(j).Position);
        elementDelta = dot(abs(receiveElements(j).Size)/2, delta(1:2))/norm(delta);
        minReceiveDistance = min(minReceiveDistance, norm(delta - elementDelta));
        maxReceiveDistance = max(maxReceiveDistance, norm(delta + elementDelta));
    end
end

minDistance = minTransmitDistance + minReceiveDistance;
maxDistance = maxTransmitDistance + maxReceiveDistance;

manVkStartTime = minDistance / c;
% manVkStartTime = startTime;
manVkSampleCount = ceil((maxDistance - minDistance) / c * fs);
manVkSampleCount = manVkSampleCount + 6;
manVkStartTime = manVkStartTime - 1.5/fs;

minN = int32(floor((t1 - manVkStartTime) * fs) + floor(t1 * fs));
maxN = int32(ceil((t4 - manVkStartTime) * fs) + ceil(t4 * fs));

minN = int32(0);
maxN = int32(manVkSampleCount-1);

powerT = (norm(dieWidth, 2).^2)/(2*pi*length(l));
powerR = (norm(dieWidth, 2).^2)/(2*pi*length(l));

manConvRf = zeros(1, manVkSampleCount);

rectT = [t1, t2, t3, t4]*fs;
rectR = ([t1, t2, t3, t4] - manVkStartTime)*fs;
normT = (rectT(4) == rectT(1))*1 + (rectT(4) ~= rectT(1))*(rectT(4) - rectT(1));
normR = (rectR(4) == rectR(1))*1 + (rectR(4) ~= rectR(1))*(rectR(4) - rectR(1));

powerT = powerT/normT;
powerR = powerR/normR;

fprintf("Conv Indices:\n");
for n = minN:maxN
    minK = int32(max(floor(rectT(1) - 0.5), double(n) - ceil(rectR(4) - 0.5)));
    maxK = int32(min(ceil(rectT(4) + 0.5), double(n) - floor(rectR(1) + 0.5)));

    summ = 0;
    for j = minK:maxK
        tT = double(j);
        tR = double(n - j);
        vT = sample_rect_aperture(tT, rectT);
        vR = sample_rect_aperture(tR, rectR);
        summ = summ  + vT*vR;
    end
    summ = summ * powerT * powerR * scatters(1).Amplitude;
    if (n >= 0 && n < manVkSampleCount)
        manConvRf(n + 1) = summ;
    end
end

function value = sample_rect_aperture(n, rectSamples)

    qa = rectSamples(1) == rectSamples(4); % Delta
    qb = ~qa && rectSamples(1) == rectSamples(2); % Rectangle
    qc = ~qa && rectSamples(2) == rectSamples(3); % Triangle
    qd = ~(qa | qb | qc); % Trapezoid
    qba = (n >= rectSamples(2)-(0.5) & n <= rectSamples(2)+(0.5)); % Left Rectangle Edge
    qbb = (n > rectSamples(2)+(0.5) & n <= rectSamples(3)-(0.5)); % Rectangle
    qbc = (n > rectSamples(3)-(0.5) & n <= rectSamples(3)+(0.5)); % Right Rectangle Edge
    qca = (n >= rectSamples(1) & n <= rectSamples(2)); % Left Triangle
    qcb = (n > rectSamples(3) & n <= rectSamples(4)); % Right Triangle
    qda = qca; % Left Trapezoid
    qdb = (n > rectSamples(2) & n <= rectSamples(3)); % Center Trapezoid
    qdc = qcb; % Right Trapezoid

    sa = 1 - abs(n - rectSamples(1)); % Delta
    sba = (n-(rectSamples(2)-(0.5))); % Left Rectangle Edge
    sbb = 1; % Rectangle
    sbc = (1 - ((n-(rectSamples(3)-(0.5))))); % Right Rectangle Edge
    sca = (n-rectSamples(1))./(rectSamples(2)-rectSamples(1)+eps); % Left Triangle
    scb = (1 - ((n-rectSamples(3))./(rectSamples(4) - rectSamples(3)+eps))); % Right Triangle
    sda = sca; % Left Trapezoid
    sdb = sbb; % Center Trapezoid
    sdc = scb; % Right Trapezoid

    value = saturate(qa*sa + qb*(qba*sba + qbb*sbb + qbc*sbc) + qc*(qca*sca + qcb*scb) +  qd*(qda*sda + qdb*sdb + qdc*sdc));

    function v = saturate(a)
        v = min(1, max(0, a));
    end
end

manVkTimes = manVkStartTime + (0:(numel(manConvRf)-1))/fs;

%% vkField

mex("matlab\vkField_lib.c", "matlab\vkField_lib.lib", "-g", "-R2018a", "-output", "matlab\vkField_mex");

[pulseEcho, vkStartTime] = vkField_mex(settings.ToBytes, transmitElements.ToBytes, receiveElements.ToBytes, scatters.ToBytes);


vkTimes = vkStartTime + (0:(size(pulseEcho, 1)-1))/fs;

%% Plot

f1 = figure(); ax1 = axes(); p1 = plot(ax1, times*1e6,fullRF/sum(abs(fullRF)), '-', times*1e6, manRF/sum(abs(manRF)), '--', manVkTimes*1e6, manConvRf/sum(abs(manConvRf)), '-', vkTimes*1e6, pulseEcho/sum(abs(pulseEcho)), '--');
legend(ax1, "FieldII", "Manual Fraunhoffer", "Manual Fraounhoffer with Manual Convolution", "vkField")

for i = 1:numel(p1)
    p1(i).LineWidth = 4;
end

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
