function [rate, count, dur] = AverageFiringRateBetween(seq, window)
% Average firing rate of a per-trial binary spike raster over a time window.
%
% Works on either an aligned sequence (from AlignSpikeSequence, which carries a
% .time axis) or a raw online_spike product (whose time axis is
% .timeseq.relative_time). The window is given in that same time frame.
%
% Input:
%   seq     - struct with:
%               .data                     units x trials x bins (0/1, NaN-padded)
%               .time OR .timeseq.relative_time   1 x bins time axis (s)
%               .info.samplingrate        bin rate (Hz)
%   window  - [t0 t1] applied to every trial, OR a trials x 2 per-trial window, in
%             seq's time frame. A NaN row (or t1<=t0) yields NaN for that trial.
%
% Output (all units x trials):
%   rate    - spikes per second, count ./ dur
%   count   - spikes counted in the window
%   dur     - observed duration = (# non-NaN source bins in the window) * binWidth,
%             so a window spilling past a trial's recorded range is not over-counted
%
% Xuefei Yu Jul 2026

    data = seq.data;
    %
    if isfield(seq, 'time')
        tvec = seq.time(:).';
        disp('Use the raw time');
    else
        tvec = seq.timeseq.relative_time(:).';
        disp('Calculate based on the relative time');
    end
   
    
    binW = 1 / seq.info.samplingrate;

    [nUnit, nTr, ~] = size(data);

    % Broadcast a single window to every trial.
    if size(window, 1) == 1
        window = repmat(window, nTr, 1);
    end

    count = nan(nUnit, nTr);
    dur   = nan(nUnit, nTr);
    for j = 1:nTr
        w = window(j, :);
        if any(isnan(w)) || w(2) <= w(1);  continue;  end
        sel = tvec >= w(1) & tvec < w(2);
        if ~any(sel);  continue;  end
        slice = data(:, j, sel);                        % units x 1 x nSel
        count(:, j) = sum(slice == 1, 3);               % NaN treated as not-a-spike
        % Observed time: bins that actually carry data (non-NaN) for this trial.
        validBins = squeeze(sum(~isnan(slice), 3));     % units x 1
        dur(:, j) = validBins * binW;
    end

    dur(dur == 0) = NaN;
    rate = count ./ dur;
end
