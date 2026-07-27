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

    % Vectorized over trials: pull the whole (1 x numel(js) x maxSpk x nSamp)
    % block in one indexing op, collapse everything but the sample axis into
    % rows (column-major reshape keeps nSamp as the trailing dimension, so no
    % permute is needed), then drop the NaN-padded rows once. No per-trial loop
    % or array growth.
    wf = reshape(waveform.waveform(r, js, :, :), [], nSamp);
    W  = wf(any(~isnan(wf), 2), :);
end
