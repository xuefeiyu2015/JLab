function [marker, win] = spikeBaselineWindow(T)
% Per-trial baseline window: the whole fixation period, from fixation onset to the
% next event (target onset or fixation offset).
%
% Returns the inputs AlignSpikeSequence / AverageFiringRateBetween consume, so a
% baseline firing rate is `AverageFiringRateBetween(AlignSpikeSequence(spike,
% marker, ...), win)`. Reusable wherever a fixation-locked baseline is needed.
%
% Input:
%   T - struct from alignSpikeTrials (needs .Start .fixAcq .fixOn .fixOff
%       .tgt1 .tgt2, all nTrials x 1 abs seconds).
%
% Output:
%   marker - nTrials x 1 ABSOLUTE fixation-onset time (Fixation_acquired, else
%            Fixation_point_on). NaN where there is no usable baseline.
%   win    - nTrials x 2 window [0, nextEvent-onset] relative to the marker; NaN
%            row where there is no baseline.
%
% Xuefei Yu Jul 2026

    nTr    = numel(T.Start);
    marker = T.fixAcq;
    useOn  = isnan(marker);
    marker(useOn) = T.fixOn(useOn);
    win = nan(nTr, 2);
    for j = 1:nTr
        onset = marker(j);
        if isnan(onset) || isnan(T.Start(j));  marker(j) = NaN;  continue;  end
        cand = [T.tgt1(j), T.tgt2(j), T.fixOff(j)];
        cand = cand(cand > onset & ~isnan(cand));
        if isempty(cand);  marker(j) = NaN;  continue;  end   % no next event
        win(j, :) = [0, min(cand) - onset];
    end
end
