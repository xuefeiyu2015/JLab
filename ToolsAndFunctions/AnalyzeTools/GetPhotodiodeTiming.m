function PDTiming = GetPhotodiodeTiming(photodiode_data, comments_data, plotFlag, plotN, savePath, reCompute, varargin)
% Derive the real visual onset/offset times of the fixation point, target 1
% and target 2 from the photodiode signal, and compare them against the
% self-reported timestamps already stored in the trials/comments table.
%
% Each channel has its own onset-marker comments column (fixation ->
% Fixation_point_on, target1 -> Target_1_presented, target2 ->
% Target_2_presented). Onset and offset are detected TOGETHER, as a pair, in
% a single pass over one aligned array: re-align all 3 channels to their own
% onset marker via ONE combined AlignContinuous call (ToolsAndFunctions/
% AnalyzeTools/AlignContinuous.m -- a generic per-trial marker-aligner for
% any continuous export product sharing the .data/.timeseq contract, reused
% as-is here rather than hand-rolling the same marker-shift math again;
% accepts a DIFFERENT marker per channel in one call, e.g. fixation's own
% Fixation_point_on alongside target1's Target_1_presented, which is what
% lets the whole detection be a single call instead of one per channel --
% see that file for why, and why nearest-sample re-indexing, not
% interpolation, is the right resampling choice for a step signal), then:
%   * ONSET  = the first run of NContig samples crossing threshold AWAY from
%              baseline, inside a tight window around the marker;
%   * OFFSET = the first run of NContig samples crossing back TOWARD
%              baseline at any point AFTER that trial's own onset.
% Baseline mean/SD comes from a window before the onset marker, and the SAME
% threshold (an absolute voltage level, not time-dependent) defines both
% ends, since it is physically the same baseline/on-state boundary either
% way. The onset half mirrors how CalculateRT's detectSaccade anchors its
% search to a behavioral marker (approxRT) rather than scanning the whole
% trial; the offset half needs no marker at all, which is the point -- it
% simply follows the trace forward until it comes back.
%
% Detecting offset by following the trace rather than by anchoring it to an
% offset comment field (the earlier design here) matters because that field
% coverage is uneven (see the coverage note below): a trial where none of the
% candidates is populated used to get no offset at all. Verified against a
% real session, the paired search reproduces the marker-anchored answer where
% both exist (agreement within 2 ms on 99.8-100% of shared trials, median
% difference 0.00 ms) and additionally resolves the ~8% of target trials that
% have NO offset marker populated -- aborted trials the stimulus PC never
% logged an off event for, whose recovered on-durations (median ~330 ms vs
% ~539 ms for complete trials) are exactly the truncated stimuli you would
% expect. Taking the FIRST return crossing after onset is what makes the wide
% forward search safe: extending the window can only add strictly-later
% candidates, so it can never corrupt a correct answer, only turn a NaN into
% a real detection.
%
% FIXATION IS THE ONE EXCEPTION. Fixation can hold for up to ~6.5 s on this
% task, far past any affordable forward-search span, so its offset keeps a
% marker anchor: one small extra pull around Fixation_point_off (populated on
% ~100% of fixation-onset trials), searched with the threshold ALREADY
% computed from the onset pull -- deliberately not re-baselined at the offset
% marker, since the period just before an offset is the stimulus-ON level,
% not the true baseline. Where Fixation_point_off is missing, the paired
% forward-search result is used instead, so coverage is never worse than
% either method alone.
%
% Polarity is detected automatically per channel (default 'auto'), not
% hand-set: for each channel, the mean level shortly after the onset marker
% (0.05 s to OnsetSearchWindow(2)) is compared to the baseline mean across
% every valid trial -- if it's lower, the channel is falling (baseline high,
% drops when the stimulus appears); if higher, rising. On the real session
% this was verified against, all 3 channels come out falling (a large, clean
% baseline-to-low step lining up with FixOn/T1on/T2on -> TargsOff), but
% nothing here assumes that in general. Pass 'Polarity','falling' or
% 'rising' to force a direction instead (e.g. if a channel is too noisy for
% the auto comparison to be reliable).
%
%   photodiode_data - photodiode export product (photodiode_matlab.mat):
%                       .data (3 x nTrials x maxSamples, single, raw uV,
%                              channel order is fixation/target1/target2 by
%                              default -- see ChannelMap below)
%                       .timeseq.relative_time  (1 x maxSamples, s; 0 at Start)
%                       .timeseq.alignedrawtime (nTrials x 1, s; absolute Start)
%                       .info.Session, .info.Trial_number (nTrials x 1)
%   comments_data   - table of parsed trials (1:1 with dim 2 of .data, same
%                      guarantee CalculateRT relies on for eye data -- both
%                      the photodiode export and comments_data are built
%                      from the same per-trial Start-anchored segmentation).
%                      Needs Task, Fixation_point_on/off, Target_1_presented,
%                      Target_1_off, Target_2_presented, Targets_off,
%                      Requested_target_2_time_offset.
%   plotFlag        - true to draw the QC figures (default true). Two windows
%                      are drawn: the combined QC figure, and a second
%                      "outliers" window showing the worst-discrepancy trials
%                      (see NWorst below; set NWorst=0 to suppress it).
%   plotN           - number of trials drawn per raw-trace panel of the main
%                      figure, randomly sampled from trials with a detected
%                      onset (default 30).
%   savePath        - (optional) session export folder. When set, the
%                      per-trial table is written to
%                      <savePath>/AnalysisCache/PhotodiodeTiming.csv (the
%                      lightweight, always-available product); the full plot
%                      payload is cached to
%                      <savePath>/AnalysisCache/PhotodiodeTiming.mat only on
%                      the plot path, since only the QC figure needs it.
%                      '' disables all caching/export.
%   reCompute       - (optional, default true) when true, recompute and
%                      refresh the cache. When false, reuse the cached
%                      result (CSV on the return-only path, MAT on the plot
%                      path) without recomputing.
%   varargin        - (optional) name/value detection-tuning overrides:
%                       'BaselineWindow' : [lo hi] s relative to the onset
%                                          marker (default [-0.2 -0.02]) --
%                                          the quiet period right before
%                                          that specific event.
%                       'SearchWindow'   : [lo hi] s relative to the marker
%                                          being searched around (default
%                                          [-0.05 0.3]) -- used for the onset
%                                          search (around each channel's
%                                          onset marker) and for the
%                                          fixation-offset search (around
%                                          Fixation_point_off): slightly
%                                          before the marker, in case the
%                                          true physical transition precedes
%                                          the logged comment timestamp,
%                                          through 300 ms after.
%                       'OffsetSearchSpan': how far after onset (s) the
%                                          paired forward search keeps
%                                          looking for the return crossing
%                                          (default 2). Only needs to exceed
%                                          the longest real on-duration being
%                                          measured this way -- targets stay
%                                          on <= 0.59 s on this task, so the
%                                          default leaves ~3x headroom.
%                                          Fixation does not use this (see
%                                          above).
%                       'PlotWindow'     : [lo hi] s relative to the onset
%                                          marker, cropping Band 1's ONSET
%                                          row (default [-0.3 0.5] -- it only
%                                          has to cover the onset step now
%                                          that offset has its own row).
%                                          Cosmetic only: it never shrinks
%                                          detection, which always gets at
%                                          least SearchWindow/OffsetSearchSpan
%                                          (the single pull below spans the
%                                          UNION of the two, so widening this
%                                          costs nothing extra and narrowing
%                                          it does not weaken detection).
%                       'OffsetPlotWindow': [lo hi] s relative to the offset
%                                          marker, for Band 1's OFFSET row
%                                          (default [-0.5 0.3] -- the tail of
%                                          the on-period leading into the
%                                          return step). Cosmetic only, and
%                                          backed by its own small pull, since
%                                          fixation offsets sit too far past
%                                          onset to re-slice from the onset
%                                          pull.
%                       'NWorst'         : trials per panel in the second
%                                          ("outliers") figure -- the ones
%                                          with the largest |photodiode -
%                                          comments| discrepancy, ranked per
%                                          panel by that panel's own error
%                                          field (default 20). 0 suppresses
%                                          that figure entirely. Render-only:
%                                          unlike plotN this never enters the
%                                          cached payload.
%                       'NSD'            : SD multiple above/below baseline
%                                          that defines the threshold
%                                          (default 3).
%                       'NContig'        : consecutive samples the threshold
%                                          crossing must be sustained for
%                                          (default 5).
%                       'ChannelMap'     : [fixation target1 target2] row
%                                          indices into photodiode_data.data
%                                          (default [1 2 3]). Only inferred
%                                          from the export metadata naming,
%                                          not stated explicitly anywhere in
%                                          the loader -- override here if a
%                                          future rig wires the channels
%                                          differently.
%                       'SuccessOutcomes': Trialoutcome values that count as
%                                          successful, i.e. as trials that ran
%                                          to completion with a choice made
%                                          (default {'correct','wrong'} -- the
%                                          same pair CalculateRT.m treats as
%                                          valid). A wrong-choice trial had its
%                                          stimuli presented normally; only the
%                                          monkey's choice differed, so its
%                                          display timing is just as valid a
%                                          measurement as a correct trial's.
%                                          BOTH figures draw only these trials
%                                          -- the sampled example traces, the
%                                          error histograms, the interval
%                                          scatters and the outlier ranking --
%                                          because aborted trials (broke
%                                          fixation, timeout) carry markers the
%                                          stimulus PC logged for a truncated
%                                          presentation, which dominate the
%                                          error tails without saying anything
%                                          about display timing. Render-only:
%                                          PDTiming, the CSV and the cached
%                                          payload always stay full-coverage,
%                                          so this can be changed on a cache
%                                          hit with no recompute. Pass
%                                          {'correct'} to narrow to correct
%                                          trials, or the full outcome list to
%                                          disable the restriction.
%                       'Polarity'       : 'auto' (default) | 'falling' |
%                                          'rising' -- direction of the step
%                                          at onset (falling = baseline high,
%                                          drops when the stimulus appears;
%                                          rising = baseline low, rises when
%                                          the stimulus appears). 'auto'
%                                          detects this per channel from the
%                                          data itself (see above); 'falling'
%                                          / 'rising' force that direction
%                                          for all channels. Offset always
%                                          crosses back the other way.
%
% Returns PDTiming, an nTrials x 8 table (one row per trial in
% comments_data, in order): Session, Trial_number, FixationOnsetPD,
% FixationOffsetPD, Target1OnsetPD, Target1OffsetPD, Target2OnsetPD,
% Target2OffsetPD (all absolute seconds, directly comparable to the
% comments-table event columns; NaN where undetected). The PD suffix keeps
% them distinguishable from the comments-side markers once a caller merges the
% two tables side by side.
%
% Note on offset-marker coverage (verified against a real session): there is
% no dedicated "Target 2 off" comment field in this codebase at all, and which
% field reports target 1's off time is TASK-DEPENDENT -- not a fallback chain:
%   * saccade tasks (memory / visual) extinguish target 1 on its own, reported
%     in Target_1_off (populated on ~96% of target-1-onset trials; the rest are
%     broke-fixation trials the stimulus PC never logged an off event for).
%     Targets_off exists on ~100% of those trials too, but it marks the END OF
%     THE TRIAL, a median ~1.65 s later -- a genuinely different event, so it
%     must never stand in for target 1's offset here.
%   * the time-delay task extinguishes both targets together and reports only
%     Targets_off (Target_1_off is never populated there -- 0% on the verified
%     session); that one marker is target 1's AND target 2's real offset.
% Fixation_point_off is populated for ~100% of fixation-onset trials and is
% fixation's reference in every task. Detection no longer depends on any of
% this for the target channels (that is the point of the paired search above),
% but the Band-2 timing-error comparison and the Band-1 offset-panel alignment
% still do -- see offsetRefTimes for the per-task mapping.
% Requested_target_2_time_offset is stored in milliseconds and is converted
% to seconds before comparison against photodiode-derived intervals.
%
% This is a standalone QC product: PDTiming is not merged into
% data.comments/extendComments and does not change the TaskRouter data
% contract -- callers that want the corrected timestamps downstream must do
% that merge themselves.
%
% Note on performance: computePhotodiodeTimingPayload contains no per-trial
% loop at all. Two things make that possible.
%   1. ONE AlignContinuous pull spans the UNION of the detection and plot
%      windows, and is then reused for baseline, polarity, threshold, onset,
%      target offsets AND Band-1 plotting. With the default windows that
%      union is exactly PlotWindow, so this single pull replaces what used to
%      be a separate onset pull, one pull per offset-priority level, and a
%      plot pull. Only fixation's marker-anchored offset needs a second
%      (much smaller) pull.
%   2. firstRunVectorized finds "first run of NContig consecutive samples
%      past threshold" for every (channel, trial) at once with a cummax
%      reset-counter, replacing the old nested per-(trial, channel) loop.
%      Its per-row lower bound is what lets each trial's offset search start
%      at that trial's own onset without a loop.
% Measured on a real session (4575 trials, 3 channels, 1 kHz): ~1.9x faster
% end to end than the per-trial-loop, multi-pull version it replaces, with
% bitwise-identical onsets. Two incidental wins found while profiling and
% kept here: skipping the chanMap copy of .data when ChannelMap is already
% [1 2 3] (that copy alone measured ~135 ms), and never slicing a single
% channel out of the raw array (a NaN marker column costs a fraction of it).
%
% Xuefei Yu Jul 2026

    if nargin < 3 || isempty(plotFlag);   plotFlag  = true; end
    if nargin < 4 || isempty(plotN);      plotN     = 30;    end
    if nargin < 5;                        savePath  = '';    end
    if nargin < 6 || isempty(reCompute);  reCompute = true;  end

    p = inputParser;
    p.addParameter('BaselineWindow', [-0.2 -0.02], ...
        @(v) isnumeric(v) && numel(v) == 2 && v(1) < v(2));
    p.addParameter('SearchWindow', [-0.05 0.3], ...
        @(v) isnumeric(v) && numel(v) == 2 && v(1) < v(2));
    p.addParameter('OffsetSearchSpan', 2, ...
        @(v) isnumeric(v) && isscalar(v) && v > 0);
    p.addParameter('PlotWindow', [-0.3 0.5], ...
        @(v) isnumeric(v) && numel(v) == 2 && v(1) < v(2));
    p.addParameter('OffsetPlotWindow', [-0.5 0.3], ...
        @(v) isnumeric(v) && numel(v) == 2 && v(1) < v(2));
    p.addParameter('NWorst', 20, @(v) isnumeric(v) && isscalar(v) && v >= 0);
    p.addParameter('NSD', 3, @(v) isnumeric(v) && isscalar(v) && v > 0);
    p.addParameter('NContig', 5, @(v) isnumeric(v) && isscalar(v) && v >= 1);
    p.addParameter('ChannelMap', [1 2 3], @(v) isnumeric(v) && numel(v) == 3);
    p.addParameter('Polarity', 'auto', @(s) any(strcmpi(s, {'auto', 'falling', 'rising'})));
    p.addParameter('SuccessOutcomes', {'correct', 'wrong'}, ...
        @(v) ischar(v) || isstring(v) || iscellstr(v));
    p.parse(varargin{:});
    baseWin   = p.Results.BaselineWindow;
    searchWin = p.Results.SearchWindow;
    offSpan   = p.Results.OffsetSearchSpan;
    plotWin   = p.Results.PlotWindow;
    offPlotWin = p.Results.OffsetPlotWindow;
    nWorst    = p.Results.NWorst;
    nSD       = p.Results.NSD;
    nContig   = p.Results.NContig;
    chanMap   = p.Results.ChannelMap;
    polarity  = lower(p.Results.Polarity);
    successOutcomes = cellstr(p.Results.SuccessOutcomes);

    if plotFlag
        % Plot path: the QC figure needs the full payload (raw traces,
        % per-trial/per-channel timing), so compute-or-load it from the
        % PhotodiodeTiming.mat cache and render from it, so the figure looks
        % identical on the compute and cache paths.
        payload = getCachedPayload(savePath, 'PhotodiodeTiming', reCompute, ...
            @() computePhotodiodeTimingPayload(photodiode_data, comments_data, ...
                baseWin, searchWin, offSpan, plotWin, offPlotWin, nSD, nContig, chanMap, polarity));
        PDTiming = payload.PDTiming;
        exportPDTimingTable(PDTiming, savePath);      % refresh the lightweight CSV
        if payload.hasTrace
            % SuccessOutcomes is applied HERE, at draw time, not folded into
            % the cached payload -- the payload carries the raw per-trial
            % outcome labels the same way it carries taskLabels, so changing
            % which outcomes count re-renders straight off a cache hit instead
            % of forcing a recompute.
            plotPhotodiodeTimingFigure(payload, plotN, successOutcomes);
            if nWorst > 0
                % Second window: the same 2x3 panel shape, but showing the
                % WORST-discrepancy trials instead of a random sample. Reads
                % only fields the payload already carries, so it costs no
                % recompute and works identically on a cache hit.
                plotPhotodiodeOutlierFigure(payload, nWorst, successOutcomes);
            end
        else
            warning('GetPhotodiodeTiming:NoTrace', ...
                'No onset/offset detected on any channel; skipping figure.');
        end
    else
        % Return-only path: never touch the heavy PhotodiodeTiming.mat.
        % Reuse the small CSV when allowed, otherwise recompute and refresh it.
        csvFile = pdCsvPath(savePath);
        if ~reCompute && ~isempty(csvFile) && exist(csvFile, 'file')
            PDTiming = readtable(csvFile);
        else
            payload = computePhotodiodeTimingPayload(photodiode_data, comments_data, ...
                baseWin, searchWin, offSpan, plotWin, offPlotWin, nSD, nContig, chanMap, polarity);
            PDTiming = payload.PDTiming;
            exportPDTimingTable(PDTiming, savePath);
        end
    end
end


function csvFile = pdCsvPath(savePath)
% Path of the per-trial PDTiming table export, or '' when caching is disabled.
    csvFile = '';
    if ~isempty(savePath)
        csvFile = fullfile(char(savePath), 'AnalysisCache', 'PhotodiodeTiming.csv');
    end
end


function exportPDTimingTable(PDTiming, savePath)
% Write the per-trial PDTiming table to
% <savePath>/AnalysisCache/PhotodiodeTiming.csv (no-op when savePath is
% empty). This is the lightweight product read back by the return-only path.
    csvFile = pdCsvPath(savePath);
    if isempty(csvFile);  return;  end
    cacheDir = fileparts(csvFile);
    if ~exist(cacheDir, 'dir');  mkdir(cacheDir);  end
    writetable(PDTiming, csvFile);
end


% =========================================================================
% Computation subfunctions (pure)
% =========================================================================

function payload = computePhotodiodeTimingPayload(photodiode_data, comments_data, baseWin, searchWin, offSpan, plotWin, offPlotWin, nSD, nContig, chanMap, polarity)
% Pure compute: detect fixation/target1/target2 onset & offset from the raw
% photodiode traces, then compare against the comments-table timestamps.
% Bundles everything the QC figure needs so a cache hit never re-touches the
% raw photodiode export.

    alignedOK = isequal(photodiode_data.info.Session(:),      comments_data.Session(:)) && ...
                isequal(photodiode_data.info.Trial_number(:), comments_data.Trial_number(:));
    if ~alignedOK
        warning('GetPhotodiodeTiming:RowMismatch', ...
            ['photodiode.info.Session/Trial_number does not match comments_data ' ...
             'row-for-row; trial indexing below assumes it does (the same ' ...
             'positional guarantee CalculateRT.m relies on for eye data). ' ...
             'Check the export.']);
    end

    nTrials = height(comments_data);
    nChan   = numel(chanMap);
    % fixation/target1/target2 role order -- fixed regardless of ChannelMap,
    % which only reorders which physical .data row plays each role.
    onsetMarkerCols  = {'Fixation_point_on', 'Target_1_presented', 'Target_2_presented'};

    % Single pull window: the UNION of everything anyone needs off this
    % array -- baseline, the onset search, the paired forward offset search,
    % and Band-1 plotting. With the default parameters this evaluates to
    % exactly PlotWindow, so the one pull below does all four jobs.
    alignWin = [min(baseWin(1), plotWin(1)), max([searchWin(2), plotWin(2), offSpan])];

    % All 3 channels at once -- every AlignContinuous call below covers all
    % channels in one go (a per-channel nTrials x nChan marker matrix, not a
    % per-channel loop of single-marker calls), since AlignContinuous accepts
    % a different marker per channel directly; measured ~34% faster than
    % looping externally, with bitwise-identical output (see AlignContinuous.m).
    % When ChannelMap is already the identity there is nothing to reorder, so
    % skip the indexed copy entirely -- on a real session .data is ~520 MB and
    % that copy alone measured ~135 ms, roughly a third of the old runtime.
    if isequal(chanMap(:).', 1:nChan) && size(photodiode_data.data, 1) == nChan
        chanAll = photodiode_data;      % identity map AND no extra rows: nothing to select
    else
        chanAll = struct('data', photodiode_data.data(chanMap, :, :), ...
            'timeseq', photodiode_data.timeseq, 'info', photodiode_data.info);
    end

    markerAbs = nan(nTrials, nChan);
    for c = 1:nChan
        if ismember(onsetMarkerCols{c}, comments_data.Properties.VariableNames)
            markerAbs(:, c) = comments_data.(onsetMarkerCols{c});
        end
    end

    % ---- the one pull: all channels, each anchored to its own onset marker ----
    alignedOn = AlignContinuous(chanAll, markerAbs, alignWin);   % nChan x nTrials x nSampOn
    tOn       = alignedOn.time;
    nSampOn   = numel(tOn);

    baseMask  = tOn >= baseWin(1) & tOn <= baseWin(2);
    base_mean = mean(alignedOn.data(:, :, baseMask), 3, 'omitnan');    % nChan x nTrials
    base_sd   = std(alignedOn.data(:, :, baseMask), 0, 3, 'omitnan');  % nChan x nTrials

    % Polarity: auto-detected per channel from the data (compare the mean
    % level shortly after the marker, once the transition has had time to
    % complete, to the baseline mean, pooled over every valid trial via the
    % median so a few noisy trials can't flip the call), or the
    % caller-forced direction for every channel.
    if strcmp(polarity, 'auto')
        postMask    = tOn > 0.05 & tOn <= 0.1;
        post_mean   = mean(alignedOn.data(:, :, postMask), 3, 'omitnan');   % nChan x nTrials
        chanFalling = median(post_mean - base_mean, 2, 'omitnan') < 0;      % nChan x 1
    else
        chanFalling = repmat(strcmp(polarity, 'falling'), nChan, 1);        % nChan x 1
    end
    thrSign = ones(nChan, 1);  thrSign(chanFalling) = -1;                   % -1 falling, +1 rising
    thrAll  = base_mean + thrSign .* (nSD * base_sd);                       % nChan x nTrials
    polarityUsed = cell(1, nChan);
    for c = 1:nChan
        polarityUsed{c} = 'rising';
        if chanFalling(c);  polarityUsed{c} = 'falling';  end
    end

    % ---- ONSET: first run away from baseline, inside the tight search
    % window around each channel's own onset marker. The mask is built over
    % only the onset sub-range, not the whole (much wider) pull, so widening
    % the pull for the offset search costs the onset search nothing.
    onLo = find(tOn >= searchWin(1), 1, 'first');
    onHi = find(tOn <= searchWin(2), 1, 'last');
    onsetIdx = nan(nChan, nTrials);
    if ~isempty(onLo) && ~isempty(onHi) && onHi >= onLo
        awayMask = crossingMask(alignedOn.data(:, :, 1:onHi), thrAll, chanFalling, 'away');
        onsetIdx = firstRunVectorized(awayMask, nContig, onLo, onHi);      % nChan x nTrials
        clear awayMask
    end

    % ---- OFFSET (paired): first run back toward baseline anywhere AFTER
    % this trial's own onset -- no offset marker consulted. The per-row lower
    % bound is what makes "after its own onset" a single vectorized search
    % instead of a per-trial loop; a NaN onset propagates to a NaN offset on
    % its own, since firstRunVectorized treats a NaN bound as "disabled".
    backMask  = crossingMask(alignedOn.data, thrAll, chanFalling, 'back');
    offsetIdx = firstRunVectorized(backMask, nContig, onsetIdx + nContig, nSampOn);
    clear backMask

    onsetAbs  = markerAbs + idxToRelTime(onsetIdx,  tOn).';
    offsetAbs = markerAbs + idxToRelTime(offsetIdx, tOn).';

    % ---- FIXATION OFFSET: marker-anchored override. Fixation can hold far
    % longer than OffsetSearchSpan, so the paired search above misses many of
    % them; anchor to Fixation_point_off instead and reuse the threshold
    % already computed above (do NOT re-baseline at the offset marker -- the
    % period before an offset is the stimulus-ON level, not baseline). The
    % forward-search result stands wherever that marker is missing, so
    % coverage is never worse than either method alone. Channels 2/3 get a
    % NaN marker rather than slicing channel 1 out of chanAll: that slice
    % would copy the full-length raw channel (hundreds of MB), while a NaN
    % marker column only costs its share of the (small) aligned output.
    if ismember('Fixation_point_off', comments_data.Properties.VariableNames)
        fixMarkerAbs = comments_data.Fixation_point_off;
        fixMarkerMat = nan(nTrials, nChan);  fixMarkerMat(:, 1) = fixMarkerAbs;
        alignedFix   = AlignContinuous(chanAll, fixMarkerMat, searchWin);

        backMaskFix = crossingMask(alignedFix.data, thrAll, chanFalling, 'back');
        fixOffIdx   = firstRunVectorized(backMaskFix, nContig, 1, size(alignedFix.data, 3));
        fixOffRel   = idxToRelTime(fixOffIdx, alignedFix.time).';        % nTrials x nChan
        fixOffAbs   = fixMarkerAbs + fixOffRel(:, 1);
        useMarker   = ~isnan(fixOffAbs);
        offsetAbs(useMarker, 1) = fixOffAbs(useMarker);
        clear backMaskFix alignedFix
    end

    % ---- Band-1 ROW A (onset panels): the same pull, cropped to PlotWindow.
    % Since onset and offset now get separate panels, PlotWindow only has to
    % cover the onset step itself, not the whole on-period -- so this crop is
    % what keeps the cached payload small even though the pull behind it still
    % spans OffsetSearchSpan for detection.
    if alignWin(1) == plotWin(1) && alignWin(2) == plotWin(2)
        plotData = alignedOn.data;      % nChan x nTrials x nPlotSamp
        plotTime = tOn;
    else
        keepPlot = tOn >= plotWin(1) & tOn <= plotWin(2);
        plotData = alignedOn.data(:, :, keepPlot);
        plotTime = tOn(keepPlot);
    end
    clear alignedOn

    % ---- Band-1 ROW B (offset panels): a second pull, anchored to each
    % channel's comments OFFSET marker, so the detected-offset dots cluster
    % near the real latency instead of scattering across the panel by
    % on-duration. This genuinely needs its own pull rather than a re-slice of
    % the onset-aligned data: fixation offsets sit at a median ~2.28 s (p99
    % ~5.2 s) after onset, past where the onset-anchored pull ends.
    offRefAbs   = offsetRefTimes(comments_data, nChan);      % nTrials x nChan
    alignedOff  = AlignContinuous(chanAll, offRefAbs, offPlotWin);
    plotDataOff = alignedOff.data;
    plotTimeOff = alignedOff.time;
    clear alignedOff

    % Onset/offset relative to each trial's own onset marker (row A) and to
    % its offset marker (row B). Row A: onset lands near 0, offset can be far
    % past the crop. Row B: offset lands near 0 (+ the ~41-45 ms latency),
    % onset is far before it. Each row draws whichever dots fall in view.
    onsetRel     = onsetAbs  - markerAbs;
    offsetRel    = offsetAbs - markerAbs;
    onsetRelOff  = onsetAbs  - offRefAbs;
    offsetRelOff = offsetAbs - offRefAbs;


    % Debug
    % For some brokefixation trials, the fixationoff markers  unreliable.
    % The target onset delay is longer for memory saccade task compared to
    % time delay task
   %{
     TrialsCheck = find(onsetRel(:,2)>0.03);
    Trial =  TrialsCheck(1);
     
    disp(comments_data(TrialsCheck ,:));

    rawtrace_offset = squeeze(plotDataOff(:,Trial,:));
    rawtrace_onset = squeeze(plotData(:,Trial,:));
    onsetRel_trial = onsetRel(Trial,:);
    offsetRel_trial = offsetRelOff(Trial,:);

   

    figure
    subplot(2,3,1)
    plot(plotTime,rawtrace_onset(1,:),'-k')
    hold on
    if ~isnan(onsetRel_trial(1))
    plot(onsetRel_trial(1),rawtrace_onset(1,round((onsetRel_trial(1)-plotTime(1))*1000)),'or')
    end
    hold on 
    plot([0,0],[min(rawtrace_onset(1,:)),max(rawtrace_onset(1,:))],'--k');
    title(sprintf('fix on diff %f',onsetRel_trial(1)*1000));

    subplot(2,3,2)
    plot(plotTime,rawtrace_onset(2,:),'-k')
    hold on
    if ~isnan(onsetRel_trial(2))
        plot(onsetRel_trial(2),rawtrace_onset(2,round((onsetRel_trial(2)-plotTime(1))*1000)),'or')
    end
    hold on 
    plot([0,0],[min(rawtrace_onset(2,:)),max(rawtrace_onset(2,:))],'--k');
    title(sprintf('target1on diff %f',onsetRel_trial(2)*1000));

    subplot(2,3,3)
    plot(plotTime,rawtrace_onset(3,:),'-k')
    hold on
    if ~isnan(onsetRel_trial(3))
    plot(onsetRel_trial(3),rawtrace_onset(3,round((onsetRel_trial(3)-plotTime(1))*1000)),'or')
    end
    hold on 
    plot([0,0],[min(rawtrace_onset(3,:)),max(rawtrace_onset(3,:))],'--k');
    title(sprintf('target2on diff %f',onsetRel_trial(3)*1000));

    
    subplot(2,3,4)
    plot(plotTimeOff,rawtrace_offset(1,:),'-k')
    hold on
    if ~isnan(offsetRel_trial(1))
    plot(offsetRel_trial(1),rawtrace_offset(1,round((offsetRel_trial(1)-plotTimeOff(1))*1000)),'or')
    end
    hold on 
    plot([0,0],[min(rawtrace_offset(1,:)),max(rawtrace_offset(1,:))],'--k');
    title(sprintf('fixoff diff %f',offsetRel_trial(1)*1000));

    subplot(2,3,5)
    plot(plotTimeOff,rawtrace_offset(2,:),'-k')
    hold on
    if ~isnan(offsetRel_trial(2))
        plot(offsetRel_trial(2),rawtrace_offset(2,round((offsetRel_trial(2)-plotTimeOff(1))*1000)),'or')
    end
    hold on 
    plot([0,0],[min(rawtrace_offset(2,:)),max(rawtrace_offset(2,:))],'--k');
    title(sprintf('target1off diff %f',offsetRel_trial(2)*1000));

    subplot(2,3,6)
    plot(plotTimeOff,rawtrace_offset(3,:),'-k')
    hold on
    if ~isnan(offsetRel_trial(3))
    plot(offsetRel_trial(3),rawtrace_offset(3,round((offsetRel_trial(3)-plotTimeOff(1))*1000)),'or')
    end
    hold on 
    plot([0,0],[min(rawtrace_offset(3,:)),max(rawtrace_offset(3,:))],'--k');
    title(sprintf('target2off diff %f',offsetRel_trial(3)*1000));
   keyboard
   %}

    PDTiming = buildPDTable(comments_data, onsetAbs, offsetAbs);

    % Timing error (photodiode - comments), ms. NOT recomputed -- onsetRel and
    % offsetRelOff above ARE this quantity, in seconds: onsetRel is
    % onsetAbs - markerAbs (each channel's onset comment marker) and
    % offsetRelOff is offsetAbs - offRefAbs (its per-task offset reference),
    % which is exactly what the old computeTimingErrors re-derived from
    % PDTiming, down to a second offsetRefTimes call. Only the s -> ms scaling
    % is left, since every consumer (histograms, outlier titles) reports ms.
    % Kept as a TABLE, not a struct, so a column can be reached by name
    % (err.Target1OffError), sliced by trial index (err(idx, :)), or summarized
    % directly; rows are 1:1 with PDTiming and comments_data, in the same order.
    err = array2table([onsetRel, offsetRelOff] * 1000, 'VariableNames', ...
        {'FixOnError',  'Target1OnError',  'Target2OnError', ...
         'FixOffError', 'Target1OffError', 'Target2OffError'});

    cmp = computeIntervalComparisons(PDTiming, comments_data);

    % Per-trial outcome, carried RAW (like taskLabels) rather than pre-reduced
    % to a success mask, so the figures can re-apply a different
    % SuccessOutcomes without a recompute. Missing column -> empty, which
    % resolveSuccessMask reads as "no outcome info, draw everything".
    if ismember('Trialoutcome', comments_data.Properties.VariableNames)
        outcomeLabels = comments_data.Trialoutcome;
    else
        outcomeLabels = {};
    end

    hasTrace = any(~isnan(onsetAbs(:)));

    fprintf('Photodiode timing: fixation on=%d/%d off=%d/%d (%s), target1 on=%d/%d off=%d/%d (%s), target2 on=%d/%d off=%d/%d (%s) (of %d trials)\n', ...
        sum(~isnan(PDTiming.FixationOnsetPD)), nTrials, sum(~isnan(PDTiming.FixationOffsetPD)), nTrials, polarityUsed{1}, ...
        sum(~isnan(PDTiming.Target1OnsetPD)),  nTrials, sum(~isnan(PDTiming.Target1OffsetPD)),  nTrials, polarityUsed{2}, ...
        sum(~isnan(PDTiming.Target2OnsetPD)),  nTrials, sum(~isnan(PDTiming.Target2OffsetPD)),  nTrials, polarityUsed{3}, nTrials);

    payload = struct('PDTiming', PDTiming, 'err', err, 'cmp', cmp, ...
        'plotData', plotData, 'plotTime', plotTime, ...
        'plotDataOff', plotDataOff, 'plotTimeOff', plotTimeOff, ...
        'onsetRel', onsetRel, 'offsetRel', offsetRel, ...
        'onsetRelOff', onsetRelOff, 'offsetRelOff', offsetRelOff, ...
        'taskLabels', {comments_data.Task}, ...
        'outcomeLabels', {outcomeLabels}, 'hasTrace', hasTrace, ...
        'baseWin', baseWin, 'searchWin', searchWin, 'nSD', nSD, 'nContig', nContig, ...
        'polarity', polarity, 'polarityUsed', {polarityUsed});
end


function mask = crossingMask(data, thr, chanFalling, direction)
% Threshold mask for every (channel, trial, sample) at once: true where the
% trace is on the far side of thr in the requested `direction` -- 'away' from
% baseline (onset) or 'back' toward it (offset) -- given each channel's
% polarity (chanFalling(c) true = baseline high, stimulus drives it low).
% thr is nChan x nTrials, broadcast along samples. NaN comparisons are false
% in MATLAB either way, so NaN padding never falsely triggers and needs no
% special-casing. Only the ONE comparison actually needed is computed; when
% every channel shares a polarity (the normal case) that is a single
% whole-array compare with no channel-indexed copy.
    thr3 = reshape(thr, size(thr, 1), size(thr, 2), 1);
    if strcmp(direction, 'away')
        wantLT = chanFalling;        % falling: away from baseline = below thr
    else
        wantLT = ~chanFalling;       % falling: back toward baseline = above thr
    end
    if all(wantLT)
        mask = data < thr3;
    elseif ~any(wantLT)
        mask = data > thr3;
    else
        mask = data > thr3;                                    % rising-channel rule
        mask(wantLT, :, :) = data(wantLT, :, :) < thr3(wantLT, :, :);
    end
end


function idx = firstRunVectorized(mask, nContig, lo, hi)
% For EVERY row of `mask` at once (a row = one channel/trial combination; the
% sample dimension is last), the first index i in [lo, hi-nContig+1] where
% mask(..., i:i+nContig-1) is all true, or NaN if there is none. No loop.
%
% lo and hi may each be a scalar (shared by every row) or an array matching
% mask's LEADING dimensions -- a different bound per row. The per-row form is
% what lets each trial's offset search begin at that trial's own onset.
%
% Method: a reset-counter. streak(...,i), the number of consecutive true
% values ending at sample i, is i minus the position of the last FALSE at or
% before i -- and that "last false position" is a cummax along samples. The
% first END position with streak >= nContig then falls out of max() on a
% logical array, which MATLAB defines to return the index of the FIRST
% maximal element. The counter is carried in the smallest unsigned integer
% class that can index the samples rather than double, which keeps the two
% largest intermediates (resetPos and its cummax) a quarter of the size --
% that dominates the cost on the full-window offset search.

    d = ndims(mask);
    nSamp = size(mask, d);
    leadDims = size(mask);  leadDims(d) = [];

    if nSamp <= intmax('uint16');  ic = 'uint16';  else;  ic = 'uint32';  end
    idxCols  = reshape(cast(1:nSamp, ic), [ones(1, d-1), nSamp]);   % broadcasts along rows
    idxColsD = reshape(1:nSamp, [ones(1, d-1), nSamp]);             % double, for the bounds

    % resetPos = sample index where mask is FALSE, 0 where TRUE. Written as
    % integer .* integer because MATLAB does not allow integer .* logical-array.
    resetPos  = cast(~mask, ic) .* idxCols;
    lastFalse = cummax(resetPos, d);                 % running last-FALSE position
    clear resetPos
    % streak >= nContig, rewritten as a compare against a tiny 1x..x1xnSamp
    % vector so the full-size streak array is never materialized. idxColsD is
    % double on purpose: idxCols - nContig in unsigned arithmetic would
    % saturate at 0 for i < nContig and admit false hits.
    endOk = lastFalse <= (idxColsD - nContig);
    clear lastFalse

    % MATLAB's max()/min() ignore NaN, so a NaN lo/hi must be excluded
    % EXPLICITLY -- otherwise an invalid bound silently collapses to the clamp
    % value instead of correctly disabling that row.
    if isscalar(lo)
        loValid = ~isnan(lo);         loSearchEnd = max(lo + nContig - 1, 1);
    else
        loArr = reshape(lo, [leadDims, 1]);
        loValid = ~isnan(loArr);      loSearchEnd = max(loArr + nContig - 1, 1);
    end
    endOk = endOk & (idxColsD >= loSearchEnd) & loValid;

    if isscalar(hi)
        hiValid = ~isnan(hi);         hiSearch = min(hi, nSamp);
    else
        hiArr = reshape(hi, [leadDims, 1]);
        hiValid = ~isnan(hiArr);      hiSearch = min(hiArr, nSamp);
    end
    endOk = endOk & (idxColsD <= hiSearch) & hiValid;

    [found, endIdx] = max(endOk, [], d);
    idx = endIdx - nContig + 1;      % run START, from the END position max() found
    idx(~found) = NaN;
end


function rel = idxToRelTime(idx, timeVec)
% Map per-(channel, trial) sample indices onto their times, NaN-safe (a NaN
% index -- nothing detected -- stays NaN rather than erroring on indexing).
    rel = nan(size(idx));
    ok  = ~isnan(idx);
    rel(ok) = timeVec(idx(ok));
end


function PDTiming = buildPDTable(comments_data, onsetAbs, offsetAbs)
% Assemble the per-trial photodiode-timing table.
    PDTiming = table(comments_data.Session, comments_data.Trial_number, ...
        onsetAbs(:,1), offsetAbs(:,1), onsetAbs(:,2), offsetAbs(:,2), onsetAbs(:,3), offsetAbs(:,3), ...
        'VariableNames', {'Session', 'Trial_number', 'FixationOnsetPD', 'FixationOffsetPD', ...
                          'Target1OnsetPD', 'Target1OffsetPD', 'Target2OnsetPD', 'Target2OffsetPD'});
end


function ref = offsetRefTimes(comments_data, nChan)
% The comments-side OFFSET reference time per (trial, channel), in absolute
% seconds -- the single definition of "what this channel's reported off time
% is", shared by the Band-2 timing-error histograms and by the Band-1 offset
% panels' alignment, so the figure cannot drift out of sync with the numbers.
%
%   fixation -> Fixation_point_off               (every task)
%   target1  -> PER TASK: Target_1_off on saccade tasks (memory / visual),
%               Targets_off on the time-delay task
%   target2  -> Targets_off  (only the time-delay task has a target 2 at all,
%               and there it goes off together with target 1)
%
% target1 is keyed on the task, NOT resolved as a Target_1_off-else-Targets_off
% priority chain, because the two markers are different events wherever both
% exist: on a saccade task Target_1_off is target 1's real extinguish and
% Targets_off is the end of the trial, a median ~1.65 s later (see the coverage
% note in the file header). A priority chain gets the right answer only by
% accident of the two tasks populating disjoint fields, and gets it wrong the
% moment a saccade trial is missing Target_1_off -- it would silently swap in
% an end-of-trial timestamp ~1.65 s late rather than reporting "no reference".
% Task strings are matched as substrings, the same way EyeCalibration's
% taskEpochs resolves them, so 'saccade' / 'visual_saccades_experiment' /
% 'memory_saccades_experiment' all land on the same rule. A task matching
% neither family (or a missing Task column) falls back to the old
% best-available order, so an unrecognized task still gets a usable reference.
%
% NaN where a trial's channel has no populated reference -- such a trial has no
% reported off time to measure against or to align to, and is simply left out
% of the histogram / offset panel rather than compared against the wrong event.
    nTrials = height(comments_data);
    fixOff   = pickColumn(comments_data, 'Fixation_point_off', nTrials);
    t1Off    = pickColumn(comments_data, 'Target_1_off',       nTrials);
    targsOff = pickColumn(comments_data, 'Targets_off',        nTrials);

    if ismember('Task', comments_data.Properties.VariableNames)
        task = comments_data.Task;
    else
        task = repmat({''}, nTrials, 1);
    end
    isSaccade = contains(task, 'saccade');
    isDelay   = contains(task, 'time_delay');
    isOther   = ~isSaccade & ~isDelay;

    t1Ref            = nan(nTrials, 1);
    t1Ref(isSaccade) = t1Off(isSaccade);
    t1Ref(isDelay)   = targsOff(isDelay);
    t1Ref(isOther)   = t1Off(isOther);                       % unknown task:
   % stillEmpty        = isOther & isnan(t1Ref);
   % t1Ref(stillEmpty) = targsOff(stillEmpty);                % ...best available

    ref = nan(nTrials, nChan);
    refByChan = [fixOff, t1Ref, targsOff];
    nUse = min(nChan, size(refByChan, 2));
    ref(:, 1:nUse) = refByChan(:, 1:nUse);
end


function v = pickColumn(comments_data, name, nTrials)
% One comments column as an nTrials x 1 double, or all-NaN when the table does
% not carry it (older exports predate some of these fields).
    if ismember(name, comments_data.Properties.VariableNames)
        v = comments_data.(name);
    else
        v = nan(nTrials, 1);
    end
end


function cmp = computeIntervalComparisons(PDTiming, comments_data)
% Target1->Target2 onset interval: photodiode-derived vs. the requested
% interval (ms -> s) vs. the comments-derived interval.
    cmp.pdInterval = PDTiming.Target2OnsetPD - PDTiming.Target1OnsetPD;    % s

    if ismember('Requested_target_2_time_offset', comments_data.Properties.VariableNames)
        cmp.reqInterval = comments_data.Requested_target_2_time_offset / 1000;   % ms -> s
    else
        cmp.reqInterval = nan(height(PDTiming), 1);
    end

    if all(ismember({'Target_2_presented', 'Target_1_presented'}, comments_data.Properties.VariableNames))
        cmp.commentsInterval = comments_data.Target_2_presented - comments_data.Target_1_presented;   % s
    else
        cmp.commentsInterval = nan(height(PDTiming), 1);
    end
end


% =========================================================================
% Visualization subfunction (rendering only; no computation)
% =========================================================================

function plotPhotodiodeTimingFigure(payload, plotN, successOutcomes)
% Render-only: draw the combined photodiode-timing QC figure from a
% computePhotodiodeTimingPayload payload. Three bands, top to bottom:
%   1. raw traces, TWO rows of 3 panels (fixation/target1/target2), plotN
%      randomly-sampled trials overlaid per panel -- the same go-cue-alignment
%      idiom CalculateRT.m's trace panels use, per channel here since each
%      channel has its own marker:
%        row A, ONSET  panels: t=0 = that channel's onset marker
%                              (Fixation_point_on / Target_1_presented /
%                              Target_2_presented);
%        row B, OFFSET panels: t=0 = that channel's offset marker
%                              (offsetRefTimes: Fixation_point_off / per-task
%                              Target_1_off-or-Targets_off / Targets_off).
%      Onset and offset need separate panels because a single onset-aligned
%      panel cannot show offset usefully: fixation on-durations run to a
%      median ~2.28 s (p99 ~5.2 s), so most fixation offsets land outside any
%      affordable onset-anchored crop, and those that do land inside scatter
%      across it by on-duration instead of clustering. Aligned to their own
%      marker they cluster at the real latency (~41 ms fixation, ~45 ms
%      targets), the same way the onset dots cluster at ~15 ms.
%      The two rows sample INDEPENDENTLY: row A draws from trials with a
%      detected onset, row B from trials that have both a detected offset and
%      an offset marker to align to (~8% of target trials have no offset
%      marker at all). Intersecting them would shrink both rows for no gain,
%      so a given column's two panels generally show different trials.
%      Both rows sample only SUCCESSFUL trials (see SuccessOutcomes), so the
%      example traces shown are drawn from the same population the histograms
%      below summarize.
%   2. stacked-by-task histograms of timing error (ms), one per onset/offset
%      field (6 panels): (photodiode - comments), Target2Offset vs Targets_off.
%   3. photodiode-derived target1->target2 interval vs. the requested
%      interval, and vs. the comments-derived interval (2 scatter panels).
% All three bands are restricted to successful trials (successOutcomes, from
% the caller's SuccessOutcomes) -- applied by blanking rows to NaN, which every
% panel already skips, so the trial axis stays full length and every index
% keeps its meaning. The restriction and its n are stated in the figure header.
%
% Explicit subplot('Position', ...) bands are used (not tiledlayout) because
% the three bands have different column counts per row -- the same approach
% CalculateRT.m's plotSaccadeFigure already uses for an irregular multi-band
% figure in this codebase.

    taskLabels = payload.taskLabels;         % cell array of char, one per trial
    onsetRel   = payload.onsetRel;           % nTrials x nChan, s from the ONSET marker
    offsetRel  = payload.offsetRel;
    onsetRelOff  = payload.onsetRelOff;      % nTrials x nChan, s from the OFFSET marker
    offsetRelOff = payload.offsetRelOff;

    % Restrict every panel to successful trials (see the header). The mask is
    % applied by BLANKING values, never by removing rows, so a trial index
    % means the same thing everywhere -- sampIdx, the err columns and
    % taskLabels all stay on the full-length trial axis.
    isSuccess = resolveSuccessMask(payload, successOutcomes);
    onsetRel     = maskRowsToNaN(onsetRel,     isSuccess);
    offsetRel    = maskRowsToNaN(offsetRel,    isSuccess);
    onsetRelOff  = maskRowsToNaN(onsetRelOff,  isSuccess);
    offsetRelOff = maskRowsToNaN(offsetRelOff, isSuccess);

    uT   = unique(taskLabels, 'stable');
    nT   = numel(uT);
    cmap = lines(max(nT, 1));

    figure('Name', 'Photodiode Timing QC', 'Color', 'w', 'Position', [60 60 1500 1150]);

    % ---------------------------------------------------------------------
    % Band 1 (top): raw traces, 2 rows x 3 channels.
    %   row A -- aligned to each channel's ONSET marker
    %   row B -- aligned to each channel's OFFSET marker
    % ---------------------------------------------------------------------
    xCol    = [0.055 0.375 0.695];
    wCol    = 0.27;
    chanLbl = {'Fixation', 'Target 1', 'Target 2'};

    % Row A samples trials with a detected onset; row B needs a detected
    % offset AND an offset marker to align to (offsetRelOff is NaN without
    % either), so the two rows sample independently -- see the header.
    sampOn  = sampleTrials(any(~isnan(onsetRel), 2),     plotN);
    sampOff = sampleTrials(any(~isnan(offsetRelOff), 2), plotN);

    axRaw = gobjects(1, 6);
    for c = 1:3
        axRaw(c) = drawTracePanel([xCol(c) 0.795 wCol 0.155], ...
            payload.plotData, payload.plotTime, onsetRel(:, c), offsetRel(:, c), ...
            c, sampOn, taskLabels, uT, cmap, ...
            sprintf('%s ON  (n=%d)', chanLbl{c}, numel(sampOn)), 'Time from ON marker (ms)');
        axRaw(3 + c) = drawTracePanel([xCol(c) 0.575 wCol 0.155], ...
            payload.plotDataOff, payload.plotTimeOff, onsetRelOff(:, c), offsetRelOff(:, c), ...
            c, sampOff, taskLabels, uT, cmap, ...
            sprintf('%s OFF  (n=%d)', chanLbl{c}, numel(sampOff)), 'Time from OFF marker (ms)');
    end
    % Shared task-color legend on the first panel only (avoids 6x redundancy).
    hTask = gobjects(nT, 1);
    hold(axRaw(1), 'on');
    for g = 1:nT
        hTask(g) = plot(axRaw(1), nan, nan, '-', 'Color', cmap(g, :), 'LineWidth', 2);
    end
    legend(axRaw(1), hTask, strrep(uT, '_', ' '), 'Location', 'best');
    hold(axRaw(1), 'off');

    % ---------------------------------------------------------------------
    % Band 2 (middle): stacked-by-task timing-error histograms
    % ---------------------------------------------------------------------
    posHist = [0.040 0.32 0.145 0.18; 0.198 0.32 0.145 0.18; 0.356 0.32 0.145 0.18; ...
               0.514 0.32 0.145 0.18; 0.672 0.32 0.145 0.18; 0.830 0.32 0.145 0.18];
    errFields = {'FixOnError',  'FixOffError',  'Target1OnError', ...
                 'Target1OffError', 'Target2OnError', 'Target2OffError'};
    % Titles stay short on purpose: drawStackedHist appends "(n=..., med=...)"
    % and these panels are only ~0.145 figure-widths apart, so anything longer
    % collides with its neighbours. Which comments field each one is measured
    % against is offsetRefTimes' per-task mapping; see the file header.
    errTitles = {'Fixation ON', 'Fixation OFF', 'Target1 ON', ...
                 'Target1 OFF', 'Target2 ON', 'Target2 OFF'};
    for k = 1:6
        drawStackedHist(posHist(k, :), maskRowsToNaN(payload.err.(errFields{k}), isSuccess), ...
            taskLabels, uT, cmap, 2, errTitles{k});
    end

    % ---------------------------------------------------------------------
    % Band 3 (bottom): interval comparison scatters
    % ---------------------------------------------------------------------
    posCmpA = [0.12 0.05 0.34 0.20];
    posCmpB = [0.56 0.05 0.34 0.20];
    pdInt = maskRowsToNaN(payload.cmp.pdInterval, isSuccess);
    drawIntervalScatter(posCmpA, pdInt, payload.cmp.reqInterval, ...
        taskLabels, uT, cmap, 'PD-derived T1\rightarrowT2 interval (ms)', ...
        'Requested interval (ms)', 'PD interval vs requested');
    drawIntervalScatter(posCmpB, pdInt, payload.cmp.commentsInterval, ...
        taskLabels, uT, cmap, 'PD-derived T1\rightarrowT2 interval (ms)', ...
        'Comments-derived interval (ms)', 'PD interval vs comments');

    polarityUsed = payload.polarityUsed;
    if all(strcmp(polarityUsed, polarityUsed{1}))
        polarityStr = polarityUsed{1};
    else
        polarityStr = sprintf('fix=%s, t1=%s, t2=%s', polarityUsed{1}, polarityUsed{2}, polarityUsed{3});
    end
    if strcmp(payload.polarity, 'auto')
        polarityStr = [polarityStr ' (auto)'];
    end
    annotation('textbox', [0.005 0.965 0.9 0.03], 'String', ...
        sprintf('Photodiode timing QC  |  %s  |  %s polarity, baseline [%.0f %.0f] ms, %g x SD, %d-sample run', ...
            successLabel(payload, successOutcomes, isSuccess), ...
            polarityStr, payload.baseWin(1) * 1000, payload.baseWin(2) * 1000, payload.nSD, payload.nContig), ...
        'EdgeColor', 'none', 'FitBoxToText', 'on', 'FontSize', 10, ...
        'VerticalAlignment', 'top');
end


function plotPhotodiodeOutlierFigure(payload, nWorst, successOutcomes)
% Render-only second window: one column per channel, one row per edge (onset
% on top, offset below), each panel overlaying the nWorst trials with the
% LARGEST-MAGNITUDE discrepancy between the comments-table marker and the
% photodiode-measured time. Selection is by magnitude so both tails are
% represented; every reported number is SIGNED (see outlierTitle for why the
% sign is the diagnosis, not noise to be collapsed away).
%
% The main figure's Band 1 samples trials at random, which shows the typical
% case but cannot show what the bad trials look like -- the Band-2 histograms
% report that a tail exists without showing the traces behind it, so there is
% no way to tell a real display-timing outlier from a detection that latched
% onto the wrong edge. This is that view.
%
% Costs nothing beyond drawing: the ranking key (payload.err), both aligned
% trace arrays and both sets of relative times are already in the payload, so
% this needs no recompute and no extra AlignContinuous pull, and renders the
% same way on a cache hit. Panels come from the same drawTracePanel the main
% figure uses -- only the trial-index vector differs.

    taskLabels = payload.taskLabels;
    uT   = unique(taskLabels, 'stable');
    nT   = numel(uT);
    cmap = lines(max(nT, 1));

    % Same success restriction as the main figure -- the worst trials worth
    % looking at are the worst SUCCESSFUL ones. Without this the panels fill up
    % with aborted trials, whose markers are unreliable by construction, and
    % the genuine display-timing outliers never make the top nWorst.
    isSuccess = resolveSuccessMask(payload, successOutcomes);
    onsetRel     = maskRowsToNaN(payload.onsetRel,     isSuccess);
    offsetRel    = maskRowsToNaN(payload.offsetRel,    isSuccess);
    onsetRelOff  = maskRowsToNaN(payload.onsetRelOff,  isSuccess);
    offsetRelOff = maskRowsToNaN(payload.offsetRelOff, isSuccess);

    figure('Name', 'Photodiode Timing Outliers', 'Color', 'w', 'Position', [100 100 1500 700]);

    xCol    = [0.055 0.375 0.695];
    wCol    = 0.27;
    chanLbl = {'Fixation', 'Target 1', 'Target 2'};
    % Rank each panel by its OWN error field: the worst fixation-onset trials
    % are not the worst target2-offset trials, so a shared selection would
    % defeat the purpose.
    onFields  = {'FixOnError',  'Target1OnError',  'Target2OnError'};
    offFields = {'FixOffError', 'Target1OffError', 'Target2OffError'};

    axOut = gobjects(1, 6);
    for c = 1:3
        eOn  = maskRowsToNaN(payload.err.(onFields{c}), isSuccess);
        iOn  = worstTrials(eOn, nWorst);
        axOut(c) = drawTracePanel([xCol(c) 0.56 wCol 0.36], ...
            payload.plotData, payload.plotTime, ...
            onsetRel(:, c), offsetRel(:, c), ...
            c, iOn, taskLabels, uT, cmap, ...
            outlierTitle(chanLbl{c}, 'ON', eOn, iOn, onsetRel(iOn, c), payload.plotTime), ...
            'Time from ON marker (ms)');

        eOff = maskRowsToNaN(payload.err.(offFields{c}), isSuccess);
        iOff = worstTrials(eOff, nWorst);
        axOut(3 + c) = drawTracePanel([xCol(c) 0.09 wCol 0.36], ...
            payload.plotDataOff, payload.plotTimeOff, ...
            onsetRelOff(:, c), offsetRelOff(:, c), ...
            c, iOff, taskLabels, uT, cmap, ...
            outlierTitle(chanLbl{c}, 'OFF', eOff, iOff, offsetRelOff(iOff, c), payload.plotTimeOff), ...
            'Time from OFF marker (ms)');
    end

    % Shared task-color legend on the first panel only.
    hTask = gobjects(nT, 1);
    hold(axOut(1), 'on');
    for g = 1:nT
        hTask(g) = plot(axOut(1), nan, nan, '-', 'Color', cmap(g, :), 'LineWidth', 2);
    end
    legend(axOut(1), hTask, strrep(uT, '_', ' '), 'Location', 'best');
    hold(axOut(1), 'off');

    annotation('textbox', [0.005 0.965 0.95 0.03], 'String', ...
        sprintf(['Photodiode timing OUTLIERS  |  %s  |  %d largest-magnitude (photodiode - comments) per panel, ' ...
                 'titles give the SIGNED range  (green = detected onset, red = detected offset; ' ...
                 'dotted line = the comments marker)'], ...
                 successLabel(payload, successOutcomes, isSuccess), nWorst), ...
        'EdgeColor', 'none', 'FitBoxToText', 'on', 'FontSize', 10, ...
        'VerticalAlignment', 'top');
end


function ttl = outlierTitle(chanLbl, kind, errVals, idx, relOfInterest, timeVec)
% Panel title for the outlier figure: the SIGNED error range actually on
% display, so the tail is readable without cross-referencing Band 2.
%
% Signed, not |err|, because the sign is the diagnosis: a photodiode time
% LATER than the comment (positive) is the ordinary display/reporting lag, so
% a large positive outlier is a slow or dropped frame; a photodiode time
% EARLIER than the comment (negative) cannot be display lag at all and means
% the detection latched onto the wrong edge, or the comment was logged late.
% Collapsing the two into a magnitude hides exactly the distinction these
% panels exist to make. Selection is still BY magnitude (see worstTrials), so
% both tails are represented -- only the reporting is signed.
%
% drawTracePanel deliberately skips a marker dot whose time falls outside the
% window (an out-of-range dot would force the axis to autoscale past it), and
% that skip is otherwise silent -- so count any such trials and say so, rather
% than letting the panel quietly under-report what it selected.
    if isempty(idx)
        ttl = sprintf('%s %s  - no data', chanLbl, kind);
        return
    end
    e    = errVals(idx);
    nOff = sum(isnan(relOfInterest) | relOfInterest < timeVec(1) | relOfInterest > timeVec(end));
    ttl  = sprintf('%s %s  - %d worst (err %+.0f to %+.0f ms)', ...
        chanLbl, kind, numel(idx), min(e), max(e));
    if nOff > 0
        ttl = sprintf('%s [%d off-panel]', ttl, nOff);
    end
end


function idx = worstTrials(errVals, nWorst)
% Indices of the up-to-nWorst trials with the largest absolute timing error.
% A NaN error means either the detection or the comments reference is missing
% for that trial, which also makes it undrawable on the panel, so dropping NaN
% here doubles as the drawability filter (the same coupling sampleTrials relies
% on for the main figure).
    ok = find(~isnan(errVals));
    if isempty(ok);  idx = [];  return;  end
    [~, ord] = sort(abs(errVals(ok)), 'descend');
    idx = ok(ord(1:min(floor(nWorst), numel(ord))));    % floor: NWorst is only validated numeric+nonneg
end


function isSuccess = resolveSuccessMask(payload, successOutcomes)
% nTrials x 1 logical: which trials the figures are allowed to draw. Resolved
% at DRAW time from the raw outcome labels in the payload, so changing
% SuccessOutcomes re-renders off a cache hit without recomputing.
%
% A payload with no outcome labels (the Trialoutcome column was absent, or the
% cache predates this field) draws everything rather than nothing -- silently
% emptying every panel would look like a detection failure, which is the one
% reading that would waste the most time.
    nTrials = size(payload.onsetRel, 1);
    if ~isfield(payload, 'outcomeLabels') || isempty(payload.outcomeLabels)
        isSuccess = true(nTrials, 1);
        return
    end
    isSuccess = ismember(payload.outcomeLabels(:), successOutcomes);
end


function v = maskRowsToNaN(v, keepRows)
% Blank every row not in keepRows. Blanking rather than deleting is deliberate:
% every panel already skips NaN, and keeping the full trial axis means a trial
% index still means the same thing in taskLabels, the err columns and the
% aligned trace arrays, which are all indexed by the same sampIdx / worstTrials
% output. Subsetting rows here would silently desynchronize all of them.
    v(~keepRows, :) = NaN;
end


function s = successLabel(payload, successOutcomes, isSuccess)
% Figure-header fragment naming the trial restriction actually in force, with
% its n. Stated on the figure because every panel's own "n=" now counts only
% the surviving trials -- without this the restriction would be invisible.
    if ~isfield(payload, 'outcomeLabels') || isempty(payload.outcomeLabels)
        s = 'all trials (no outcome labels in payload)';
        return
    end
    s = sprintf('%s trials only (n=%d/%d)', strjoin(successOutcomes, '/'), ...
        sum(isSuccess), numel(isSuccess));
end


function idx = sampleTrials(eligible, plotN)
% Up to plotN randomly-chosen trial indices from a logical eligibility mask
% (the randperm idiom CalculateRT.m uses for its trace panels).
    idx = find(eligible);
    if numel(idx) > plotN
        idx = idx(randperm(numel(idx), plotN));
    end
end


function ax = drawTracePanel(pos, data, timeVec, onRelCol, offRelCol, chan, sampIdx, taskLabels, uT, cmap, ttl, xlab)
% One Band-1 raw-trace panel: the sampled trials of one channel overlaid on a
% shared marker-aligned axis, with the detected on-segment bolded and its ends
% dotted. Used for BOTH rows -- the only difference between an ON panel and an
% OFF panel is which pull (`data`/`timeVec`) and which pair of relative-time
% columns get passed in, so the drawing itself lives here once.
%   onRelCol/offRelCol - nTrials x 1, detected onset/offset in seconds
%                        relative to whatever marker this panel is aligned to.
    ax = subplot('Position', pos); hold(ax, 'on');
    tms = timeVec * 1000;
    lo  = timeVec(1);  hi = timeVec(end);

    for i = sampIdx(:).'
        % `data` is already all-NaN for a trial that never reached this
        % channel's marker (AlignContinuous leaves it that way), so such a
        % trial simply doesn't render -- no explicit skip needed.
        g     = find(strcmp(uT, taskLabels{i}), 1);
        col   = cmap(g, :);
        trace = reshape(data(chan, i, :), 1, []);
        plot(ax, tms, trace, '-', 'Color', [col 0.5], 'LineWidth', 0.5);

        % Detection is independent of the display crop, so an end of the
        % on-segment usually falls outside it now that each panel shows only
        % ONE end of that segment (on an ON panel the offset is off to the
        % right, on an OFF panel the onset off to the left). Bold the
        % on-segment only when BOTH of its ends are actually in view --
        % clipping it instead, as an earlier single-panel layout did, would
        % bold nearly the whole panel and bury the task-coloured traces
        % underneath, which is exactly the information these panels exist to
        % show. The green/red dots carry the detection result either way.
        onR = onRelCol(i);  offR = offRelCol(i);
        if ~isnan(onR) && ~isnan(offR) && onR >= lo && offR <= hi
            seg = timeVec >= onR & timeVec <= offR;
            plot(ax, tms(seg), trace(seg), '-', 'Color', 'r', 'LineWidth', 1.5);
        end
        if ~isnan(onR) && onR >= lo && onR <= hi
            [~, ix] = min(abs(timeVec - onR));
            plot(ax, onR * 1000, trace(ix), 'o', ...
                'MarkerFaceColor', 'g', 'MarkerEdgeColor', 'k', 'MarkerSize', 5);
        end
        if ~isnan(offR) && offR >= lo && offR <= hi
            [~, ix] = min(abs(timeVec - offR));
            plot(ax, offR * 1000, trace(ix), 'o', ...
                'MarkerFaceColor', 'r', 'MarkerEdgeColor', 'k', 'MarkerSize', 5);
        end
    end

    yl = ylim(ax);
    plot(ax, [0 0], yl, 'k:');            % the marker itself, t=0
    ylim(ax, yl);
    xlim(ax, [lo hi] * 1000);             % hard guarantee, not just incidental
    xlabel(ax, xlab);
    ylabel(ax, 'Photodiode (uV)');
    title(ax, ttl);
    set(ax, 'LineWidth', 1, 'FontSize', 9);
    hold(ax, 'off');
end


function drawStackedHist(pos, vals, taskLabels, uT, cmap, binWidth, ttl)
% One stacked-by-task histogram panel of (photodiode - comments) timing
% error, ms. Mirrors CalculateRT.m's RT-distribution histogram
% (bar(centers, counts, 'stacked', ...) colored per task).
    ax = subplot('Position', pos); hold(ax, 'on');
    ok = ~isnan(vals);
    if ~any(ok)
        text(ax, 0.5, 0.5, 'no data', 'Units', 'normalized', 'HorizontalAlignment', 'center');
        title(ax, ttl); hold(ax, 'off'); return
    end
    v   = vals(ok);
    tsk = taskLabels(ok);
    nT  = numel(uT);

    lo = floor(min(v) / binWidth) * binWidth;
    hi = ceil( max(v) / binWidth) * binWidth;
    if hi <= lo;  hi = lo + binWidth;  end
    edges   = lo:binWidth:hi;
    centers = edges(1:end-1) + binWidth / 2;

    counts = zeros(numel(centers), nT);
    for g = 1:nT
        counts(:, g) = histcounts(v(strcmp(tsk, uT{g})), edges);
    end
    hb = bar(ax, centers, counts, 'stacked', 'EdgeColor', 'w');
    for g = 1:nT
        hb(g).FaceColor = cmap(g, :);
    end
    xline(ax, 0, 'k:');
    xlabel(ax, 'PD - comments (ms)');
    ylabel(ax, 'Count');
    title(ax, sprintf('%s (n=%d, med=%.1f)', ttl, numel(v), median(v)));
    set(ax, 'LineWidth', 1, 'FontSize', 9); hold(ax, 'off');
end


function drawIntervalScatter(pos, x, y, taskLabels, uT, cmap, xlab, ylab, ttl)
% Scatter + unity line: does the photodiode-derived interval track the
% comparison interval 1:1, or is there a slope/offset bias? Mirrors
% CalculateRT.m's "main sequence" scatter idiom (posSc1), generalized with a
% diagonal reference line (same dashed-reference-line idiom as its go-cue
% marker, plot([0 0], ylim, 'k:')).
    ax = subplot('Position', pos); hold(ax, 'on');
    ok = ~isnan(x) & ~isnan(y);
    xv = x(ok) * 1000;   % s -> ms
    yv = y(ok) * 1000;
    tsk = taskLabels(ok);
    for g = 1:numel(uT)
        k = strcmp(tsk, uT{g});
        plot(ax, xv(k), yv(k), 'o', 'MarkerFaceColor', cmap(g, :), ...
            'MarkerEdgeColor', 'k', 'MarkerSize', 5);
    end
    if any(ok)
        lims = [min([xv; yv]), max([xv; yv])];
        if diff(lims) <= 0;  lims = lims + [-10 10];  end
        plot(ax, lims, lims, 'k--', 'LineWidth', 1);
        xlim(ax, lims);  ylim(ax, lims);
    end
    axis(ax, 'square');
    xlabel(ax, xlab); ylabel(ax, ylab); title(ax, ttl);
    set(ax, 'LineWidth', 1, 'FontSize', 9); hold(ax, 'off');
end
