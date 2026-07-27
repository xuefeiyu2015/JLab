function tc = gatherUnitSpikeTimes(spike, waveform, r)
% Per-trial spike times (seconds) for one unit (raster row r).
%
% Precise from the waveform product's waveform_time when a waveform is supplied,
% otherwise the 1 ms-quantised times of the binary raster. The spike-time analog
% of gatherUnitWaveforms; reusable for ISI, cross-correlation, PSTH, etc.
%
% Input:
%   spike    - online_spike product: .data (units x trials x bins), .timeseq
%              .relative_time (1 x bins, s from the aligned marker).
%   waveform - online_spike_waveform product (.waveform_time, units x trials x
%              maxSpk, s), or [] to force the raster fallback.
%   r        - raster row (unit) index.
%
% Output:
%   tc - 1 x nTrials cell; tc{j} is a row vector of that trial's spike times (s),
%        sorted ascending, in the raster's time frame.
%
% Xuefei Yu Jul 2026

    haveWave = ~isempty(waveform) && isfield(waveform, 'waveform_time');
    nTr      = size(spike.data, 2);
    relTime  = spike.timeseq.relative_time(:).';

    % Vectorized over trials: flatten the whole (trial x spike-slot) or
    % (trial x bin) block for this unit in one indexing op, find every spike at
    % once, sort by (trial, time) so each trial's spikes are grouped and in
    % ascending order, then split into the per-trial cell with mat2cell. No
    % per-trial loop, regardless of trial or spike count.
    if haveWave
        wt         = reshape(waveform.waveform_time(r, :, :), nTr, []);   % nTr x maxSpk
        mask       = ~isnan(wt);
        [trIdx, ~] = find(mask);
        vals       = wt(mask);
    else
        Rmat             = reshape(spike.data(r, :, :), nTr, []) == 1;    % nTr x nBins
        [trIdx, binIdx]  = find(Rmat);
        vals             = relTime(binIdx);
    end

    keys   = sortrows([trIdx, vals(:)]);
    counts = accumarray(keys(:,1), 1, [nTr, 1]);
    tc     = mat2cell(keys(:,2).', 1, counts(:).');
end
