function W = gatherUnitWaveforms(waveform, T, r, trialMask)
% Every in-window spike waveform of one unit (raster row r) from the selected
% trials, as [nSpikes x nSamp] with the NaN-padded spikes dropped.
%
% Reusable feeder for extractWaveformFeatures / spikeWaveformPCA.
%
% Input:
%   waveform  - online_spike_waveform product: .waveform (units x trials x maxSpk
%               x nSamp, uV, NaN-padded).
%   T         - struct from SpikeTrialAlignmentCheck (uses .valid to skip unmatched trials).
%   r         - raster row (unit) index.
%   trialMask - logical / index over trials selecting which trials to gather.
%
% Output:
%   W - [nSpikes x nSamp] waveforms (uV); empty [0 x nSamp] when none.
%
% Xuefei Yu Jul 2026

    nSamp = size(waveform.waveform, 4);
    js    = find(trialMask(:).' & T.valid(:).');
    W     = zeros(0, nSamp);
    for j = js
        wf   = reshape(waveform.waveform(r, j, :, :), [], nSamp);  % maxSpk x nSamp
        keep = any(~isnan(wf), 2);
        W    = [W; wf(keep, :)]; %#ok<AGROW>
    end
end
