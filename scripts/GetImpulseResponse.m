function impulseResponse = GetImpulseResponse(fc, fs)
    arguments
        fc(1,1) single
        fs(1,1) single
    end
    
    numberOfCycles = 1; % ~1-2 for broad-band transducer
    waveform = sin(2*pi*(0:1/fs:numberOfCycles/fc)*fc);
    impulseResponse = waveform.*hamming(numel(waveform))';
end