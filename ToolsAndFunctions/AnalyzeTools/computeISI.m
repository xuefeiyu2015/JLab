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

    isis = [];
    for j = 1:numel(spikeTimesCell)
        tm = sort(spikeTimesCell{j}(:).');
        if numel(tm) < 2;  continue;  end
        isis = [isis, diff(tm)]; %#ok<AGROW>
    end

    if isempty(isis)
        violRate = NaN;
    else
        violRate = mean(isis < violThresh);
    end
end
