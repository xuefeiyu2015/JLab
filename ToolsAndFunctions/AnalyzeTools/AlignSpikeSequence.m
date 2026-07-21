function aligned = AlignSpikeSequence(spike, alignMarker, timeWindow)
% Re-align a per-trial spike raster to a per-trial marker.
%
% The exported raster (online_spike) is left-aligned to each trial's Start marker;
% this shifts every trial so t = 0 falls on alignMarker instead, and returns the
% binary sequence on one common time axis. Reusable for PSTHs, event-locked
% rasters, and the QC baseline.
%
% Input:
%   spike       - online_spike-style struct:
%                   .data                    units x trials x bins (0/1, NaN-padded)
%                   .timeseq.relative_time   1 x bins, s from the Start marker
%                   .timeseq.alignedrawtime  trials x 1, abs Start time (s)
%                   .info.samplingrate       bin rate (Hz)
%                 (.info.Channel_Number / .Unit_No are carried through if present)
%   alignMarker - trials x 1 marker times in ABSOLUTE recording-clock seconds (the
%                 same clock as the trials-table markers). A scalar is broadcast to
%                 all trials. NaN -> that trial's output is all-NaN.
%   timeWindow  - [tPre tPost] in seconds relative to the marker. Omitted or []
%                 spans the full aligned range across all trials (NaN-padded).
%
% Output:
%   aligned     - struct:
%                   .data         units x trials x newBins (0/1, NaN-padded)
%                   .time         1 x newBins, seconds from the marker
%                   .info         .samplingrate (+ Channel_Number/Unit_No if given)
%                   .alignMarker  the markers used (trials x 1, abs s)
%
% Nearest-bin resampling maps each output sample to the closest source bin, so the
% marker offset (not generally an integer number of bins) shifts the sequence by at
% most half a bin while keeping it binary.
%
% Xuefei Yu Jul 2026

    if nargin < 3;  timeWindow = [];  end

    data    = spike.data;
    relTime = spike.timeseq.relative_time(:).';        % 1 x bins, s from Start
    rawStart = spike.timeseq.alignedrawtime(:);        % trials x 1, abs Start (s)
    fs      = spike.info.samplingrate;
    binW    = 1 / fs;

    [nUnit, nTr, ~] = size(data);

    alignMarker = alignMarker(:);
    if isscalar(alignMarker);  alignMarker = repmat(alignMarker, nTr, 1);  end

    % Marker in the raster's Start frame (s from Start), per trial.
    mRel  = alignMarker - rawStart;                    % trials x 1
    valid = ~isnan(mRel);

    % --- output time grid (integer bins from the marker) ------------------
    if ~isempty(timeWindow)
        kmin = round(timeWindow(1) / binW);
        kmax = round(timeWindow(2) / binW);
    elseif any(valid)
        % Full span: earliest and latest source time re-expressed from the marker.
        kmin = floor((relTime(1)   - max(mRel(valid))) / binW);
        kmax = ceil( (relTime(end) - min(mRel(valid))) / binW);
    else
        kmin = 0;  kmax = 0;
    end
    kgrid   = kmin:kmax;
    newTime = kgrid * binW;                            % 1 x newBins, s from marker
    newBins = numel(newTime);

    out = nan(nUnit, nTr, newBins);
    t0  = relTime(1);
    for j = 1:nTr
        if ~valid(j);  continue;  end
        % Source-bin index for each output sample (nearest bin).
        srcIdx = round((newTime + mRel(j) - t0) / binW) + 1;   % 1 x newBins
        ok     = srcIdx >= 1 & srcIdx <= size(data, 3);
        if ~any(ok);  continue;  end
        out(:, j, ok) = data(:, j, srcIdx(ok));       % NaN source stays NaN
    end

    aligned = struct();
    aligned.data = out;
    aligned.time = newTime;
    aligned.info.samplingrate = fs;
    if isfield(spike, 'info') && isfield(spike.info, 'Channel_Number')
        aligned.info.Channel_Number = spike.info.Channel_Number;
    end
    if isfield(spike, 'info') && isfield(spike.info, 'Unit_No')
        aligned.info.Unit_No = spike.info.Unit_No;
    end
    aligned.alignMarker = alignMarker;
end
