function [Ws, idx] = sampleWaveformRows(W, n)
% Random row subsample of a [nSpikes x nSamp] waveform matrix.
%
% Caps how many waveforms are carried into drawing / PCA without touching the
% numbers computed from the full set: gather everything with
% gatherUnitWaveforms, compute features on it with extractWaveformFeatures, then
% pass the result through here for the display + PCA copy.
%
% Input:
%   W - [nSpikes x nSamp] waveforms (as returned by gatherUnitWaveforms).
%   n - how many rows to keep. [] / NaN / Inf, or n >= size(W,1), keeps every row
%       (no shuffling: W and idx come back in their original order).
%
% Output:
%   Ws  - [min(n, nSpikes) x nSamp] the selected waveforms.
%   idx - the selected row indices, so per-spike side data (e.g. spike times)
%         can be subset the same way.
%
% The draw comes from the global rng, so the sample is fresh on every call.
%
% Xuefei Yu Jul 2026

    nRow = size(W, 1);
    if isempty(n) || ~isfinite(n) || n >= nRow
        Ws  = W;
        idx = (1:nRow).';
        return
    end

    idx = randperm(nRow, max(floor(n), 0)).';
    Ws  = W(idx, :);
end
