function RT = CalculateRT(caled_eyes, comments_data, plotFlag, plotN, errorCheck, savePath, reCompute, varargin)
% Detect the saccadic reaction time (RT) of each trial from the eye trace.
%
% For every saccade-task trial the eye trace is aligned to the go cue
% (Fixation_point_off), the 2D eye speed is thresholded, and the saccade onset
% is extrapolated back to the pre-saccade baseline to give a sub-sample RT.
% Per-trial saccade metrics are returned as a table.
%
% The analysis window is cut PER TRIAL, inside the detection loop: it runs from
% PRE_MS before the go cue to POST_MS after that trial's Fixation_exited marker,
% falling back to POST_MS after the go cue when the marker is missing. Fixation
% exit lands anywhere from a few ms to ~1 s after the go cue, so a single shared
% window would be either too short for the slow trials or mostly empty on the
% fast ones. Every window starts at -PRE_MS and shares the native sample step,
% so the per-trial axes are prefixes of the longest one -- which is what the QC
% figures plot against, NaN-padding the shorter trials.
%
%   caled_eyes    - calibrated eye product from EyeCalibration:
%                     .data (chan x nTrials x maxSamples, eye X/Y on chans 1/2)
%                     .timeseq.relative_time (1 x maxSamples, s; 0 at Start)
%                     .timeseq.alignedrawtime (nTrials x 1, s; absolute Start)
%                     .info.samplingrate (Hz)
%                     .cal.applied (logical), .cal.units ('deg' | 'uV')
%                   When no eye data was recorded, caled_eyes has only
%                   .cal.applied = false and NO .data field. It may also be []
%                   -- either because the session has no eye export, or because
%                   PrepareEyes skipped the calibration knowing this call would
%                   hit its cache and never look at the trace. Both cases return
%                   an all-NaN RT table of the right height.
%   comments_data - table of parsed trials (1:1 with dim 2 of .data). Needs
%                   Task, Trialoutcome, Fixation_point_off, Fixation_exited.
%   plotFlag      - true to draw the population QC figure (default false).
%   plotN         - number of detected trials to draw, randomly sampled and
%                   colored by task (default 50; NaN = draw all detected).
%   errorCheck    - true to also draw the error-check figure of outlier saccades
%                   (default true). Only used on the plot path.
%   savePath      - (optional) session export folder. When set, the per-trial RT
%                   table is written to <savePath>/AnalysisCache/RT.csv (the
%                   lightweight, always-available product). The full plot payload
%                   is cached to <savePath>/AnalysisCache/RT.mat only on the plot
%                   path (plotFlag true), since only the QC figures need it.
%                   '' disables all caching / export.
%   reCompute     - (optional, default true) when true, recompute RT and refresh
%                   the export/cache. When false, reuse the cached result: the
%                   plot path redraws from RT.mat, the return-only path reads
%                   RT.csv, neither recomputing.
%   varargin      - (optional) name/value flags controlling only the saccade-map
%                   QC figure (plot path, calibrated data):
%                     'EndpointStyle' : 'hist' (default) | 'kde'  -- endpoint
%                                       density as a binned 2-D histogram or a
%                                       gaussian-smoothed density.
%                     'PeakVelStyle'  : 'surface' (default) | 'dots' -- peak
%                                       velocity per target as a griddata surface
%                                       or discrete colored markers.
%
% Returns RT, an nTrials x 10 table of per-trial saccade metrics (one row per trial
% in comments_data, in order):
%   Session, Trial_number, RTtime (s from go cue), SaccadeAmplitude, PeakVelocity,
%   StartX, StartY, EndX, EndY, SaccadeDuration.
% Session/Trial_number are copied from comments_data, matching the key
% GetPhotodiodeTiming returns and SpikeTrialAlignmentCheck matches on, so every
% analyze-stage product joins on the same two columns. Trial_number restarts at 0
% each session, so the PAIR is the identifier -- Trial_number alone is not unique.
% Every RT comes from the eye trace; trials that were invalid or where no saccade
% was detected are NaN rows.
% Note: The detector is not optimized for uncalibrated eye data.
% Xuefei Jul 2026

    if nargin < 3 || isempty(plotFlag);    plotFlag   = false;  end
    if nargin < 4 || isempty(plotN);       plotN      = 50;     end
    if nargin < 5 || isempty(errorCheck);  errorCheck = true;   end
    if nargin < 6;                         savePath   = '';     end
    if nargin < 7 || isempty(reCompute);   reCompute  = true;   end

    % Style flags for the saccade-map QC figure only (see plotSaccadeMapsFigure).
    p = inputParser;

    p.addParameter('EndpointStyle', 'kde', ...
        @(s) any(strcmpi(s, {'hist', 'kde'})));
    p.addParameter('PeakVelStyle',  'surface', ...
        @(s) any(strcmpi(s, {'surface', 'dots'})));
    p.parse(varargin{:});
    plotOpts = struct('EndpointStyle', lower(p.Results.EndpointStyle), ...
                      'PeakVelStyle',  lower(p.Results.PeakVelStyle));

    if plotFlag
        % Plot path: the QC figures need the full payload (traces, per-trial
        % detection cells), so compute-or-load it from the RT.mat cache and render
        % from it, so the plots look identical on the compute and cache paths.
        % computeRTPayload is pure; plotRTFigures only draws.
        payload = getCachedPayload(savePath, 'RT', reCompute, ...
            @() computeRTPayload(caled_eyes, comments_data));
        payload = backfillPayload(payload);   % older caches lack the newer fields
        RT = payload.RT;
        exportRTtable(RT, savePath);          % refresh the lightweight CSV
        if payload.hasTrace
            plotRTFigures(payload, plotN, errorCheck, plotOpts);
        end
    else
        % Return-only path: never touch the heavy RT.mat. Reuse the small RT.csv
        % when allowed, otherwise recompute and refresh it.
        csvFile = rtCsvPath(savePath);
        if ~reCompute && ~isempty(csvFile) && exist(csvFile, 'file')
            RT = readtable(csvFile);
        else
            payload = computeRTPayload(caled_eyes, comments_data);
            RT = payload.RT;
            exportRTtable(RT, savePath);
        end
    end
end


function csvFile = rtCsvPath(savePath)
% Path of the per-trial RT table export, or '' when caching is disabled.
    csvFile = '';
    if ~isempty(savePath)
        csvFile = fullfile(char(savePath), 'AnalysisCache', 'RT.csv');
    end
end


function exportRTtable(RT, savePath)
% Write the per-trial RT table to <savePath>/AnalysisCache/RT.csv (no-op when
% savePath is empty). This is the lightweight product read back by the
% return-only path; it is far smaller than the RT.mat plot payload.
    csvFile = rtCsvPath(savePath);
    if isempty(csvFile);  return;  end
    cacheDir = fileparts(csvFile);
    if ~exist(cacheDir, 'dir');  mkdir(cacheDir);  end
    writetable(RT, csvFile);
end


function payload = computeRTPayload(caled_eyes, comments_data)
% Pure compute: detect RT / saccade metrics and bundle everything the QC plots
% need. Returns payload with fields RT (the returned struct), t (aligned time
% axis, s), dets (per-trial detection cells), ampOut / durOut (outlier masks),
% taskLabels (per-trial Task) and hasTrace (whether any trace can be plotted).

    % No eye trace at all: caled_eyes is [] (the session has no eye export, so
    % PrepareEyes never calibrated) or carries only .cal.applied = false with no
    % .data. Return a full-length all-NaN table instead of erroring at the
    % reshape below, so the one-row-per-comments-row contract that extendComments
    % and SetupDataForTask rely on still holds. hasTrace = false makes the caller
    % skip the QC figures, so the empty t / dets / maps are never drawn from.
    if isempty(caled_eyes) || ~isfield(caled_eyes, 'data') || isempty(caled_eyes.data)
        disp('No eye trace available; RT returned as all NaN.');
        nanCol  = nan(height(comments_data), 1);
        payload = struct( ...
            'RT', buildTable(comments_data, nanCol, nanCol, nanCol, nanCol, ...
                             nanCol, nanCol, nanCol, nanCol), ...
            'units', 'uV/s', 't', [], 'dets', {cell(height(comments_data), 1)}, ...
            'ampOut', false(height(comments_data), 1), ...
            'durOut', false(height(comments_data), 1), ...
            'rtOut', false(height(comments_data), 1), ...
            'taskLabels', {comments_data.Task}, 'hasTrace', false, ...
            'calApplied', false, ...
            'maps', {struct('task', {}, 'endPts', {}, 'startCenter', {}, ...
                            'fixPt', {}, 'targets', {}, 'targPV', {}, 'targN', {})}, ...
            'minAmp', struct('trial', [], 't', [], 'x', [], 'y', []));
        return
    end

    % ---- detection settings ------------------------------------------------
    % The analysis window is cut PER TRIAL inside the loop below:
    %   [go cue - PRE_MS,  Fixation_exited + POST_MS]
    % and falls back to [go cue - PRE_MS, go cue + POST_MS] when the trial has no
    % Fixation_exited marker. Fixation exit lands anywhere from a few ms to ~1 s
    % after the go cue, so one shared window would be either too short for the
    % slow trials or mostly empty on the fast ones.
    PRE_MS   = 200;             % ms,window kept before the go cue
    POST_MS  = 800;             % ms,window kept after the fixation-exit marker
    BASE_WIN = [-0.200 -0.05]; % baseline window (s from go cue)
    V_THR    = 30;             % primary speed threshold above baseline (deg/s)
    MAX_DUR  = 0.150;          % max saccade duration; end searched within this of onset (s)
    END_THR_STEP = 10;         % raise end speed threshold by this if no end within MAX_DUR (deg/s)
    SPEED_NOISE = 1500;        % speed above this (deg/s) is tracker noise -> removed
    NOISE_WIN = [0 0.200];     % hard reject: noise in this window after go -> RT NaN (s)
    ONSET_BACK = -0.100;       % onset search may reach back to this (s from go cue)
    N_CONTIG = 5;             % samples a criterion must be sustained

    % Bundle detection constants so detectSaccade takes one cfg struct, not a
    % long positional list. Names match the locals unpacked inside detectSaccade.
    cfg = struct('baseWin', BASE_WIN, 'primaryThr', V_THR, ...
         'maxDur', MAX_DUR, ...
        'endThrStep', END_THR_STEP,   ...
        'speedNoise', SPEED_NOISE, 'noiseWin', NOISE_WIN, 'onsetBack', ONSET_BACK, ...
        'nContig', N_CONTIG);

    % Behavioral-marker times in the aligned (go-cue = 0) frame. Onset is anchored
    % to the approximate RT, the end to Choicetime. approxRT also sets each
    % trial's window length (see the loop below).
    approxRT   = comments_data.Fixation_exited - comments_data.Fixation_point_off;   % s from go
    choice_rel = comments_data.Choicetime     - comments_data.Fixation_point_off;   % s from go

    nTrials = height(comments_data);

    % Saccade tasks whose RT is meaningful, and the trials we score.
    tasks_for_RT = {'visual_saccades_experiment', 'memory_saccades_experiment', ...
                    'time_delay_experiment'};
    isTask  = contains(comments_data.Task, tasks_for_RT);
    isValid = isTask & ismember(comments_data.Trialoutcome, {'correct', 'wrong'});

    % Pre-allocate every metric column with NaN so invalid / undetected trials
    % simply stay NaN.
    RTtime   = nan(nTrials, 1);
    ampl     = nan(nTrials, 1);
    peakVel  = nan(nTrials, 1);
    startX   = nan(nTrials, 1);
    startY   = nan(nTrials, 1);
    endX     = nan(nTrials, 1);
    endY     = nan(nTrials, 1);
    durSac   = nan(nTrials, 1);

    N_Onset_regular     = nan(nTrials, 1);
    N_Onset_release     = nan(nTrials, 1);
    N_Onset_fail   = nan(nTrials, 1);
    N_Onset_early   = nan(nTrials, 1);

    N_Offset_regular     = nan(nTrials, 1);
    N_Offset_release     = nan(nTrials, 1);
    N_Offset_fail   = nan(nTrials, 1);
    N_Offset_early   = nan(nTrials, 1);

   
    % Calibrated traces are in degrees, so the 30 deg/s threshold applies.
    % Uncalibrated traces are still in uV, where 30 deg/s is meaningless, so
    % only the baseline + 3*SD criterion is used.
    useDegThr = caled_eyes.cal.applied;
    if useDegThr
        units = 'deg/s';
    else
        units = 'uV/s';
        disp('Eye trace is uncalibrated (uV); using baseline + 3*SD criterion.');
    end

    eye_x    = reshape(caled_eyes.data(1, :, :), nTrials, []);  % nTrials x nSamp
    eye_y    = reshape(caled_eyes.data(2, :, :), nTrials, []);
    eye_time = caled_eyes.timeseq.relative_time;               % 1 x nSamp, s from Start

    % Go cue in the relative frame, as EyeCalibration does it: the comment marker
    % is on the absolute NSP clock, relative_time is 0 at Start.
    marker_rel = comments_data.Fixation_point_off - caled_eyes.timeseq.alignedrawtime(:);

    % Every per-trial axis is (-nPre : nPost_i) * step_s with the SAME nPre and
    % step_s, so all of them are left-aligned prefixes of the longest one. Keeping
    % the longest lets the QC plots stay on one shared axis (short trials just
    % NaN-pad on the right) without a second alignment pass.
    t    = [];
    dets = cell(nTrials, 1);            % kept for the QC plot
    for i = find(isValid).'
        [x, y, t_i] = alignTrialWindow(eye_x(i, :), eye_y(i, :), eye_time, ...
            marker_rel(i), PRE_MS, POST_MS, approxRT(i));
        if all(isnan(x));  continue;  end       % window fell outside recorded data
        if numel(t_i) > numel(t);  t = t_i;  end

        
        mk  = struct('approxRT', approxRT(i), 'choicetime', choice_rel(i));
        det = detectSaccade(t_i, x, y, cfg, mk, useDegThr);
        dets{i} = det;
        if ~det.detected;  continue;  end

        RTtime(i)  = det.RTtime;
        ampl(i)    = det.SaccadeAmplitude;
        peakVel(i) = det.PeakVelocity;
        startX(i)  = det.StartPoint(1);
        startY(i)  = det.StartPoint(2);
        endX(i)    = det.EndPoint(1);
        endY(i)    = det.EndPoint(2);
        durSac(i)  = det.SaccadeDuration;

        N_Onset_regular(i)     = det.N_Onset_regular;
        N_Onset_release(i)    = det.N_Onset_release;
        N_Onset_fail(i)   = det.N_Onset_fail;
        N_Onset_early(i)   = det.N_Onset_early;

        N_Offset_regular(i)     = det.N_Offset_regular;
        N_Offset_release(i)    = det.N_Offset_release;
        N_Offset_fail(i)   = det.N_Offset_fail;
        N_Offset_early(i)  = det.N_Offset_early;



    end

    fprintf('%d real RT detected from the eye trace (of %d valid trials).\n', ...
        sum(~isnan(RTtime)), sum(isValid));
    fprintf('For onset detection \n : %d RTs were identified regularly.\n',sum(N_Onset_regular==1));
    fprintf('%d RTs were identified with released criterium.\n',sum(N_Onset_release==1));
    fprintf('%d RTs were failed to identify.\n',sum(N_Onset_fail==1));
    fprintf('%d RTs have fix-exit marker later than the eye trace window.\n',sum(N_Onset_early==1));

    fprintf('For offset detection \n : %d RTs were identified regularly.\n',sum(N_Offset_regular==1));
    fprintf('%d RTs were identified with released criterium.\n',sum(N_Offset_release==1));
    fprintf('%d RTs were failed to identify.\n',sum(N_Offset_fail==1));
    fprintf('%d RTs have choice time marker already back to baseline.\n',sum(N_Offset_early==1));
    %{
    % Smallest detected saccade, for the single-trial QC figure. Only its window
    % is re-cut (one extra align) -- storing the position traces of EVERY trial
    % would roughly double RT.mat, since dets already carries speed + dev.
    minAmp = struct('trial', [], 't', [], 'x', [], 'y', []);
    [minVal, kMin] = min(ampl);
    if ~isnan(minVal)
        [xk, yk, tk] = alignTrialWindow(eye_x(kMin, :), eye_y(kMin, :), eye_time, ...
            marker_rel(kMin), PRE_MS, POST_MS, approxRT(kMin));
        minAmp = struct('trial', kMin, 't', tk, 'x', xk, 'y', yk);
    end
    %}
    %{
    figure
    subplot(3,1,1)
    plot(tk,xk);
    hold on
    plot(RTtime(kMin),startX(kMin),'or');

    subplot(3,1,2)
    plot(tk,yk);
    hold on
    plot(RTtime(kMin),startY(kMin),'or');

    subplot(3,1,3)
    [speed, tv, xs, ys] = computeEyeSpeed(xk, yk, tk);
    plot(tv,speed);
    hold on
    plot(RTtime(kMin),speed(round(RTtime(kMin)-tv(1)*1000)),'or');
    %}
    RTtable = buildTable(comments_data, RTtime, ampl, peakVel, ...
                         startX, startY, endX, endY, durSac);

    % Trials rejected because tracker noise landed inside the detected saccade
    % (RT already NaN for these).
    noiseTrials = find(cellfun(@(d) ~isempty(d) && d.noiseReject, dets));
    if ~isempty(noiseTrials)
        fprintf('%d trial(s) rejected: noise inside the saccade -> RT set NaN.\n', ...
            numel(noiseTrials));
    end

    % Flag abnormal (outlier) saccades: amplitude, duration and RT each more than
    % 3 SD from the detected-population mean. Returned for downstream QC.
    [ampOut, durOut, rtOut] = flagOutliers(ampl, durSac * 1000, RTtime * 1000, ...
                                           ~isnan(RTtime));
    %
    outliers = struct('trials',    find(ampOut | durOut | rtOut), ...
                         'amplitude', find(ampOut), ...
                         'duration',  find(durOut), ...
                         'rt',        find(rtOut));
    %}

    fprintf('%d abnormal saccade(s) flagged (amp>3SD: %d, dur>3SD: %d, RT>3SD: %d).\n', ...
        numel(outliers.trials), numel(outliers.amplitude), numel(outliers.duration), ...
        numel(outliers.rt));


    hasTrace = any(cellfun(@(d) ~isempty(d) && ~isempty(d.tv), dets));

    % Per-trial target / fixation location (deg), for the saccade-map QC figure.
    % Only meaningful when calibrated (endpoints and targets share the deg frame).
    targetXY = positionColumns(comments_data, 'Target_1_position');
    fixXY    = positionColumns(comments_data, 'Fixation_position');
    maps     = computeSaccadeMaps(RTtable, comments_data.Task, targetXY, fixXY, ...
                                  tasks_for_RT);

    payload  = struct('RT', RTtable, 'units', units, 't', t, 'dets', {dets}, ...
        'ampOut', ampOut, 'durOut', durOut, 'rtOut', rtOut, ...
        'taskLabels', {comments_data.Task}, 'hasTrace', hasTrace, ...
        'calApplied', useDegThr, 'maps', {maps});
end


function [x, y, t] = alignTrialWindow(eye_x, eye_y, eye_time, marker_rel, ...
        preMs, postMs, approxRT)
% Cut ONE trial's analysis window around its go cue, 0 at the go cue.
%
% The window runs from preMs before the go cue to postMs after the trial's
% fixation-exit marker; when that marker is missing (approxRT NaN) it falls back
% to postMs after the go cue. Returns 1 x nOut row vectors, all NaN when the
% trial has no usable go cue or the window fell outside the recorded data.
%
%   eye_x/eye_y - 1 x nSamp raw trial trace
%   eye_time    - 1 x nSamp sample times (s, same frame as marker_rel)
%   marker_rel  - go cue in that frame (s); NaN -> all-NaN output
%   approxRT    - Fixation_exited - go cue (s); NaN -> no fixation-exit marker
    if ~isnan(approxRT)
        postMs = approxRT * 1000 + postMs;
    end
    [aligned, t] = AlignEyeTrace(eye_x, eye_y, eye_time, marker_rel, preMs, postMs);
    x = aligned.x;
    y = aligned.y;
end


function plotRTFigures(payload, plotN, errorCheck, plotOpts)
% Render-only: draw the RT QC figures from a computeRTPayload payload.
    t       = payload.t;
    dets    = payload.dets;
    nTrials = numel(dets);

    % Every valid trial stores its trace (detected or not), so build the matrices
    % over all trace-carrying trials: plotSaccadeFigure filters to detected
    % internally, while plotErrorCheck also draws the failed ones.
    traced = find(cellfun(@(d) ~isempty(d) && ~isempty(d.tv), dets));
    if isempty(traced)
        warning('CalculateRT: no traces to plot.');
        return
    end

    % Smoothed eye deviation (what detection is based on) and the per-trial speed
    % profiles, assembled from the stored per-trial results so this stays
    % render-only. Windows are cut per trial, but they all share the same start
    % (-PRE_MS) and sample step, so every trial's axis is a prefix of the longest
    % one (payload.t) -- short trials simply NaN-pad on the right and render as a
    % trace that ends early.
    tv        = (t(1:end-1) + t(2:end)) / 2;
    dev_all   = nan(nTrials, numel(t));    % nTrials x nSamp (smoothed)
    speed_all = nan(nTrials, numel(tv));
    for i = traced.'
        dev_all(i,   1:numel(dets{i}.dev))   = dets{i}.dev;
        speed_all(i, 1:numel(dets{i}.speed)) = dets{i}.speed;
    end
    % rtOut is guaranteed present: backfillPayload derives it from the RT table
    % when an older cache lacks it, so the no-recompute path draws the same
    % figures as a fresh compute.
    plotSaccadeFigure(t, tv, dev_all, speed_all, dets, payload.RT, ...
        payload.taskLabels, plotN, payload.units);
    if errorCheck
        plotErrorCheck(t, tv, dev_all, speed_all, dets, ...
            payload.ampOut, payload.durOut, payload.rtOut, payload.units);
    end

    % Saccade endpoint / peak-velocity maps. Requires the enriched payload
    % (older cached RT.mat lacks these fields) and calibrated deg data (targets
    % and endpoints only align in the deg frame).
    if ~isfield(payload, 'maps') || ~isfield(payload, 'calApplied')
        warning(['CalculateRT: cached RT.mat predates the saccade-map figure; ' ...
            'rerun with ReComputeRT = true to enable it.']);
    elseif ~payload.calApplied
        warning(['CalculateRT: saccade-endpoint maps need calibrated (deg) eye ' ...
            'data; skipping (trace is uncalibrated).']);
    elseif isempty(payload.maps)
        warning('CalculateRT: no saccade-task targets to map; skipping.');
    else
        plotSaccadeMapsFigure(payload.maps, payload.units, plotOpts);
    end
%{
    % Single-trial check on the smallest detected saccade (the most likely
    % false positive). Guarded like maps above, so an older cached RT.mat just
    % skips it instead of erroring.
    if isfield(payload, 'minAmp') && ~isempty(payload.minAmp.trial)
        plotMinAmplitudeTrial(payload.minAmp, payload.RT, dets, payload.units);
    end
%}
end


% =========================================================================
% Computation subfunctions (pure)
% =========================================================================

function [speed, tv, xs, ys] = computeEyeSpeed(x, y, t)
% Smooth the eye position, then take the 2D radial speed from the SMOOTHED
% position -- so the trace detection is based on and the trace plotted are one
% and the same. Speed is returned on the mid-sample axis tv.
%   x, y - 1 x nSamp raw eye position (deg or uV)
%   t    - 1 x nSamp time (s)
% Returns:
%   speed  - 1 x nSamp-1 eye speed from the smoothed position
%   tv     - 1 x nSamp-1 mid-sample time axis
%   xs, ys - 1 x nSamp smoothed eye position (what to plot / measure from)
    dt    = median(diff(t));
    xs    = smoothdata(x, 'sgolay', 7, 'omitnan');   % ~7 ms Savitzky-Golay
    ys    = smoothdata(y, 'sgolay', 7, 'omitnan');
    vx    = diff(xs) / dt;
    vy    = diff(ys) / dt;
    speed = hypot(vx, vy);
    tv    = (t(1:end-1) + t(2:end)) / 2;             % midpoints of the position axis
end


function det = detectSaccade(t, x, y, cfg, mk, useDegThr)
% Detect one saccade on the go-cue-aligned window and extrapolate its onset.
%
% cfg - struct of detection constants (see the settings block in CalculateRT).
% mk  - per-trial marker times in the aligned frame: .approxRT (Fixation_exited
%       - go cue) anchors the onset search; .choicetime (Choicetime - go cue)
%       anchors the end search. NaN when a marker is missing.
%
% Trigger (calibrated): the eye deviation must exceed baseline by devMargin deg
% AND the eye speed must exceed baseline by primaryThr deg/s, both sustained for
% nContig samples, with the run starting in [onsetBack, approxRT]. The trigger is
% where both hold; the speed level is then traced back to its up-crossing and the
% rising edge extrapolated to baseline for the sub-sample onset. (Uncalibrated
% falls back to a speed-only 3*SD rule.) If no criterion triggers, a marker-based
% fallback fills the row from approxRT / Choicetime with PeakVelocity NaN.

    % Unpack cfg into the local names the body uses (body unchanged by refactor).
    baseWin     = cfg.baseWin;      primaryThr  = cfg.primaryThr;
    %devMargin   = cfg.devMargin;    
   % devStop     = cfg.devStop;
   % endDevMin   = cfg.endDevMin;    startDevMax = cfg.startDevMax;
   %peakFrac    = cfg.peakFrac;
    %devSettleFB = cfg.devSettleFB;  
    maxDur      = cfg.maxDur;
    endThrStep  = cfg.endThrStep;   
    
    speedNoise  = cfg.speedNoise;
    noiseWin    = cfg.noiseWin;     onsetBack   = cfg.onsetBack;
    nContig    = cfg.nContig;
    approxRT    = mk.approxRT;      choicetime  = mk.choicetime;

    det = struct('detected', false, 'RTtime', NaN, 'SaccadeAmplitude', NaN, ...
        'PeakVelocity', NaN, 'StartPoint', [NaN NaN], 'EndPoint', [NaN NaN], ...
        'SaccadeDuration', NaN, 'onset_t', NaN, 'offset_t', NaN, 'threshold', NaN, ...
        'speed', [], 'tv', [], 't', [], 'dev', [], 'onset_speed', NaN, 'offset_speed', NaN, ...
        'onset_dev', NaN, 'offset_dev', NaN, 'noiseReject', false, 'markerBased', false,...
        'N_Onset_regular',NaN,'N_Onset_release',NaN,'N_Onset_fail',NaN,'N_Onset_early',NaN,...
        'N_Offset_regular',NaN,'N_Offset_release',NaN,'N_Offset_fail',NaN,'N_Offset_early',NaN);

    % Detection (and every position it reports) runs on the SMOOTHED trace.
    [speed, tv, xs, ys] = computeEyeSpeed(x, y, t);

    % Preprocessing: drop tracker-noise samples. A speed over speedNoise deg/s
    % is a blink/glitch, not a saccade. NaN the speed there and the two position
    % samples that produced it, so noise never triggers detection, corrupts the
    % baseline, or shows up in the plot (stored below as NaN gaps). deg/s only.
    % noiseMask (tv axis) is kept so a noise spike landing inside the detected
    % saccade can later reject the whole trial.
    noiseMask = false(1, numel(speed));
    if useDegThr
        noiseMask = speed > speedNoise;
        speed(noiseMask) = NaN;
        badPos = false(1, numel(xs));
        badPos(1:end-1) = badPos(1:end-1) | noiseMask;   % sample before each spike
        badPos(2:end)   = badPos(2:end)   | noiseMask;   % sample after each spike
        xs(badPos) = NaN;  ys(badPos) = NaN;
    end

    dev = hypot(xs, ys);                          % smoothed deviation (nSamp)

    % Store the trace on det up front so EVERY exit path below (the noise / other
    % rejects included) still carries speed/tv/t/dev -- the error-check figure uses
    % it to draw the trials that never produced an RT. t is this trial's own
    % window, which varies in length with its fixation-exit marker.
    det.speed = speed;  det.tv = tv;  det.t = t;  det.dev = dev;

    % Hard gate (before any detection): if tracker noise appears anywhere in the
    % [noiseWin] window after the go signal, this trial's RT is unanalysable --
    % reject it outright (det.detected stays false -> RT NaN).
    if any(noiseMask & tv >= noiseWin(1) & tv <= noiseWin(2))
        det.noiseReject = true;
        return
    end
   % dev_tv = (dev(1:end-1) + dev(2:end)) / 2;     % on the speed axis tv (nSamp-1)
    % x_tv = (xs(1:end-1) + xs(2:end)) / 2;     % on the speed axis tv (nSamp-1)
    % y_tv = (ys(1:end-1) + ys(2:end)) / 2;     % on the speed axis tv (nSamp-1)

    % ---- baseline over the pre-saccade window ---------------------------
    inBase = tv >= baseWin(1) & tv <= baseWin(2);
    base_mean = mean(speed(inBase),  'omitnan');
    base_sd   = std(speed(inBase),   'omitnan');
    %base_dev  = mean(dev_tv(inBase), 'omitnan');
    %base_dev_sd  = std(dev_tv(inBase), 'omitnan');
    %inBaseT   = t >= baseWin(1) & t <= baseWin(2);       % baseline on the position axis
    %base_x    = mean(x_tv(inBaseT), 'omitnan');            % baseline gaze position
    %base_y    = mean(y_tv(inBaseT), 'omitnan');
    %base_x_sd    = std(x_tv(inBaseT), 'omitnan');            % baseline gaze position
    %base_y_sd    = std(y_tv(inBaseT), 'omitnan');
    if isnan(base_mean);  return;  end

    speed_thr = primaryThr + base_mean;           % speed level for the trigger
    %dev_thr   = base_dev   + devMargin;           % deviation level for the trigger
    thr3sd    = base_mean  + 3 * base_sd;         % speed-only fallback

    % Ordered detection criteria: each is a per-sample trigger (held nContig
    % samples) plus the speed level onset/offset are measured against.
    %   Calibrated: combined (deviation AND speed) first, speed-only 3*SD fallback.
    %   Uncalibrated: only the speed-only 3*SD rule (deviation deg is meaningless).
    if useDegThr
        crit = struct('trig', speed > speed_thr , 'level', speed_thr);
    else
        crit    = struct('trig', speed > thr3sd,    'level', thr3sd);
    end

    % Onset trigger is searched in [onsetBack, approxRT]: from the approximate RT (Fixation_exited).
    % back to just before the go cue up to. 
    %  If approxRT is missing, the
    % upper bound falls back to the end of the window.
    onsetHi = approxRT;
    if isnan(onsetHi);  onsetHi = tv(end);  end
    [iTrig, N_onset_regular,N_onset_release,N_onset_fail,N_onset_early] = findSaccadeRun(crit.trig, tv, nContig, onsetBack, onsetHi);
    speed_level = crit.level;

    if isnan(iTrig)
        %failed onset detection
        onset_t = NaN;
    else
  
        % Trace back from the trigger to where the speed crossed speed_level on
        % the way up -- the start of the fast phase.
        iCross = iTrig;
        while iCross > 1 && speed(iCross - 1) >= speed_level
            iCross = iCross - 1;
        end

        % ---- find out the rising edge back to baseline ----------
        iBase = iCross;
        try
        max_dev = max(dev(iCross: min(iCross+500,length(dev))));%Only select the maximum in 500ms after iCross
        
        while iBase > 1 && speed(iBase - 1) > thr3sd || dev(iBase - 1) > max_dev/2
            iBase = iBase - 1;
        end
        catch
            keyboard
        end
        
        onset_t = tv(iBase); 

    end 

    %If onset is nan, no need to detect the offset anymore:
    if isnan(onset_t)
        det.N_Onset_regular = N_onset_regular;
        det.N_Onset_release = N_onset_release;
        det.N_Onset_fail = N_onset_fail; 
        det.N_Onset_early = N_onset_early; 

       return

    end
       
        % ---- offset: confirm the eye has stopped, then extrapolate ------
        % A saccade should not last > maxDur, so the end is searched only within
        % maxDur of onset (iDownMax). Step 1: iDown = where speed first drops
        % below the end threshold for nContig samples, inside that window; if the
        % speed stays elevated the whole window, raise the end threshold by
        % endThrStep and retry (a higher bar crosses sooner). Step 2: from iDown,
        % keep searching (still within the window) until the DEVIATION stops
        % changing -- its range over nContig samples < devStop deg (eye landed).
        % Step 3: fit the falling speed over iDown:iStable, extrapolate to baseline.
        iDownMax = find(tv <= onset_t + maxDur, 1, 'last');
        if isempty(iDownMax) || iDownMax <= iCross
            iDownMax = min(numel(speed), iCross + 1);
        end

        % The end is searched starting AFTER Choicetime (iEndStart). If that
        % marker is missing or falls outside the maxDur window, fall back to the
        % onset-anchored search (iCross).
        iChoice = [];
        if ~isnan(choicetime);  iChoice = find(tv >= choicetime, 1);  end
        if isempty(iChoice) || iChoice <= iCross || iChoice >= iDownMax
            iEndStart = iCross;
        else
            iEndStart = iChoice;
        end

        end_thr = speed_level;
        offOk   = false;
        winMax  = max(speed(iEndStart:iDownMax), [], 'omitnan');   % NaN if all noise
        while ~offOk
            [iDown, offOk,N_offset_regular,N_offset_release,N_offset_fail,N_offset_early] = findSaccadeEnd(speed, iEndStart, iDownMax, end_thr, nContig);
            if offOk;  break;  end
            if isnan(winMax) || end_thr >= winMax       % nothing higher to clear
                break
            end
            end_thr = end_thr + endThrStep;
        end
        if offOk
            % Forward trace the point where saccade hits the baseline
             iOffBase = iDown;
        else
            if isnan(onset_t)
                iOffBase = NaN; %If there is no onset, there is no offset.
            else
                iOffBase = iEndStart;  %if there is an onset, there should be an offset.         
            end
            
            
        end

        if isnan(iOffBase)
            offset_t = NaN;
            iPeakEnd = NaN;

        else
        
        while iOffBase < length(speed) && speed(iOffBase+1) > thr3sd
              iOffBase = iOffBase + 1;
              if iOffBase == length(speed)
                    break;
              end
        end
        
        

            offset_t = tv(iOffBase);
            iPeakEnd = iOffBase;
            
        end
        

        % ---- reject the trial if tracker noise landed inside the saccade -
        % A blink/glitch (speed > speedNoise) anywhere between onset and offset
        % corrupts the amplitude, peak velocity and end point, so the RT is
        % unusable: leave det.detected false (RT stays NaN) and flag it.
        if any(noiseMask & tv >= onset_t & tv <= offset_t)
            det.noiseReject = true;
            return
        end

        

        % ---- metrics (measured off the smoothed trace) ------------------
        sp0 = [interp1(t, xs, onset_t),  interp1(t, ys, onset_t)];
        sp1 = [interp1(t, xs, offset_t), interp1(t, ys, offset_t)];

        det.detected        = true;
        det.RTtime          = onset_t;
        det.onset_t         = onset_t;
        det.offset_t        = offset_t;
        det.StartPoint      = sp0;
        det.EndPoint        = sp1;
        det.PeakVelocity    = max(speed(iCross:iPeakEnd));
        det.SaccadeAmplitude = hypot(sp1(1) - sp0(1), sp1(2) - sp0(2));
        det.SaccadeDuration = offset_t - onset_t;
        det.threshold       = speed_level;
        % Stored for the QC plot (keeps the plot render-only).
        det.speed        = speed;
        det.tv           = tv;
        det.t            = t;
        det.dev          = dev;                    % smoothed eye deviation trace
        det.onset_speed  = interp1(tv, speed, onset_t,  'linear', 'extrap');
        det.offset_speed = interp1(tv, speed, offset_t, 'linear', 'extrap');
        det.onset_dev    = hypot(sp0(1), sp0(2));
        det.offset_dev   = hypot(sp1(1), sp1(2));

        %Situation counts

        det.N_Onset_regular = N_onset_regular;
        det.N_Onset_release = N_onset_release;
        det.N_Onset_fail = N_onset_fail;
        det.N_Onset_early = N_onset_early;

        det.N_Offset_regular = N_offset_regular;
        det.N_Offset_release = N_offset_release;
        det.N_Offset_fail = N_offset_fail;
        det.N_Offset_early = N_offset_early;


        


        return
    

 
end


function [iStart, N_regular,N_release,N_fail,N_early] = findSaccadeRun(above, tv, nContig, lo, hi)
% Trace BACK from the upper bound hi (the approximate RT) toward lo and return
% the ONSET: the latest sample i in the window [lo, hi] (s, on the tv axis) that
% is a clean rising edge of the trigger `above` --
%     the nContig samples AT/AFTER i (i : i+nContig-1) are all TRUE   (over thr),
%     the nContig samples BEFORE i  (i-nContig : i-1)   are all FALSE (below thr).
%
% Requiring the below-threshold run just before the above-threshold run rejects
% points that were already elevated (drift / an earlier movement), and searching
% back from the approximate RT anchors the onset to the true baseline->saccade
% transition nearest the RT rather than the earliest blip after lo.
    ok = false;  iStart = NaN;
    i0 = find(tv >= lo, 1);
    %Condition counts
   N_regular = 0;%Count for regular detection case 
   N_release = 0;%Count for release detection case 
   N_fail = 0; %Count for failed detection in this round
   N_early = 0; %Count for trials the fix exit marker is over the end of eye trace window.
    if isempty(i0)
        N_fail = N_fail +1;
        disp('Onset detection Failed. Start time out of range. Check your prewindow setting: PRE_MS.');
        return;  
    end
    iHi = find(tv <= hi, 1, 'last');
    if isempty(iHi) || iHi < i0
        N_fail = N_fail +1;
        disp('Onset detection failed. End window empty or End window out of range.');
        
    return;  
    end

    % i needs the before-window (i-nContig : i-1) and the after-window
    % (i : i+nContig-1) both in range, so bound the scan accordingly.
    idxTop = find(above,1,'last');


    if isempty(idxTop)
        iTop = min(iHi, numel(above) - nContig + 1);
    else
        iTop = min([iHi, numel(above) - nContig + 1,idxTop]);
        
    end

    if numel(above) == iHi 
        disp('Saccade onset later than the fixation exit marker, consider to adjust postMS.')
        fprintf('Fix exit marker delayed: %d ms\n',(iHi-numel(above)));
        N_early = N_early+1;
    end
    
    idx = find(above,1,'first');
    if isempty(idx)
        iBot = max(max(i0, nContig + 1));
    else
        iBot = max(max(i0, nContig + 1),idx);
    end
    
    N_turing = floor(nContig/2);% turing point detection

    
    %Recursive search
    MaxSearch = 2;
    while ~ok && N_turing >= 0 && MaxSearch > 0
        %Search until find out the turing point
        for i = iTop:-1:iBot

            

           
            if all(above(i:i + nContig - 1)) && sum(~above(i - nContig:i - 1))> N_turing
            iStart = i;  ok = true;  
            if MaxSearch > 1
                N_regular = N_regular+1;
            else
                N_release = N_release + 1;
            end
            
            return
            end
        end
        N_turing = max(N_turing-1,0);
        MaxSearch = MaxSearch-1;

        if MaxSearch == 1 %Last chance, release the pre-criterium more
            N_turing = 0;
           
        end

    end

    if ~ok
       % iStart = iHi; detection failed, keep iStart a NaN 
         N_fail =  N_fail +1;
    end
end


function [iOff, ok,N_regular,N_release,N_fail,N_early] = findSaccadeEnd(speed, iCross, iMax, thr, nContig)
% First index in (iCross, iMax] where speed stays < thr for nContig samples.
% iMax bounds the search (e.g. the maxDur-from-onset boundary).
    ok = false;  
    iOff = NaN;
    below = speed < thr;
    N_turing = ceil(nContig/2);
    MaxSearch = 2;

    %Condition counts
   N_regular = 0;%Count for regular detection case 
   N_release = 0;%Count for release detection case
   N_fail = 0;%Count for failed detection case
   N_early = 0; %early detection of the points already below the baseline.

    if below(iCross)
        iOff = iCross;  
        ok = true;
        N_early = N_early+1;
        return 
    end
   

   
    while ~ok && N_turing >= 0 && MaxSearch > 0

        for i = (iCross + 1):min(iMax, numel(below) - nContig + 1)
            
            if all(~below(i - nContig:i-1)) && sum(below(i:i+nContig-1)) > N_turing

                iOff = i;  ok = true; 

                if MaxSearch > 1
                    N_regular = N_regular+1;
                else
                    N_release = N_release +1;
                end



                return
            end
            
        end

        N_turing = max(N_turing-1,0);
        MaxSearch = MaxSearch-1;
        if MaxSearch == 1
            N_turing = 0;
            
        end

    end



    if ~ok
         N_fail = N_fail +1;
    end

end


function tbl = buildTable(comments_data, RTtime, ampl, peakVel, startX, startY, endX, endY, durSac)
% Assemble the per-trial saccade-detail table.
%
% Keyed on (Session, Trial_number) copied straight from comments_data -- the
% same key GetPhotodiodeTiming's buildPDTable emits and SpikeTrialAlignmentCheck
% matches on, so the analyze-stage products all join to each other and to the
% comments table on identical columns.
%
% This replaces an earlier synthesized `Trial = (0:nTrials-1)'` column. That was
% a GLOBAL 0-based row index, not a trial number: Trial_number restarts at 0
% every session (on a real 3-session recording: 0..1805, 0..2473, 0..294), so the
% row index agreed with it only inside the first session and differed on 2769 of
% 4575 rows. Trial_number alone is not unique either -- only the (Session,
% Trial_number) pair is -- which is why both columns are carried.
    tbl = table(comments_data.Session, comments_data.Trial_number, ...
        RTtime, ampl, peakVel, startX, startY, endX, endY, durSac, ...
        'VariableNames', {'Session', 'Trial_number', 'RTtime', 'SaccadeAmplitude', ...
                          'PeakVelocity', 'StartX', 'StartY', 'EndX', 'EndY', ...
                          'SaccadeDuration'});
end


function ms = traceWindowMax(RTtime, durSac, padMs)
% Right-hand x limit (ms from the go cue) for the summary trace panels: the last
% saccade to END among the trials passed in, plus padMs of padding.
%
% Per-trial windows run out to Fixation_exited + POST_MS, which on the slowest
% trials is ~1.9 s -- far beyond any saccade -- so plotting the full axis would
% squash every trace into the left edge. Callers pass only the trials actually
% drawn on the panel, so the limit follows what is on screen rather than the one
% slowest trial in the session.
%
%   RTtime / durSac - onset and duration (s) of the plotted trials, NaN allowed
%   padMs           - padding past the last saccade end (ms)
% Returns padMs alone when nothing was detected among them.
    ms = max(RTtime + durSac, [], 'omitnan') * 1000 + padMs;
    if isempty(ms) || isnan(ms);  ms = padMs;  end
end


function payload = backfillPayload(payload)
% Add payload fields introduced after older RT.mat caches were written, so a
% cache hit draws the same figures as a fresh compute instead of silently losing
% the RT-outlier column.
%
% Pure, and derived from payload.RT alone -- it never needs the eye trace, which
% is exactly why rtOut can be recovered on the no-recompute path. Idempotent (the
% field is guarded), so it is safe to call on a freshly computed payload.
%
% maps / minAmp are deliberately NOT backfilled here: they need comments_data
% (target positions) and the eye trace respectively, neither of which is in the
% cache. plotRTFigures keeps its own guards + warnings for those.
    if ~isfield(payload, 'rtOut')
        [~, ~, payload.rtOut] = flagOutliers(payload.RT.SaccadeAmplitude, ...
            payload.RT.SaccadeDuration * 1000, payload.RT.RTtime * 1000, ...
            ~isnan(payload.RT.RTtime));
    end
end


function [ampOut, durOut, rtOut] = flagOutliers(amp, dur_ms, rt_ms, det)
% Flag abnormal detected saccades (all inputs/outputs are nTrials x 1):
%   ampOut - amplitude more than 3 SD from the detected-population mean
%   durOut - duration  more than 3 SD from the detected-population mean
%   rtOut  - RT        more than 3 SD from the detected-population mean
% Undetected trials (det false) are never flagged.
    ampMean = mean(amp(det), 'omitnan');
    ampSD   = std(amp(det),  'omitnan');
    durMean = mean(dur_ms(det), 'omitnan');
    durSD   = std(dur_ms(det),  'omitnan');
    rtMean  = mean(rt_ms(det), 'omitnan');
    rtSD    = std(rt_ms(det),  'omitnan');
    ampOut  = det & abs(amp - ampMean) > 3 * ampSD;
   %ampOut  = det & abs(amp - ampMean) > 4 * ampSD;
   % durOut  = det & (dur_ms < 20 | dur_ms > 95);
   durOut  = det & abs(dur_ms - durMean) > 3 * durSD ;
   rtOut   = det & abs(rt_ms  - rtMean)  > 3 * rtSD  ;
end


function h = computeRTHistogram(rt_ms, tsk, uT, binMs)
% Bin the detected RTs per task for the summary histogram, folding a sparse slow
% tail into a single overflow bar.
%
% A handful of very slow trials (RT ~1 s) would otherwise stretch the axis and
% squash the 150-350 ms mode into a few pixels. The cutoff is the 99th
% percentile rounded up to a whole bin; everything above it is pooled into one
% extra bar drawn one bin past the cutoff. The fold is only applied when the tail
% actually reaches far beyond the bulk (max > 1.5x the cutoff) -- a tight RT
% distribution keeps its full axis and gets no overflow bar.
%
%   rt_ms - nDet x 1 detected RTs (ms)
%   tsk   - nDet x 1 task label per RT (cellstr)
%   uT    - 1 x nTask unique task labels, in the figure's colour order
%   binMs - bin width (ms)
% Returns h with fields:
%   centers     - nBin x 1 bar centres (ms); the last one is the overflow bar
%                 when hasOverflow
%   counts      - nBin x nTask stacked counts
%   edges       - 1 x nBin+1 (or nBin) bin edges of the non-overflow part (ms)
%   cutoff      - overflow threshold (ms); RTs above it are pooled
%   hasOverflow - whether the last centers/counts row is the overflow bar
%   nOver       - number of RTs pooled into the overflow bar
    nTask = numel(uT);
    lo    = floor(min(rt_ms) / binMs) * binMs;
    hiAll = ceil( max(rt_ms) / binMs) * binMs;

    % 99th percentile without the Statistics Toolbox (prctile/quantile).
    srt = sort(rt_ms);
    p99 = srt(max(1, ceil(0.99 * numel(srt))));

    cutoff      = ceil(p99 / binMs) * binMs;
    hasOverflow = cutoff > max(lo, 0) && max(rt_ms) > 1.5 * cutoff;
    if ~hasOverflow
        cutoff = hiAll;
    end
    if cutoff <= lo;  cutoff = lo + binMs;  end

    h.edges   = lo:binMs:cutoff;
    h.centers = (h.edges(1:end-1) + binMs/2).';
    h.counts  = zeros(numel(h.centers), nTask);
    for g = 1:nTask
        h.counts(:, g) = histcounts(rt_ms(strcmp(tsk, uT{g})), h.edges);
    end

    h.cutoff      = cutoff;
    h.hasOverflow = hasOverflow;
    h.nOver       = sum(rt_ms > cutoff);
    if hasOverflow
        over = rt_ms > cutoff;
        h.centers(end+1, 1) = cutoff + binMs;       % one bin gap, then the bar
        h.counts(end+1, :)  = arrayfun(@(g) sum(over & strcmp(tsk, uT{g})), 1:nTask);
    end
end


function xy = positionColumns(comments_data, base)
% Per-trial [x y] (deg) from the <base>_x / <base>_y columns of comments_data,
% e.g. base = 'Target_1_position'. Returns an nTrials x 2 all-NaN matrix when
% either column is absent, so callers never have to special-case a missing field
% (guarded exactly like markerLocations in EyeCalibration.m).
    n  = height(comments_data);
    xy = nan(n, 2);
    cx = [base '_x'];  cy = [base '_y'];
    if all(ismember({cx, cy}, comments_data.Properties.VariableNames))
        xy = [comments_data.(cx)(:), comments_data.(cy)(:)];
    end
end


function maps = computeSaccadeMaps(RT, taskLabels, targetXY, fixXY, tasks_for_RT)
% Aggregate, per RT-saccade task, the data the saccade-map QC figure needs.
% Pure: bins nothing for display (that is the draw function's job) -- it only
% selects detected trials, pools endpoints, and averages peak velocity per
% distinct target location. Returns a struct array with one entry per task that
% has at least one detected saccade, each with fields:
%   task        - task name (char)
%   endPts      - m x 2 saccade end points (deg) of detected trials
%   startCenter - 1 x 2 mean saccade start point (deg) over detected trials
%   fixPt       - k x 2 distinct fixation locations (deg) used by these trials
%   targets     - g x 2 distinct target locations (deg)
%   targPV      - g x 1 mean peak velocity at each target location
%   targN       - g x 1 detected-trial count at each target location

    maps = struct('task', {}, 'endPts', {}, 'startCenter', {}, ...
                  'fixPt', {}, 'targets', {}, 'targPV', {}, 'targN', {});

    detected = ~isnan(RT.RTtime);
    for c = 1:numel(tasks_for_RT)
        task = tasks_for_RT{c};
        sel  = detected & strcmp(taskLabels, task);
        if ~any(sel);  continue;  end

        endPts      = [RT.EndX(sel),   RT.EndY(sel)];
        startCenter = [mean(RT.StartX(sel), 'omitnan'), ...
                       mean(RT.StartY(sel), 'omitnan')];
        fixPt       = uniqueXY(fixXY(sel, :));

        % Mean peak velocity per distinct target location.
        tgt = targetXY(sel, :);
        pv  = RT.PeakVelocity(sel);
        [targets, ~, grp] = unique(tgt(all(~isnan(tgt), 2), :), 'rows');
        pvValid = pv(all(~isnan(tgt), 2));
        g       = size(targets, 1);
        targPV  = nan(g, 1);
        targN   = zeros(g, 1);
        for k = 1:g
            inK       = grp == k;
            targPV(k) = mean(pvValid(inK), 'omitnan');
            targN(k)  = sum(inK);
        end

        maps(end+1) = struct('task', task, 'endPts', endPts, ...
            'startCenter', startCenter, 'fixPt', fixPt, ...
            'targets', targets, 'targPV', targPV, 'targN', targN);  %#ok<AGROW>
    end
end


function u = uniqueXY(xy)
% Distinct rows of xy (deg) with any-NaN rows dropped; [] when nothing remains.
    u = [];
    if isempty(xy);  return;  end
    u = unique(xy(all(~isnan(xy), 2), :), 'rows');
end


% =========================================================================
% Visualization subfunction (rendering only; no computation)
% =========================================================================

function plotSaccadeFigure(t, tv, dev_all, speed_all, dets, rtTable, taskLabels, ...
        plotN, units)
% One QC + summary figure, laid out as:
%   left column  - eye deviation (top) and speed profile (bottom), for plotN
%                  randomly-sampled detected trials (all if plotN is NaN),
%                  colored by task; each trace's saccade segment (onset->offset)
%                  over-drawn bold red, with onset (green) / end (red) dots.
%   top right    - RT distribution histogram (all detected trials)
%   bottom mid   - saccade amplitude vs peak velocity (the "main sequence")
%   bottom right - saccade amplitude vs duration
% Everything is pre-computed: trace matrices are indexed and the scatter/hist
% come straight off the RT table -- only the histogram's display binning happens
% here (via computeRTHistogram).
%
% The two trace panels are bounded on the right at the last saccade to END among
% the SAMPLED trials, plus TRACE_PAD_MS -- see traceWindowMax. Per-trial windows
% run out to Fixation_exited + POST_MS (~1.9 s on the slowest trial), so the full
% axis would squash every drawn trace into the left edge. Scoping the limit to
% the sample rather than to all detected trials keeps it tied to what is actually
% on screen, and means nothing about it has to be cached.

    TRACE_PAD_MS = 800;     % padding past the last plotted saccade end (ms)

    tt_ms = t  * 1000;
    tv_ms = tv * 1000;
    posUnit = strrep(units, '/s', '');          % 'deg' or 'uV'

    detIdx = find(cellfun(@(d) ~isempty(d) && d.detected, dets));
    if isempty(detIdx)
        warning('plotSaccadeFigure: no detected saccades to plot.');
        return
    end

    % Task -> colour, shared across every panel (built from all detected trials).
    uT   = unique(taskLabels(detIdx), 'stable');
    nT   = numel(uT);
    cmap = lines(max(nT, 1));
    colorOf = @(lbl) cmap(find(strcmp(uT, lbl), 1), :);

    % Sample only for the trace panels.
    sampIdx = detIdx;
    if ~isnan(plotN) && numel(sampIdx) > plotN
        sampIdx = sampIdx(randperm(numel(sampIdx), plotN));
    end

    % Right edge shared by both trace panels: driven by the sampled trials, and
    % never past the data itself.
    traceHi = min(tt_ms(end), traceWindowMax(rtTable.RTtime(sampIdx), ...
                                             rtTable.SaccadeDuration(sampIdx), ...
                                             TRACE_PAD_MS));

    figure('Name', 'Saccade detection & summary', 'Color', 'w');

    % Explicit axes positions so the two trace panels get a wide left column,
    % while the right side stacks the RT histogram over the two scatters.
    % [left bottom width height]
    posDev   = [0.06 0.58 0.42 0.37];
    posSpeed = [0.06 0.09 0.42 0.37];
    posHist  = [0.57 0.58 0.40 0.37];
    posSc1   = [0.57 0.09 0.17 0.37];
    posSc2   = [0.80 0.09 0.17 0.37];

    % ---------------------------------------------------------------------
    % Left top: eye deviation
    % ---------------------------------------------------------------------
    subplot('Position', posDev); hold on;
    for i = sampIdx(:).'
        col = colorOf(taskLabels{i});
        dv  = dev_all(i, :);
        plot(tt_ms, dv, '-', 'Color', [col 0.5], 'LineWidth', 0.5);
        seg = t >= dets{i}.onset_t & t <= dets{i}.offset_t;   % saccade segment
        plot(tt_ms(seg), dv(seg), '-', 'Color', 'r', 'LineWidth', 2);
        plot(dets{i}.onset_t  * 1000, dets{i}.onset_dev,  'o', ...
            'MarkerFaceColor', 'g', 'MarkerEdgeColor', 'k', 'MarkerSize', 5);
        plot(dets{i}.offset_t * 1000, dets{i}.offset_dev, 'o', ...
            'MarkerFaceColor', 'r', 'MarkerEdgeColor', 'k', 'MarkerSize', 5);
    end
    yl = ylim;  plot([0 0], yl, 'k:');  ylim(yl);            % go cue
    xlim([tt_ms(1) traceHi]);
    xlabel('Time from go cue (ms)');
    ylabel(sprintf('Deviation (%s)', posUnit));
    title('Smoothed eye deviation  |  bold red = saccade');
    hTask = gobjects(nT, 1);                                 % task legend
    for g = 1:nT
        hTask(g) = plot(nan, nan, '-', 'Color', cmap(g,:), 'LineWidth', 2);
    end
    legend(hTask, strrep(uT, '_', ' '), 'Location', 'best');
    set(gca, 'LineWidth', 1, 'FontSize', 11);
    hold off;

    % ---------------------------------------------------------------------
    % Left bottom: speed profile + threshold
    % ---------------------------------------------------------------------
    subplot('Position', posSpeed); hold on;
    for i = sampIdx(:).'
        col = colorOf(taskLabels{i});
        sp  = speed_all(i, :);
        plot(tv_ms, sp, '-', 'Color', [col 0.5], 'LineWidth', 0.5);
        seg = tv >= dets{i}.onset_t & tv <= dets{i}.offset_t;
        plot(tv_ms(seg), sp(seg), '-', 'Color', 'r', 'LineWidth', 2);
        plot(dets{i}.onset_t  * 1000, dets{i}.onset_speed,  'o', ...
            'MarkerFaceColor', 'g', 'MarkerEdgeColor', 'k', 'MarkerSize', 5);
        plot(dets{i}.offset_t * 1000, dets{i}.offset_speed, 'o', ...
            'MarkerFaceColor', 'r', 'MarkerEdgeColor', 'k', 'MarkerSize', 5);
    end
    xr = [tv_ms(1) min(tv_ms(end), traceHi)];  xlim(xr);
    yl = ylim;  plot([0 0], yl, 'k:');  ylim(yl);            % go cue
    % Per-trial detection threshold(s), dashed.
    thrs = unique(round(arrayfun(@(k) dets{k}.threshold, sampIdx(:)), 2));
    for th = thrs(:).'
        plot(xr, [th th], '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1);
    end
    xlabel('Time from go cue (ms)');
    ylabel(sprintf('Speed (%s)', units));
    title('Speed profile  |  dashed = threshold');
    set(gca, 'LineWidth', 1, 'FontSize', 11);
    hold off;

    % ---------------------------------------------------------------------
    % Summary data over ALL detected trials
    % ---------------------------------------------------------------------
    ok  = ~isnan(rtTable.RTtime);
    rt  = rtTable.RTtime(ok)          * 1000;    % ms
    amp = rtTable.SaccadeAmplitude(ok);
    pv  = rtTable.PeakVelocity(ok);
    dur = rtTable.SaccadeDuration(ok) * 1000;    % ms
    tsk = taskLabels(ok);

    % ---- top right: RT distribution, stacked by task --------------------
    % A sparse slow tail is folded into a single ">cutoff" bar so the mode keeps
    % most of the axis (see computeRTHistogram).
    subplot('Position', posHist); hold on;
    binMs = 10;
    h  = computeRTHistogram(rt, tsk, uT, binMs);
    hb = bar(h.centers, h.counts, 'stacked', 'EdgeColor', 'w');
    for g = 1:nT
        hb(g).FaceColor = cmap(g, :);
    end
    xlim([h.edges(1) h.centers(end) + binMs]);
    if h.hasOverflow
        % Re-label the last tick as the pooled ">cutoff" bar and mark the fold.
        xt = get(gca, 'XTick');
        xt = xt(xt <= h.cutoff);
        lbl = [arrayfun(@(v) sprintf('%g', v), xt, 'UniformOutput', false), ...
               {sprintf('>%g', h.cutoff)}];
        set(gca, 'XTick', [xt, h.centers(end)], 'XTickLabel', lbl);
        yl = ylim;
        plot((h.cutoff + binMs/2) * [1 1], yl, 'k:');  ylim(yl);
    end
    xlabel('RT (ms)');
    ylabel('Count');
    if h.hasOverflow
        title(sprintf('RT distribution  (n=%d, median=%.0f ms, %d > %g ms pooled)', ...
            numel(rt), median(rt), h.nOver, h.cutoff));
    else
        title(sprintf('RT distribution  (n=%d, median=%.0f ms)', numel(rt), median(rt)));
    end
    legend(hb, strrep(uT, '_', ' '), 'Location', 'best');
    set(gca, 'LineWidth', 1, 'FontSize', 11);
    hold off;

    % ---- bottom mid: amplitude vs peak velocity -------------------------
    subplot('Position', posSc1); hold on;
    for g = 1:nT
        k = strcmp(tsk, uT{g});
        plot(amp(k), pv(k), 'o', 'MarkerFaceColor', cmap(g,:), ...
            'MarkerEdgeColor', 'k', 'MarkerSize', 5);
    end
    xlabel(sprintf('Amplitude (%s)', posUnit));
    ylabel(sprintf('Peak velocity (%s)', units));
    title('Main sequence');
    set(gca, 'LineWidth', 1, 'FontSize', 11);
    hold off;

    % ---- bottom right: amplitude vs duration ----------------------------
    subplot('Position', posSc2); hold on;
    for g = 1:nT
        k = strcmp(tsk, uT{g});
        plot(amp(k), dur(k), 'o', 'MarkerFaceColor', cmap(g,:), ...
            'MarkerEdgeColor', 'k', 'MarkerSize', 5);
    end
    xlabel(sprintf('Amplitude (%s)', posUnit));
    ylabel('Duration (ms)');
    title('Amplitude vs duration');
    set(gca, 'LineWidth', 1, 'FontSize', 11);
    hold off;

    % Small sample-size label in the top-left corner (no super-title).
    if isnan(plotN)
        nLbl = sprintf('N = %d (all)', numel(detIdx));
    else
        nLbl = sprintf('N = %d (random)', numel(sampIdx));
    end
    annotation('textbox', [0.005 0.955 0.25 0.04], 'String', nLbl, ...
        'EdgeColor', 'none', 'FitBoxToText', 'on', 'FontSize', 11, ...
        'VerticalAlignment', 'top');
end


function plotErrorCheck(t, tv, dev_all, speed_all, dets, ampOut, durOut, rtOut, units)
% Error-check figure, 2 rows (deviation top / speed bottom) x 4 columns:
%   col 1 - trials that FAILED to yield an RT: tracker-noise rejects (red) plus
%           any other non-detected valid trial (blue). No onset/offset markers
%           (there is no detected saccade for these).
%   col 2 - amplitude outliers (> 3 SD from the detected mean), onset/offset marked.
%   col 3 - duration  outliers (> 3 SD from the detected mean), onset/offset marked.
%   col 4 - RT        outliers (> 3 SD from the detected mean), onset/offset marked.
% Pre-computed inputs; nothing is recomputed here.

    tt_ms   = t  * 1000;
    tv_ms   = tv * 1000;
    posUnit = strrep(units, '/s', '');

    % Failed-to-find-RT sets, derived from the per-trial detection results.
    noiseIdx = find(cellfun(@(d) ~isempty(d) &&  d.noiseReject, dets));
    otherIdx = find(cellfun(@(d) ~isempty(d) && ~isempty(d.tv) && ...
                                 ~d.detected && ~d.noiseReject, dets));
    ampIdx   = find(ampOut);
    durIdx   = find(durOut);
    rtIdx    = find(rtOut);

    if isempty(noiseIdx) && isempty(otherIdx) && isempty(ampIdx) && ...
            isempty(durIdx) && isempty(rtIdx)
        warning('plotErrorCheck: no failed or outlier saccades to plot.');
        return
    end

    RED = [1 0 0];   BLUE = [0 0 1]; GREEN = [0,1,0];

    figure('Name', 'Saccade error check', 'Color', 'w');

    % ===== Column 1: failed to find RT (noise + other) ===================
    subplot(2, 4, 1); hold on;
    drawErrTraces(tt_ms, dev_all, noiseIdx, RED,  dets, '', '');
    drawErrTraces(tt_ms, dev_all, otherIdx, BLUE, dets, '', '');
    finishErrPanel(tt_ms, 'Time from go cue (ms)', sprintf('Deviation (%s)', posUnit), ...
        sprintf('Failed RT  (noise=%d, other=%d)', numel(noiseIdx), numel(otherIdx)));
    hN = plot(nan, nan, '-', 'Color', RED,  'LineWidth', 2);
    hO = plot(nan, nan, '-', 'Color', BLUE, 'LineWidth', 2);
    legend([hN hO], {'noise reject', 'other (no RT)'}, 'Location', 'best');
    hold off;

    subplot(2, 4, 5); hold on;
    drawErrTraces(tv_ms, speed_all, noiseIdx, RED,  dets, '', '');
    drawErrTraces(tv_ms, speed_all, otherIdx, BLUE, dets, '', '');
    finishErrPanel(tv_ms, 'Time from go cue (ms)', sprintf('Speed (%s)', units), ...
        'Failed RT: speed profile');
    hold off;

    % ===== Columns 2-4: amplitude / duration / RT outliers ===============
    % Same pair of panels per outlier kind, so drive them from one table.
    cols = { 2, ampIdx, 'Amplitude'; ...
             3, durIdx, 'Duration'; ...
             4, rtIdx,  'RT' };
    for c = 1:size(cols, 1)
        col = cols{c, 1};  idx = cols{c, 2};  name = cols{c, 3};

        subplot(2, 4, col); hold on;
        drawErrTraces(tt_ms, dev_all, idx, GREEN, dets, 'onset_dev', 'offset_dev');
        finishErrPanel(tt_ms, 'Time from go cue (ms)', ...
            sprintf('Deviation (%s)', posUnit), ...
            sprintf('%s outliers  (n=%d)', name, numel(idx)));
        hold off;

        subplot(2, 4, col + 4); hold on;
        drawErrTraces(tv_ms, speed_all, idx, GREEN, dets, 'onset_speed', 'offset_speed');
        finishErrPanel(tv_ms, 'Time from go cue (ms)', sprintf('Speed (%s)', units), ...
            sprintf('%s outliers: speed profile', name));
        hold off;
    end

    annotation('textbox', [0.005 0.965 0.9 0.03], 'String', sprintf( ...
        'Failed: noise=%d, other=%d   |   Outliers: amp>3SD=%d, dur>3SD=%d, RT>3SD=%d', ...
            numel(noiseIdx), numel(otherIdx), numel(ampIdx), numel(durIdx), ...
            numel(rtIdx)), ...
        'EdgeColor', 'none', 'FitBoxToText', 'on', 'FontSize', 10, ...
        'VerticalAlignment', 'top');
end


function drawErrTraces(xms, mat, idx, col, dets, onField, offField)
% Plot rows `idx` of `mat` against xms in colour col. If onField/offField are
% non-empty, overplot the onset (green) and offset (black) markers from dets --
% skipped for failed trials, whose onset/offset are NaN.
    for i = idx(:).'
        plot(xms, mat(i, :), '-', 'Color', [col 0.6], 'LineWidth', 0.75);
        if ~isempty(onField) && ~isnan(dets{i}.onset_t)
            plot(dets{i}.onset_t  * 1000, dets{i}.(onField),  'o', ...
                'MarkerFaceColor', 'g', 'MarkerEdgeColor', 'k', 'MarkerSize', 5);
            plot(dets{i}.offset_t * 1000, dets{i}.(offField), 'o', ...
                'MarkerFaceColor', 'k', 'MarkerEdgeColor', 'k', 'MarkerSize', 5);
        end
    end
end


function finishErrPanel(xms, xlab, ylab, ttl)
% Shared axes cosmetics for one error-check panel: go-cue line, limits, labels.
    yl = ylim;
    plot([0 0], yl, 'k:');  ylim(yl);
    xlim([xms(1) xms(end)]);
    xlabel(xlab);  ylabel(ylab);  title(ttl);
    set(gca, 'LineWidth', 1, 'FontSize', 10);
end


function plotMinAmplitudeTrial(minAmp, rtTable, dets, units)
% Render-only single-trial check on the SMALLEST detected saccade -- the trial
% most likely to be a false positive. Three stacked panels over that trial's own
% window: eye X, eye Y and speed, each with the detected onset marked (red o).
% Everything is pre-computed: the raw aligned position comes from minAmp, the
% speed profile and the interpolated onset speed from that trial's det.
    k   = minAmp.trial;
    det = dets{k};
    if isempty(det) || isempty(det.tv);  return;  end

    t_ms    = minAmp.t * 1000;
    tv_ms   = det.tv   * 1000;
    rt_ms   = rtTable.RTtime(k) * 1000;
    posUnit = strrep(units, '/s', '');           % 'deg' or 'uV'

    figure('Name', 'Min-amplitude trial', 'Color', 'w');

    panels = { minAmp.x, sprintf('Eye X (%s)', posUnit), rtTable.StartX(k); ...
               minAmp.y, sprintf('Eye Y (%s)', posUnit), rtTable.StartY(k) };
    for p = 1:2
        subplot(3, 1, p); hold on;
        plot(t_ms, panels{p, 1}, '-', 'Color', [0 0 0 0.7], 'LineWidth', 0.75);
        plot(rt_ms, panels{p, 3}, 'or', 'MarkerFaceColor', 'r', 'MarkerSize', 5);
        yl = ylim;  plot([0 0], yl, 'k:');  ylim(yl);        % go cue
        xlim([t_ms(1) t_ms(end)]);
        xlabel('Time from go cue (ms)');  ylabel(panels{p, 2});
        set(gca, 'LineWidth', 1, 'FontSize', 10);
        hold off;
    end

    subplot(3, 1, 3); hold on;
    plot(tv_ms, det.speed, '-', 'Color', [0 0 0 0.7], 'LineWidth', 0.75);
    % det.onset_speed is the speed interpolated at the onset, so this marker
    % needs no sampling-rate assumption.
    plot(rt_ms, det.onset_speed, 'or', 'MarkerFaceColor', 'r', 'MarkerSize', 5);
    plot([tv_ms(1) tv_ms(end)], [det.threshold det.threshold], '--', ...
        'Color', [0.5 0.5 0.5], 'LineWidth', 1);
    yl = ylim;  plot([0 0], yl, 'k:');  ylim(yl);
    xlim([tv_ms(1) tv_ms(end)]);
    xlabel('Time from go cue (ms)');  ylabel(sprintf('Speed (%s)', units));
    set(gca, 'LineWidth', 1, 'FontSize', 10);
    hold off;

    annotation('textbox', [0.005 0.955 0.9 0.04], 'String', sprintf( ...
        ['Smallest detected saccade  |  trial row %d (Session %s, Trial %d)  |  ' ...
         'amp = %.2f %s, RT = %.0f ms, dur = %.0f ms'], ...
        k, string(rtTable.Session(k)), rtTable.Trial_number(k), ...
        rtTable.SaccadeAmplitude(k), posUnit, rt_ms, ...
        rtTable.SaccadeDuration(k) * 1000), ...
        'EdgeColor', 'none', 'FitBoxToText', 'on', 'FontSize', 10, ...
        'VerticalAlignment', 'top');
end


function plotSaccadeMapsFigure(maps, units, opts)
% Render-only saccade-map QC figure, laid out as 2 rows x nTask columns (each
% RT-saccade task in its own column). All data is pre-aggregated in
% computeSaccadeMaps; only the display binning / interpolation happens here.
%   Top row    - 2-D heatmap of the saccade-endpoint distribution, with the
%                target locations (o), fixation point (square) and the mean
%                saccade start point (x) overlaid.
%   Bottom row - 2-D heatmap of mean peak velocity per target location.
% opts.EndpointStyle : 'hist' (binned counts) | 'kde' (gaussian-smoothed).
% opts.PeakVelStyle  : 'surface' (griddata) | 'dots' (colored markers).

    posUnit = strrep(units, '/s', '');          % 'deg'
    nTask   = numel(maps);

    % Shared peak-velocity color range across all task columns, so the bottom-row
    % colors are comparable between tasks (a fast target in one task looks the
    % same as an equally fast target in another).
    allPV = vertcat(maps.targPV);
    pvClim = [min(allPV, [], 'omitnan'), max(allPV, [], 'omitnan')];
    if ~all(isfinite(pvClim)) || pvClim(1) == pvClim(2)
        pvClim = [];                            % degenerate -> let each panel autoscale
    end

    fig = figure('Name', 'Saccade endpoint & peak-velocity maps', 'Color', 'w');
    tl  = tiledlayout(fig, 2, nTask, 'TileSpacing', 'compact', 'Padding', 'compact');

    for c = 1:nTask
        M = maps(c);

        % ---- top: endpoint distribution heatmap -------------------------
        ax = nexttile(tl, c);
        drawEndpointMap(ax, M, posUnit, opts.EndpointStyle);
        title(ax, sprintf('%s  (n=%d)', strrep(M.task, '_', ' '), size(M.endPts, 1)));

        % ---- bottom: peak velocity per target location ------------------
        ax = nexttile(tl, nTask + c);
        drawPeakVelMap(ax, M, posUnit, units, opts.PeakVelStyle, pvClim);
    end

    title(tl, 'Saccade endpoints (top) & peak velocity by target (bottom)');
end


function drawEndpointMap(ax, M, posUnit, style)
% One endpoint-distribution panel: a 2-D density heatmap of M.endPts with the
% targets (o), fixation (square) and mean start point (x) drawn on top.
    hold(ax, 'on');

    % Frame the panel on the targets/fixation (the region of interest); endpoints
    % that stray far on bad trials are clipped rather than allowed to shrink it.
    anchor = [M.targets; M.fixPt; M.startCenter];
    anchor = anchor(all(~isnan(anchor), 2), :);
    if isempty(anchor);  anchor = M.endPts;  end
    r = max(abs(anchor(:)), [], 'omitnan') + 4;
    if isempty(r) || ~isfinite(r) || r <= 0;  r = 15;  end

    % Bin count adapts to the number of endpoints: a fixed fine grid leaves
    % each bin holding 0-1 trials on sparse sessions (a discrete, speckled map),
    % so coarsen the grid when there are few trials and refine it when there are
    % many. Clamped to [8, 30] bins.
    pts   = M.endPts(all(~isnan(M.endPts), 2), :);
    nPts  = size(pts, 1);
    nBins = min(30, max(8, round(2 * sqrt(nPts))));
    edges = linspace(-r, r, nBins + 1);
    ctrs  = edges(1:end-1) + diff(edges(1:2)) / 2;

    if ~isempty(pts)
        counts = histcounts2(pts(:,1), pts(:,2), edges, edges);   % X by Y
        total  = sum(counts(:));
        if total > 0;  counts = counts / total;  end             % -> proportion
        dens   = counts.';                                        % rows=Y for imagesc
        if strcmp(style, 'kde')
            %SIGMA = 5; 
            %dens = smoothDensity(dens,SIGMA);
            dens = smoothDensity(dens);
        end
        him = imagesc(ax, ctrs, ctrs, dens);
        set(him, 'AlphaData', dens > 0);                          % empty bins clear
    end
    colormap(ax, parula);
    cb = colorbar(ax);  cb.Label.String = 'Proportion';

    % Overlays: targets (o), fixation (square), mean start point (x).
    h = gobjects(0);  lbl = {};
    if ~isempty(M.targets)
        h(end+1) = plot(ax, M.targets(:,1), M.targets(:,2), 'o', ...
            'MarkerEdgeColor', 'r', 'MarkerSize', 5, 'LineWidth', 1.5);
        lbl{end+1} = 'target';
    end
    if ~isempty(M.fixPt)
        h(end+1) = plot(ax, M.fixPt(:,1), M.fixPt(:,2), 's', ...
            'MarkerEdgeColor', 'k', 'MarkerSize', 5, 'LineWidth', 1.5);
        lbl{end+1} = 'fixation';
    end
    if all(~isnan(M.startCenter))
        % Magenta so the start marker reads on both the white empty-bin
        % background (near fixation, where endpoint density is ~0) and the
        % parula density fill.
        h(end+1) = plot(ax, M.startCenter(1), M.startCenter(2), 'x', ...
            'MarkerEdgeColor', [1 0 1], 'MarkerSize', 14, 'LineWidth', 2.5);
        lbl{end+1} = 'start (mean)';
    end

    axis(ax, 'equal');
    xlim(ax, [-r r]);  ylim(ax, [-r r]);
    xlabel(ax, sprintf('Eye X (%s)', posUnit));
    ylabel(ax, sprintf('Eye Y (%s)', posUnit));
    if ~isempty(h);  legend(ax, h, lbl, 'Location', 'southoutside', ...
            'Orientation', 'horizontal', 'FontSize', 8);  end
    set(ax, 'LineWidth', 1, 'FontSize', 10, 'YDir', 'normal');
    hold(ax, 'off');
end


function drawPeakVelMap(ax, M, posUnit, units, style, pvClim)
% One peak-velocity-per-target panel: color = mean peak velocity at each target
% location, as a griddata surface ('surface') or discrete colored dots ('dots').
% Falls back to dots when there are too few targets to interpolate.
% pvClim (optional [lo hi]) fixes the color range so every task shares one scale;
% [] lets the panel autoscale.
    if nargin < 6;  pvClim = [];  end
    hold(ax, 'on');

    xy = M.targets;  pv = M.targPV;
    ok = all(~isnan(xy), 2) & ~isnan(pv);
    xy = xy(ok, :);  pv = pv(ok);

    if isempty(xy)
        text(ax, 0.5, 0.5, 'no targets', 'Units', 'normalized', ...
            'HorizontalAlignment', 'center');
        axis(ax, 'square');  set(ax, 'LineWidth', 1, 'FontSize', 10);
        hold(ax, 'off');  return
    end

    useSurface = strcmp(style, 'surface') && size(xy, 1) >= 3;
    if useSurface
        % Display-only interpolation over the sampled target space (the same
        % pattern as drawHitRateMaps in behaviorCheck.m); NaN outside the convex
        % hull leaves unexplored screen blank rather than extrapolated.
        pad = 2;
        gx  = linspace(min(xy(:,1))-pad, max(xy(:,1))+pad, 120);
        gy  = linspace(min(xy(:,2))-pad, max(xy(:,2))+pad, 120);
        [GX, GY] = meshgrid(gx, gy);
        GZ  = griddata(xy(:,1), xy(:,2), pv, GX, GY, 'linear');
        him = imagesc(ax, gx, gy, GZ);
        set(him, 'AlphaData', ~isnan(GZ));
        scatter(ax, xy(:,1), xy(:,2), 15, 'k', 'LineWidth', 1);   % target markers
    else
        scatter(ax, xy(:,1), xy(:,2), 100, pv, 'filled', ...
            'MarkerEdgeColor', 'k', 'LineWidth', 0.75);
    end

    colormap(ax, parula);
    if ~isempty(pvClim);  clim(ax, pvClim);  end     % shared range across tasks
    cb = colorbar(ax);  cb.Label.String = sprintf('Peak velocity (%s)', units);
    axis(ax, 'equal');
    r = max(abs(xy(:)), [], 'omitnan') + 4;
    xlim(ax, [-r r]);  ylim(ax, [-r r]);
    xlabel(ax, sprintf('Target X (%s)', posUnit));
    ylabel(ax, sprintf('Target Y (%s)', posUnit));
    set(ax, 'LineWidth', 1, 'FontSize', 10, 'YDir', 'normal');
    hold(ax, 'off');
end


function out = smoothDensity(dens,sigma)
% Gaussian-smooth a 2-D density for the 'kde' endpoint style. Uses imgaussfilt
% when the Image Processing Toolbox is available, else a small separable
% gaussian via conv2 so the plot never hard-depends on that toolbox.
    if nargin < 2
        sigma = 1.5; %default
    end

    if exist('imgaussfilt', 'file') == 2
        out = imgaussfilt(dens, sigma);
        return
    end

    radius = ceil(3 * sigma);
    x = -radius:radius;

    g = exp(-(x.^2) / (2 * sigma^2));
    g = g / sum(g);
    out = conv2(g, g, dens, 'same');
end
