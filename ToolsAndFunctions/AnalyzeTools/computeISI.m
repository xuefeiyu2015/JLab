function [isis, violRate] = computeISI(spikeTimesCell, violThresh)
% Within-trial inter-spike intervals and the short-interval violation rate.
%
% ISIs are taken within each trial only (never across a trial boundary), then
% concatenated. Reusable for ISI histograms and refractory-period QC.
%
% Input:
%   spikeTimesCell - cell array; each cell a vector of one trial's spike times (s).
%   violThresh     - (optional) violation threshold in seconds (default 1e-3).
%
% Output:
%   isis     - 1 x N row vector of all within-trial ISIs (s).
%   violRate - fraction of isis below violThresh (NaN when there are no ISIs).
%
% Xuefei Yu Jul 2026

    if nargin < 2 || isempty(violThresh);  violThresh = 1e-3;  end

    % Vectorized within-trial diff: flatten all trials with a trial-id tag, sort
    % by (trial, time) so each trial's spikes are contiguous and ascending, take
    % one global diff, then keep only the diffs that stay inside a trial (i.e.
    % where the trial id did not change). No per-trial loop or array growth.
    lens = cellfun(@numel, spikeTimesCell);
    if sum(lens) < 2
        isis = [];
    else
        allTm   = [spikeTimesCell{:}];
        trialId = repelem(1:numel(spikeTimesCell), lens);
        keys    = sortrows([trialId(:), allTm(:)]);
        d       = diff(keys(:,2));
        isis    = d(diff(keys(:,1)) == 0).';
    end

    if isempty(isis)
        violRate = NaN;
    else
        violRate = mean(isis < violThresh);
    end
end
