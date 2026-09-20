function metrics = signal_metrics(actual, reference)
difference = actual - reference;
referenceNorm = norm(reference(:));
actualNorm = norm(actual(:));
referencePeak = max(abs(reference), [], 'all');
actualPeak = max(abs(actual), [], 'all');
referenceEnergy = mean(reference.^2, 'all');
differenceEnergy = mean(difference.^2, 'all');

maxDiff = max(abs(difference), [], 'all');
metrics.maxRelativeDifference = (maxDiff / max(referencePeak, eps('double'))) * 100;
metrics.differenceEnergyRatio = differenceEnergy / max(referenceEnergy, eps('double'));
metrics.relativeL2 = norm(difference(:)) / max(referenceNorm, eps('double'));
metrics.rmsErrorPercent = metrics.relativeL2 * 100;
metrics.peakRatio = actualPeak / max(referencePeak, eps('double'));
if actualNorm == 0 || referenceNorm == 0
    metrics.correlation = 0;
else
    metrics.correlation = dot(actual(:), reference(:)) / (actualNorm * referenceNorm);
end
end
