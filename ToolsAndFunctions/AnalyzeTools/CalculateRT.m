function RT = CalculateRT(caled_eyes, comments_data, plotFlag, plotN, errorCheck, savePath, reCompute, varargin)
% Detect the saccadic reaction time (RT) of each trial from the eye trace.
%
% For every saccade-task trial the eye trace is aligned to the go cue
% (Fixation_point_off), the 2D eye speed is thresholded, and the saccade onset
% is extrapolated back to the pre-saccade baseline to give a sub-sample RT.
% Per-trial saccade metrics are returned as a table.
%
%   caled_eyes    - calibrated eye product from EyeCalibration:
%                     .data (chan x nTrials x maxSamples, eye X/Y on chans 1/2)
%                     .timeseq.relative_time (1 x maxSamples, s; 0 at Start)
%                     .timeseq.alignedrawtime (nTrials x 1, s; absolute Start)
%                     .info.samplingrate (Hz)
%                     .cal.applied (logical), .cal.units ('deg' | 'uV')
%                   When no analog was recorded, caled_eyes has only
%                   .cal.applied = false and NO .data field.
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
% Returns RT, an nTrials x 9 table of per-trial saccade metrics (one row per trial
% in comments_data, in order):
%   Trial, RTtime (s from go cue), SaccadeAmplitude, PeakVelocity,
%   StartX, StartY, EndX, EndY, SaccadeDuration.
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

    p.addParameter('EndpointStyle', 'hist', ...
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

    % ---- detection settings ------------------------------------------------
    PRE_MS   = 200;             % window kept before the go cue
    POST_MS  = 500;             % window kept after the go cue
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
    marker_rel(~isValid) = NaN;                 % AlignEyeTrace NaNs these rows

    % One shared axis, 0 at the go cue.
    [aligned_eye, t] = AlignEyeTrace(eye_x, eye_y, eye_time, marker_rel, PRE_MS, POST_MS);

    % Behavioral-marker times in the aligned (go-cue = 0) frame. Onset is anchored
    % to the approximate RT, the end to Choicetime.
    approxRT   = comments_data.Fixation_exited - comments_data.Fixation_point_off;   % s from go
    choice_rel = comments_data.Choicetime     - comments_data.Fixation_point_off;   % s from go

    dets = cell(nTrials, 1);            % kept for the QC plot
    for i = find(isValid).'
        x = aligned_eye.x(i, :);
        y = aligned_eye.y(i, :);
        if all(isnan(x));  continue;  end       % window fell outside recorded data

        mk  = struct('approxRT', approxRT(i), 'choicetime', choice_rel(i));
        det = detectSaccade(t, x, y, cfg, mk, useDegThr);
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
    end

    fprintf('%d real RT detected from the eye trace (of %d valid trials).\n', ...
        sum(~isnan(RTtime)), sum(isValid));

    RTtable = buildTable(nTrials, RTtime, ampl, peakVel, ...
                         startX, startY, endX, endY, durSac);

    % Trials rejected because tracker noise landed inside the detected saccade
    % (RT already NaN for these).
    noiseTrials = find(cellfun(@(d) ~isempty(d) && d.noiseReject, dets));
    if ~isempty(noiseTrials)
        fprintf('%d trial(s) rejected: noise inside the saccade -> RT set NaN.\n', ...
            numel(noiseTrials));
    end

    % Flag abnormal (outlier) saccades: amplitude > 3 SD from the population
    % mean, and duration > 3 SD from the population. Returned for downstream QC.
    [ampOut, durOut] = flagOutliers(ampl, durSac * 1000, ~isnan(RTtime));
    %
    outliers = struct('trials',    find(ampOut | durOut), ...
                         'amplitude', find(ampOut), ...
                         'duration',  find(durOut));
    %}
    
    fprintf('%d abnormal saccade(s) flagged (amp>3SD: %d, dur>3SD: %d).\n', ...
        numel(outliers.trials), numel(outliers.amplitude), numel(outliers.duration));

    hasTrace = any(cellfun(@(d) ~isempty(d) && ~isempty(d.tv), dets));

    % Per-trial target / fixation location (deg), for the saccade-map QC figure.
    % Only meaningful when calibrated (endpoints and targets share the deg frame).
    targetXY = positionColumns(comments_data, 'Target_1_position');
    fixXY    = positionColumns(comments_data, 'Fixation_position');
    maps     = computeSaccadeMaps(RTtable, comments_data.Task, targetXY, fixXY, ...
                                  tasks_for_RT);

    payload  = struct('RT', RTtable, 'units', units, 't', t, 'dets', {dets}, ...
        'ampOut', ampOut, 'durOut', durOut, ...
        'taskLabels', {comments_data.Task}, 'hasTrace', hasTrace, ...
        'calApplied', useDegThr, 'maps', {maps});
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
    % render-only.
    tv        = dets{traced(1)}.tv;
    dev_all   = nan(nTrials, numel(t));    % nTrials x nSamp (smoothed)
    speed_all = nan(nTrials, numel(tv));
    for i = traced.'
        dev_all(i, :)   = dets{i}.dev;
        speed_all(i, :) = dets{i}.speed;
    end
    plotSaccadeFigure(t, tv, dev_all, speed_all, dets, payload.RT, ...
        payload.taskLabels, plotN, payload.units);
    if errorCheck
        plotErrorCheck(t, tv, dev_all, speed_all, dets, ...
            payload.ampOut, payload.durOut, payload.units);
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
        'speed', [], 'tv', [], 'dev', [], 'onset_speed', NaN, 'offset_speed', NaN, ...
        'onset_dev', NaN, 'offset_dev', NaN, 'noiseReject', false, 'markerBased', false);

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
    % rejects included) still carries speed/tv/dev -- the error-check figure uses
    % it to draw the trials that never produced an RT.
    det.speed = speed;  det.tv = tv;  det.dev = dev;

    % Hard gate (before any detection): if tracker noise appears anywhere in the
    % [noiseWin] window after the go signal, this trial's RT is unanalysable --
    % reject it outright (det.detected stays false -> RT NaN).
    if any(noiseMask & tv >= noiseWin(1) & tv <= noiseWin(2))
        det.noiseReject = true;
        return
    end
   % dev_tv = (dev(1:end-1) + dev(2:end)) / 2;     % on the speed axis tv (nSamp-1)

    % ---- baseline over the pre-saccade window ---------------------------
    inBase = tv >= baseWin(1) & tv <= baseWin(2);
    base_mean = mean(speed(inBase),  'omitnan');
    base_sd   = std(speed(inBase),   'omitnan');
    %base_dev  = mean(dev_tv(inBase), 'omitnan');
    %inBaseT   = t >= baseWin(1) & t <= baseWin(2);       % baseline on the position axis
    %base_x    = mean(xs(inBaseT), 'omitnan');            % baseline gaze position
    %base_y    = mean(ys(inBaseT), 'omitnan');
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
    iTrig = findSaccadeRun(crit.trig, tv, nContig, onsetBack, onsetHi);
    speed_level = crit.level;

    
        % Trace back from the trigger to where the speed crossed speed_level on
        % the way up -- the start of the fast phase.
        iCross = iTrig;
        while iCross > 1 && speed(iCross - 1) >= speed_level
            iCross = iCross - 1;
        end

        % ---- find out the rising edge back to baseline ----------
        iBase = iCross;
        while iBase > 1 && speed(iBase - 1) > thr3sd
            iBase = iBase - 1;
        end
        
        onset_t = tv(iBase); 

        
       
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
            [iDown, offOk] = findSaccadeEnd(speed, iEndStart, iDownMax, end_thr, nContig);
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
            iOffBase = iEndStart;
        end
        
        while iOffBase > 1 && speed(iOffBase + 1) > thr3sd
              iOffBase = iOffBase + 1;
              if iOffBase == length(speed)
                    break;
              end
        end
        

            offset_t = tv(iOffBase);
            iPeakEnd = iOffBase;
            
        
        

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
        det.dev          = dev;                    % smoothed eye deviation trace
        det.onset_speed  = interp1(tv, speed, onset_t,  'linear', 'extrap');
        det.offset_speed = interp1(tv, speed, offset_t, 'linear', 'extrap');
        det.onset_dev    = hypot(sp0(1), sp0(2));
        det.offset_dev   = hypot(sp1(1), sp1(2));
        return
    

 
end


function iStart = findSaccadeRun(above, tv, nContig, lo, hi)
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
    if isempty(i0);  return;  end
    iHi = find(tv <= hi, 1, 'last');
    if isempty(iHi) || iHi < i0;  return;  end

    % i needs the before-window (i-nContig : i-1) and the after-window
    % (i : i+nContig-1) both in range, so bound the scan accordingly.
    iTop = min(iHi, numel(above) - nContig + 1);
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
            iStart = i;  ok = true;  return
            end
        end
        N_turing = max(N_turing-1,0);
        MaxSearch = MaxSearch-1;

        if MaxSearch == 1 %Last chance, release the pre-criterium more
            N_turing = 0;
        end

    end

    if ~ok
        iStart = iHi;
    end
end


function [iOff, ok] = findSaccadeEnd(speed, iCross, iMax, thr, nContig)
% First index in (iCross, iMax] where speed stays < thr for nContig samples.
% iMax bounds the search (e.g. the maxDur-from-onset boundary).
    ok = false;  
    iOff = NaN;
    below = speed < thr;
    N_turing = ceil(nContig/2);
    MaxSearch = 2;

    if below(iCross)
        iOff = iCross;  
        ok = true;
        return 
    end

    while ~ok && N_turing >= 0 && MaxSearch > 0

        for i = (iCross + 1):min(iMax, numel(below) - nContig + 1)
            
            if all(~below(i - nContig:i-1)) && sum(below(i:i+nContig-1)) > N_turing

                iOff = i;  ok = true;  return
            end
            
        end

        N_turing = max(N_turing-1,0);
        MaxSearch = MaxSearch-1;
        if MaxSearch == 1
            N_turing = 0;
        end

    end

end


function tbl = buildTable(nTrials, RTtime, ampl, peakVel, startX, startY, endX, endY, durSac)
% Assemble the per-trial saccade-detail table.
    Trial = (1:nTrials).';
    tbl = table(Trial, RTtime, ampl, peakVel, startX, startY, endX, endY, durSac, ...
        'VariableNames', {'Trial', 'RTtime', 'SaccadeAmplitude', 'PeakVelocity', ...
                          'StartX', 'StartY', 'EndX', 'EndY', 'SaccadeDuration'});
end


function [ampOut, durOut] = flagOutliers(amp, dur_ms, det)
% Flag abnormal detected saccades (all inputs/outputs are nTrials x 1):
%   ampOut - amplitude more than 3 SD from the detected-population mean
%   durOut - duration below 20 ms or above 90 ms
% Undetected trials (det false) are never flagged.
    ampMean = mean(amp(det), 'omitnan');
    ampSD   = std(amp(det),  'omitnan');
    durMean = mean(dur_ms(det), 'omitnan');
    durSD   = std(dur_ms(det),  'omitnan');
    ampOut  = det & abs(amp - ampMean) > 3 * ampSD;
   %ampOut  = det & abs(amp - ampMean) > 4 * ampSD;
   % durOut  = det & (dur_ms < 20 | dur_ms > 95);
   durOut  = det & abs(dur_ms - durMean) > 3 * durSD ;
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

function plotSaccadeFigure(t, tv, dev_all, speed_all, dets, rtTable, taskLabels, plotN, units)
% One QC + summary figure, laid out as:
%   left column  - eye deviation (top) and speed profile (bottom), for plotN
%                  randomly-sampled detected trials (all if plotN is NaN),
%                  colored by task; each trace's saccade segment (onset->offset)
%                  over-drawn bold red, with onset (green) / end (red) dots.
%   top right    - RT distribution histogram (all detected trials)
%   bottom mid   - saccade amplitude vs peak velocity (the "main sequence")
%   bottom right - saccade amplitude vs duration
% Everything is pre-computed: trace matrices are indexed and the scatter/hist
% come straight off the RT table -- nothing is recomputed here.

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
    xlim([tt_ms(1) tt_ms(end)]);
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
    xr = [tv_ms(1) tv_ms(end)];  xlim(xr);
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
    subplot('Position', posHist); hold on;
    lo = floor(min(rt) / 10) * 10;
    hi = ceil( max(rt) / 10) * 10;
    if hi <= lo;  hi = lo + 10;  end
    edges   = lo:10:hi;
    centers = edges(1:end-1) + 5;
    counts  = zeros(numel(centers), nT);            % bins x task
    for g = 1:nT
        counts(:, g) = histcounts(rt(strcmp(tsk, uT{g})), edges);
    end
    hb = bar(centers, counts, 'stacked', 'EdgeColor', 'w');
    for g = 1:nT
        hb(g).FaceColor = cmap(g, :);
    end
    xlabel('RT (ms)');
    ylabel('Count');
    title(sprintf('RT distribution  (n=%d, median=%.0f ms)', numel(rt), median(rt)));
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


function plotErrorCheck(t, tv, dev_all, speed_all, dets, ampOut, durOut, units)
% Error-check figure, 2 rows (deviation top / speed bottom) x 3 columns:
%   col 1 - trials that FAILED to yield an RT: tracker-noise rejects (red) plus
%           any other non-detected valid trial (blue). No onset/offset markers
%           (there is no detected saccade for these).
%   col 2 - amplitude outliers (> 3 SD from the detected mean), onset/offset marked.
%   col 3 - duration  outliers (> 3 SD from the detected mean), onset/offset marked.
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

    if isempty(noiseIdx) && isempty(otherIdx) && isempty(ampIdx) && isempty(durIdx)
        warning('plotErrorCheck: no failed or outlier saccades to plot.');
        return
    end

    RED = [1 0 0];   BLUE = [0 0 1];

    figure('Name', 'Saccade error check', 'Color', 'w');

    % ===== Column 1: failed to find RT (noise + other) ===================
    subplot(2, 3, 1); hold on;
    drawErrTraces(tt_ms, dev_all, noiseIdx, RED,  dets, '', '');
    drawErrTraces(tt_ms, dev_all, otherIdx, BLUE, dets, '', '');
    finishErrPanel(tt_ms, 'Time from go cue (ms)', sprintf('Deviation (%s)', posUnit), ...
        sprintf('Failed RT  (noise=%d, other=%d)', numel(noiseIdx), numel(otherIdx)));
    hN = plot(nan, nan, '-', 'Color', RED,  'LineWidth', 2);
    hO = plot(nan, nan, '-', 'Color', BLUE, 'LineWidth', 2);
    legend([hN hO], {'noise reject', 'other (no RT)'}, 'Location', 'best');
    hold off;

    subplot(2, 3, 4); hold on;
    drawErrTraces(tv_ms, speed_all, noiseIdx, RED,  dets, '', '');
    drawErrTraces(tv_ms, speed_all, otherIdx, BLUE, dets, '', '');
    finishErrPanel(tv_ms, 'Time from go cue (ms)', sprintf('Speed (%s)', units), ...
        'Failed RT: speed profile');
    hold off;

    % ===== Column 2: amplitude outliers ==================================
    subplot(2, 3, 2); hold on;
    drawErrTraces(tt_ms, dev_all, ampIdx, RED, dets, 'onset_dev', 'offset_dev');
    finishErrPanel(tt_ms, 'Time from go cue (ms)', sprintf('Deviation (%s)', posUnit), ...
        sprintf('Amplitude outliers  (n=%d)', numel(ampIdx)));
    hold off;

    subplot(2, 3, 5); hold on;
    drawErrTraces(tv_ms, speed_all, ampIdx, RED, dets, 'onset_speed', 'offset_speed');
    finishErrPanel(tv_ms, 'Time from go cue (ms)', sprintf('Speed (%s)', units), ...
        'Amplitude outliers: speed profile');
    hold off;

    % ===== Column 3: duration outliers ===================================
    subplot(2, 3, 3); hold on;
    drawErrTraces(tt_ms, dev_all, durIdx, BLUE, dets, 'onset_dev', 'offset_dev');
    finishErrPanel(tt_ms, 'Time from go cue (ms)', sprintf('Deviation (%s)', posUnit), ...
        sprintf('Duration outliers  (n=%d)', numel(durIdx)));
    hold off;

    subplot(2, 3, 6); hold on;
    drawErrTraces(tv_ms, speed_all, durIdx, BLUE, dets, 'onset_speed', 'offset_speed');
    finishErrPanel(tv_ms, 'Time from go cue (ms)', sprintf('Speed (%s)', units), ...
        'Duration outliers: speed profile');
    hold off;

    annotation('textbox', [0.005 0.965 0.7 0.03], 'String', ...
        sprintf('Failed: noise=%d, other=%d   |   Outliers: amp>3SD=%d, dur>3SD=%d', ...
            numel(noiseIdx), numel(otherIdx), numel(ampIdx), numel(durIdx)), ...
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
            'MarkerEdgeColor', 'r', 'MarkerSize', 10, 'LineWidth', 1.5);
        lbl{end+1} = 'target';
    end
    if ~isempty(M.fixPt)
        h(end+1) = plot(ax, M.fixPt(:,1), M.fixPt(:,2), 's', ...
            'MarkerEdgeColor', 'k', 'MarkerSize', 10, 'LineWidth', 1.5);
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
        scatter(ax, xy(:,1), xy(:,2), 25, 'k', 'LineWidth', 1);   % target markers
    else
        scatter(ax, xy(:,1), xy(:,2), 120, pv, 'filled', ...
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


function out = smoothDensity(dens)
% Gaussian-smooth a 2-D density for the 'kde' endpoint style. Uses imgaussfilt
% when the Image Processing Toolbox is available, else a small separable
% gaussian via conv2 so the plot never hard-depends on that toolbox.
    if exist('imgaussfilt', 'file') == 2
        out = imgaussfilt(dens, 1.5);
        return
    end
    g = exp(-((-3:3).^2) / (2 * 1.5^2));
    g = g / sum(g);
    out = conv2(g, g, dens, 'same');
end
