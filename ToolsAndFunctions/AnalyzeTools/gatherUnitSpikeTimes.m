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
    tc       = cell(1, nTr);

    for j = 1:nTr
        if haveWave
            wt = reshape(waveform.waveform_time(r, j, :), 1, []);
            tc{j} = sort(wt(~isnan(wt)));
        else
            rd = reshape(spike.data(r, j, :), 1, []);
            tc{j} = relTime(rd == 1);
        end
    end
end
