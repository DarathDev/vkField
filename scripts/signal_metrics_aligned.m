function [metrics, actualAligned, referenceAligned, commonTimes] = signal_metrics_aligned( ...
    actual, actualTimes, reference, referenceTimes, samplingFrequency)
actualTimes = double(actualTimes(:));
referenceTimes = double(referenceTimes(:));
commonStart = min(actualTimes(1), referenceTimes(1));
commonEnd = max(actualTimes(end), referenceTimes(end));
commonTimes = (commonStart:1 / double(samplingFrequency):commonEnd)';
actualAligned = interp1(actualTimes, actual, commonTimes, 'linear', 0);
referenceAligned = interp1(referenceTimes, reference, commonTimes, 'linear', 0);
channelCount = min(size(actualAligned, 2), size(referenceAligned, 2));
actualAligned = actualAligned(:, 1:channelCount);
referenceAligned = referenceAligned(:, 1:channelCount);
metrics = signal_metrics(actualAligned, referenceAligned);
end
