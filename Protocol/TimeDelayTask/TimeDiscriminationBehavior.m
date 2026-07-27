function result = TimeDiscriminationBehavior(data, cfg,plotFlag)
% Offline psychometric / behavior analysis for the time-discrimination task.
%
% Mirrors the organization of the online reference
% OnlinePlotBlackRock/jivesLink/plotJivesPsychometrics.m (a 4x2 grid: a large
% psychometric panel on top, Bias-vs-trial + Threshold-vs-trial in the middle,
% two RT-vs-asynchrony panels at the bottom), but works offline on the data
% struct already passed in and adds interactive session selection.
%
% Input
%   data     - struct from BlackRockFileAnalyzer with field .events (the trials
%              table from readtable of *_trials_matlab). Only .events is used;
%              behaviour comes entirely from the events table, not the spikes.
%   cfg    - unused (leave here for future batch analysis).
%   plotFlag - 1: build the interactive GUI; 0: compute the default selection
%              and return without any figure.
%
% Output
%   result   - struct with result.sessions(k): .id .range .pse .threshold .psy
%              .sliding (windowed bias/threshold) .rtLeft .rtRight .n
%
% UI: three dropdowns each select one session present in the recording (or
% "(none)"); under each are two editable trial-number fields (default = that
% session's first/last valid trial, clamped to the whole recording [1 total]).
% Psychometric and RT panels overlay the selected sessions in one colour each;
% Bias/Threshold share one global Trial_number axis with a per-session
% background shade and a sliding window (win=30, step=5) that never crosses a
% session boundary. Reuses VisPsychometricFunction for every fit.
%
% Xuefei Yu, 2026

    if nargin < 3 || isempty(plotFlag);  plotFlag = 1;  end

    WIN  = 30;   % sliding-window length (trials) for bias/threshold
    STEP = 5;    % sliding-window step (trials)

    % ---------------------------------------------------------------------
    % Parse / filter the events table.
    % ---------------------------------------------------------------------
    D = prepTDData(data);

    if isempty(D.S)
        warning('TimeDiscriminationBehavior:noTrials', ...
            'No valid time-delay trials in the passed data.');
        result = struct('sessions', []);
        if plotFlag
            figure('Name', 'Time discrimination behavior', 'Color', 'w');
            axis off;
            text(0.5, 0.5, 'No valid time-delay trials', ...
                'HorizontalAlignment', 'center', 'FontSize', 14);
        end
        return
    end

    % ---------------------------------------------------------------------
    % Compute-only path: default selection (first up to 3 sessions, full range).
    % ---------------------------------------------------------------------
    if ~plotFlag
        sel = defaultSelection(D);
        result = computeAll(D, sel, WIN, STEP);
        return
    end

    % ---------------------------------------------------------------------
    % GUI (spikeCheck.m idiom: left uicontrol rail + right uipanel of axes).
    % ---------------------------------------------------------------------
    result = struct('sessions', []);
    cmap   = lines(3);                       % one stable colour per dropdown slot

    % Per-figure recompute caches (D is fixed for the figure's lifetime, so
    % entries never go stale -- no invalidation needed). containers.Map has
    % handle semantics, so the nested callbacks mutate these in place.
    slidingCache = containers.Map('KeyType', 'double', 'ValueType', 'any'); % sessionId -> full-session sliding
    slotCache    = containers.Map('KeyType', 'char',   'ValueType', 'any'); % 'id|lo|hi' -> whole-range fit + RT

    fig = figure('Name', 'Time discrimination behavior', 'Color', 'w', ...
                 'Position', [60 60 1300 900]);

    % Dropdown labels: session title carries the end trial number.
    ddLabels = [{'(none)'}, arrayfun(@(s) sprintf('Session %d (end %d)', ...
                    s.id, s.endTrial), D.S, 'UniformOutput', false)];

    dd      = gobjects(3, 1);
    edStart = gobjects(3, 1);
    edEnd   = gobjects(3, 1);
    yTop    = [0.94 0.66 0.38];              % top of each selection group

    for g = 1:3
        y = yTop(g);
        uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [0.01 y 0.17 0.03], 'String', sprintf('Selection %d', g), ...
            'BackgroundColor', 'w', 'FontWeight', 'bold', ...
            'ForegroundColor', cmap(g, :), 'HorizontalAlignment', 'left');
        dd(g) = uicontrol(fig, 'Style', 'popupmenu', 'Units', 'normalized', ...
            'Position', [0.01 y-0.05 0.17 0.045], 'String', ddLabels, ...
            'Callback', @(src, ~) onDropdown(g));
        uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [0.01 y-0.10 0.05 0.03], 'String', 'Start', ...
            'BackgroundColor', 'w', 'HorizontalAlignment', 'left');
        edStart(g) = uicontrol(fig, 'Style', 'edit', 'Units', 'normalized', ...
            'Position', [0.055 y-0.105 0.055 0.04], 'String', '', ...
            'Callback', @(~, ~) onTrialEdit(g));
        uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [0.115 y-0.10 0.03 0.03], 'String', 'End', ...
            'BackgroundColor', 'w', 'HorizontalAlignment', 'left');
        edEnd(g) = uicontrol(fig, 'Style', 'edit', 'Units', 'normalized', ...
            'Position', [0.14 y-0.105 0.04 0.04], 'String', '', ...
            'Callback', @(~, ~) onTrialEdit(g));

        % Default: slot g -> the g-th session (if it exists), else "(none)".
        if g <= numel(D.S)
            set(dd(g), 'Value', g + 1);
            set(edStart(g), 'String', num2str(D.S(g).first));
            set(edEnd(g),   'String', num2str(D.S(g).last));
        end
    end

    uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', ...
        'Position', [0.01 0.06 0.17 0.05], 'String', 'Update', ...
        'Callback', @(~, ~) redraw());

    % Right panel: the reference 4x2 grid (psychometric spans the top half).
    pnl    = uipanel(fig, 'Units', 'normalized', 'Position', [0.20 0.03 0.79 0.95], ...
                     'BackgroundColor', 'w', 'BorderType', 'none');
    axPsy  = axes('Parent', pnl, 'Position', [0.08 0.56 0.86 0.40]);
    axBias = axes('Parent', pnl, 'Position', [0.08 0.30 0.38 0.16]);
    axThr  = axes('Parent', pnl, 'Position', [0.56 0.30 0.38 0.16]);
    axRTL  = axes('Parent', pnl, 'Position', [0.08 0.05 0.38 0.16]);
    axRTR  = axes('Parent', pnl, 'Position', [0.56 0.05 0.38 0.16]);

    redraw();
    %uiwait(fig);

    % =====================================================================
    % Nested callbacks / drawing (share D, handles, cmap, result).
    % =====================================================================
    function onDropdown(g)
        % On a new session, reset its trial fields to that session's range.
        s = getSlot(g);
        if ~isempty(s)
            set(edStart(g), 'String', num2str(s.first));
            set(edEnd(g),   'String', num2str(s.last));
        end
       % redraw();
    end

    function onTrialEdit(g)
        s = getSlot(g);
        if isempty(s) 
            %redraw();  
          return;  
        end
        lo = clampTrial(parseField(edStart(g), s.first), s.first);
        hi = clampTrial(parseField(edEnd(g),   s.last),  s.first);
        if lo > hi;  [lo, hi] = deal(hi, lo);  end
        set(edStart(g), 'String', num2str(lo));
        set(edEnd(g),   'String', num2str(hi));
      %  redraw();
    end

    function v = parseField(h, defaultVal)
        % Read an edit field as an integer trial number; fall back to a default.
        v = round(str2double(get(h, 'String')));
        if isnan(v);  v = defaultVal;  end
    end

    function v = clampTrial(v, sessFirst)
        % Clamp to the whole recording: below the recording's first trial ->
        % this session's first trial; above the recording total -> the last
        % trial. Values between (even outside this session's own range) are kept.
        if v < D.minTrial
            v = sessFirst;
        elseif v > D.totalTrials
            v = D.totalTrials;
        end
    end

    function s = getSlot(g)
        % The session struct chosen in dropdown g, or [] for "(none)".
        v = get(dd(g), 'Value');
        if v <= 1
            s = [];
        else
            s = D.S(v - 1);
        end
    end

    function sel = currentSelection()
        sel = struct('S', {}, 'lo', {}, 'hi', {}, 'slot', {});
        for gg = 1:3
            s = getSlot(gg);
            if isempty(s);  continue;  end
            lo = clampTrial(parseField(edStart(gg), s.first), s.first);
            hi = clampTrial(parseField(edEnd(gg),   s.last),  s.first);
            if lo > hi;  [lo, hi] = deal(hi, lo);  end
            sel(end+1) = struct('S', s, 'lo', lo, 'hi', hi, 'slot', gg); %#ok<AGROW>
        end
    end

    function res = computeAllCached(sel)
        % Cached counterpart of computeAll: reuse unchanged slots and the
        % once-per-session sliding bias/threshold, so only what actually
        % changed is refit.
        res  = struct('sessions', []);
        sess = struct([]);            % grown into a struct array (avoids double->struct)
        for k = 1:numel(sel)
            s  = sel(k).S;
            lo = sel(k).lo;  hi = sel(k).hi;

            % Full-session sliding windows: expensive, computed once per session.
            if ~isKey(slidingCache, s.id)
                slidingCache(s.id) = computeSlidingBTFull(D, s.rows, WIN, STEP);
            end
            Wfull = slidingCache(s.id);

            % Whole-range fit + RT: keyed by the exact selection.
            key = sprintf('%d|%d|%d', s.id, lo, hi);
            if isKey(slotCache, key)
                base = slotCache(key);
            else
                rows = s.rows(D.trialNum(s.rows) >= lo & D.trialNum(s.rows) <= hi);
                [pse, thr, psy, n] = computeSessionPsy(D, rows);
                base = struct('id', s.id, 'range', [lo hi], 'pse', pse, ...
                              'threshold', thr, 'psy', psy, 'n', n, ...
                              'rtLeft',  computeRTByLevel(D, rows, -1), ...
                              'rtRight', computeRTByLevel(D, rows, +1));
                slotCache(key) = base;
            end

            base.sliding = selectWindows(Wfull, lo, hi);
            if isempty(sess)
                sess = base;                 % first entry seeds the struct array
            else
                sess(k) = base;
            end
        end
        if ~isempty(sess);  res.sessions = sess;  end
    end

    function redraw()
        sel    = currentSelection();
        result = computeAllCached(sel);

        % --- Psychometric overlay -------------------------------------
        cla(axPsy);  hold(axPsy, 'on');
        h = gobjects(0);  lbl = {};
        for k = 1:numel(sel)
            col = cmap(sel(k).slot, :);
            psy = result.sessions(k).psy;
            if isempty(psy);  continue;  end
            plot(axPsy, psy.stim_levels, psy.pRight, '.', 'Color', col, 'MarkerSize', 18);
            h(end+1) = plot(axPsy, psy.fit_x, psy.fit_y, '-', ...
                'Color', col, 'LineWidth', 2); %#ok<AGROW>
            if psy.separable
                thrTxt = 'thr unreliable';
            else
                thrTxt = sprintf('thr %.1f', result.sessions(k).threshold);
            end
            lbl{end+1} = sprintf('S%d [%d-%d] n=%d | PSE %.1f, %s', ...
                sel(k).S.id, sel(k).lo, sel(k).hi, result.sessions(k).n, ...
                result.sessions(k).pse, thrTxt); %#ok<AGROW>
        end
        plot(axPsy, xlim(axPsy), [0.5 0.5], '--k');
        plot(axPsy, [0 0], [0 1], '--k');
        ylim(axPsy, [0 1]);  yticks(axPsy, [0 0.5 1]);
        xlabel(axPsy, 'Signed onset asynchrony (ms)');
        ylabel(axPsy, 'P(rightward)');
        title(axPsy, 'Psychometric function', 'FontSize', 13);
        if ~isempty(h)
            legend(axPsy, h, lbl, 'Location', 'northwest', 'FontSize', 8);
        end
        set(axPsy, 'LineWidth', 1, 'FontSize', 11);  box(axPsy, 'off');
        hold(axPsy, 'off');

        % --- Bias & Threshold: shared global-trial axis + per-session shade
        drawBT(axBias, sel, 'pse', 'Bias (PSE, ms)');
        drawBT(axThr,  sel, 'thr', 'Threshold (ms)');

        % --- RT panels -------------------------------------------------
        drawRT(axRTL, sel, 'rtLeft',  'RT vs asynchrony (left-onset-first)');
        drawRT(axRTR, sel, 'rtRight', 'RT vs asynchrony (right-onset-first)');
    end

    function drawBT(ax, sel, field, ttl)
        cla(ax);  hold(ax, 'on');
        anyPt = false;
        for k = 1:numel(sel)
            col = cmap(sel(k).slot, :);
            W   = result.sessions(k).sliding;
            y   = W.(field);
            if any(isfinite(y))
                plot(ax, W.x, y, '.-', 'Color', col, 'MarkerSize', 12, 'LineWidth', 1.2);
                anyPt = true;
            end
        end
        if anyPt
            yl = ylim(ax);
        else
            yl = [0 1];
        end
        for k = 1:numel(sel)                 % background block shade per session
            col = cmap(sel(k).slot, :);
            xr  = [sel(k).lo sel(k).hi];
            p = patch(ax, [xr(1) xr(2) xr(2) xr(1)], [yl(1) yl(1) yl(2) yl(2)], col, ...
                'FaceAlpha', 0.12, 'EdgeColor', 'none');
            uistack(p, 'bottom');
        end
        ylim(ax, yl);
        xlabel(ax, 'Trial number');  ylabel(ax, ttl);
        title(ax, ttl);
        set(ax, 'LineWidth', 1, 'FontSize', 10);  box(ax, 'off');
        hold(ax, 'off');
    end

    function drawRT(ax, sel, field, ttl)
        cla(ax);  hold(ax, 'on');
        for k = 1:numel(sel)
            col = cmap(sel(k).slot, :);
            R   = result.sessions(k).(field);
            if isempty(R.lev);  continue;  end
            okC = R.nC > 0;   % correct: filled dots
            if any(okC)
                errorbar(ax, R.lev(okC), R.mrtC(okC), R.sdC(okC), 'o', ...
                    'LineStyle', 'none', 'Color', col, 'MarkerFaceColor', col, ...
                    'MarkerEdgeColor', col, 'MarkerSize', 8, 'CapSize', 4);
            end
            okW = R.nW > 0;   % wrong: open dots
            if any(okW)
                errorbar(ax, R.lev(okW), R.mrtW(okW), R.sdW(okW), 'o', ...
                    'LineStyle', 'none', 'Color', col, 'MarkerFaceColor', 'none', ...
                    'MarkerEdgeColor', col, 'MarkerSize', 8, 'CapSize', 4);
            end
            if ~isempty(R.fit)   % linear trend from correct averages
                xx = [min(R.lev) max(R.lev)];
                plot(ax, xx, polyval(R.fit, xx), '-', 'Color', col, 'LineWidth', 1.2);
            end
        end
        % r/p of each session's correct-trial fit, stacked in the top-right corner
        yTxt = 0.97;
        for k = 1:numel(sel)
            R = result.sessions(k).(field);
            if isempty(R.lev) || isempty(R.fit);  continue;  end
            text(ax, 0.97, yTxt, sprintf('r=%.2f, p=%.3f', R.r, R.p), ...
                'Units', 'normalized', 'Color', cmap(sel(k).slot, :), 'FontSize', 8, ...
                'HorizontalAlignment', 'right', 'VerticalAlignment', 'top');
            yTxt = yTxt - 0.11;
        end
        xlabel(ax, 'Signed onset asynchrony (ms)');  ylabel(ax, 'RT (s)');
        title(ax, ttl, 'FontSize', 9);
        set(ax, 'LineWidth', 1, 'FontSize', 10);  box(ax, 'off');
        hold(ax, 'off');
    end
end

% =========================================================================
% Computation helpers (pure: no plotting, no side effects)
% =========================================================================
function D = prepTDData(d)
% Filter the events table to valid trials and index them by session. The events
% table arrives pre-scoped to the time-delay task (SetupDataForTask), so only the
% analysis-specific validity screening is applied here.
    ev = d.comments;
    saved       = ev.Save_complete == 1;
    validChoice = ~isnan(ev.Choose_target);
    validMask   = saved & validChoice;

    %D.totalTrials = max(ev.Trial_number);         % clamp upper bound (whole recording)
    %D.minTrial    = min(ev.Trial_number);         % clamp lower bound (may be 0-indexed)
    D.totalTrials = sum(validMask);         % clamp upper bound (whole recording)
    D.minTrial    = 1;         % clamp lower bound 

    %Screen out valid trials
    ev = ev(validMask,:);

    D.trialNum    = [1:sum(validMask)]';
    D.stimulus    = ev.Requested_target_2_time_offset;
    D.direction   = ev.Stimulus_direction;
    D.choiceLR    = ev.Choose_leftright;          % -1 = left, 1 = right

    % Per-trial correctness (repo-wide convention: the Trialoutcome string). After
    % the Save_complete/valid-choice screen above, trials are correct or wrong only.
    if ismember('Trialoutcome', ev.Properties.VariableNames)
        D.correct = strcmp(string(ev.Trialoutcome), 'correct');   % normalizes cell/char/categorical
    else
        D.correct = D.choiceLR == D.direction;                    % geometric fallback
    end


    if ismember('RTtime', ev.Properties.VariableNames)
        disp('Use real RT estimated by eyemovement.');
        D.saccade = ev.RTtime;
    else
        disp('Use approximate RT by the comments marker.');
        hasRT = ismember('Choicetime', ev.Properties.VariableNames) && ...
            ismember('Fixation_point_off', ev.Properties.VariableNames);
        if hasRT
            D.saccade = ev.Choicetime - ev.Fixation_point_off;   % seconds
        else
            D.saccade = nan(height(ev), 1);
        end
        

    end

 
    sessIds_raw = unique(ev.Session);
    sessIds = [1:length(sessIds_raw)]';
    S = struct('id', {}, 'rows', {}, 'first', {}, 'last', {}, 'endTrial', {});
    for k = 1:numel(sessIds)
        sid  = sessIds_raw(k);
        rows = find(ev.Session == sid);
        tn   = D.trialNum(rows);
        S(k) = struct('id', k, 'rows', rows, 'first', min(tn), ...
                      'last', max(tn), 'endTrial', max(tn));
    end
    D.S = S;
end

function sel = defaultSelection(D)
% First up to 3 sessions, each over its full valid-trial range.
    sel = struct('S', {}, 'lo', {}, 'hi', {}, 'slot', {});
    for g = 1:min(3, numel(D.S))
        sel(end+1) = struct('S', D.S(g), 'lo', D.S(g).first, ...
                            'hi', D.S(g).last, 'slot', g); %#ok<AGROW>
    end
end

function res = computeAll(D, sel, win, step)
% Per-selected-session psychometric fit, sliding bias/threshold and RT-by-level.
    res = struct('sessions', []);
    for k = 1:numel(sel)
        s    = sel(k).S;
        rows = s.rows(D.trialNum(s.rows) >= sel(k).lo & D.trialNum(s.rows) <= sel(k).hi);
        [pse, thr, psy, n]        = computeSessionPsy(D, rows);
        res.sessions(k).id        = s.id;
        res.sessions(k).range     = [sel(k).lo sel(k).hi];
        res.sessions(k).pse       = pse;
        res.sessions(k).threshold = thr;
        res.sessions(k).psy       = psy;
        res.sessions(k).n         = n;
        res.sessions(k).sliding   = selectWindows( ...
            computeSlidingBTFull(D, s.rows, win, step), sel(k).lo, sel(k).hi);
        res.sessions(k).rtLeft    = computeRTByLevel(D, rows, -1);
        res.sessions(k).rtRight   = computeRTByLevel(D, rows, +1);
    end
end

function [pse, thr, psy, n] = computeSessionPsy(D, rows)
% Logistic psychometric fit over the given rows via VisPsychometricFunction.
    n = numel(rows);
    pse = NaN;  thr = NaN;  psy = [];
    if n < 2;  return;  end
    sd = D.stimulus(rows) .* D.direction(rows);
    if numel(unique(sd)) < 2;  return;  end     % need >=2 signed levels to fit
    psymat = [D.stimulus(rows), D.direction(rows), double(D.choiceLR(rows) == 1)];

    % Small/short windows are often perfectly separable, which makes fitglm warn
    % about non-finite estimates and hit its iteration limit. That case is
    % expected (and flagged below via psy.separable), so mute those two warnings.
    ws = warning;                                       %#ok<WNTAG> full state
    cleanup = onCleanup(@() warning(ws));
    warning('off', 'stats:glmfit:PerfectSeparation');
    warning('off', 'stats:glmfit:IterationLimit');
    try
        [pse, thr, psy] = VisPsychometricFunction(psymat, 0);
        if ~isempty(psy) && psy.separable
            thr = NaN;                           % slope unconstrained -> unreliable
        end
    catch
        pse = NaN;  thr = NaN;  psy = [];
    end
    if abs(pse) >1000
       % Hard up level
       % the pse is meaningless if above this value
       pse = NaN;
    end
    if thr >1000 
       % Hard up level
       % the thr is meaningless if above this value
       thr = NaN;
    end
end

function W = computeSlidingBTFull(D, rows, win, step)
% Bias/threshold in a trailing window of `win` trials stepped by `step`, over a
% whole session's rows (never crossing a session boundary). Windows are anchored
% to fixed session positions -- not to any selected sub-range -- so a range edit
% just re-selects a subset (see selectWindows) instead of refitting. x = window
% centre; lo/hi = the window's first/last trial number, used for that selection.
    n         = numel(rows);
    starts    = 1:step:max(1, n - win + 1);
    W.x   = nan(numel(starts), 1);
    W.pse = nan(numel(starts), 1);
    W.thr = nan(numel(starts), 1);
    W.lo  = nan(numel(starts), 1);
    W.hi  = nan(numel(starts), 1);
    if n < win;  return;  end
    for i = 1:numel(starts)
        w      = starts(i):min(n, starts(i) + win - 1);
        wrows  = rows(w);
        [p, t] = computeSessionPsy(D, wrows);
        tn       = D.trialNum(wrows);
        W.x(i)   = mean(tn);
        W.pse(i) = p;
        W.thr(i) = t;
        W.lo(i)  = min(tn);
        W.hi(i)  = max(tn);
    end
end

function W = selectWindows(Wfull, lo, hi)
% Pick the precomputed full-session windows whose whole trial span lies inside
% the selected range [lo, hi], so no window uses trials outside the selection.
    keep  = Wfull.lo >= lo & Wfull.hi <= hi;
    W.x   = Wfull.x(keep);
    W.pse = Wfull.pse(keep);
    W.thr = Wfull.thr(keep);
end

function R = computeRTByLevel(D, rows, sideSign)
% RT per signed asynchrony level, split by outcome, for trials whose onset-first
% side matches sideSign (-1 left-first, +1 right-first). Per level: correct/wrong
% mean, std and count (mrtC/sdC/nC and mrtW/sdW/nW). `fit` is a [slope intercept]
% linear fit of the correct-trial mean RT vs level, only when >2 signed levels
% carry correct data (else []).
    R = struct('lev', [], 'mrtC', [], 'sdC', [], 'nC', [], ...
                          'mrtW', [], 'sdW', [], 'nW', [], ...
                          'fit', [], 'r', NaN, 'p', NaN);
    sd   = D.stimulus(rows) .* D.direction(rows);

    if size(D.saccade,2) >1
        %Real saccade
        rt   = D.saccade.RTtime(rows);
    else
        %Estimated saccade
        rt   = D.saccade(rows);

    end
    side = sign(D.direction(rows));
    cor  = logical(D.correct(rows));
    m    = side == sideSign & ~isnan(rt);
    if ~any(m);  return;  end
    lev = sd(m);  rtv = rt(m);  cor = cor(m);
    ulev = unique(lev);
    nL   = numel(ulev);
    [mrtC, sdC, nC, mrtW, sdW, nW] = deal(nan(nL, 1));
    for i = 1:nL
        atC = lev == ulev(i) &  cor;
        atW = lev == ulev(i) & ~cor;
        nC(i) = sum(atC);  nW(i) = sum(atW);
        if nC(i) > 0;  mrtC(i) = mean(rtv(atC));  sdC(i) = std(rtv(atC));  end
        if nW(i) > 0;  mrtW(i) = mean(rtv(atW));  sdW(i) = std(rtv(atW));  end
    end
    R.lev  = ulev;
    R.mrtC = mrtC;  R.sdC = sdC;  R.nC = nC;
    R.mrtW = mrtW;  R.sdW = sdW;  R.nW = nW;

    % Linear trend from correct-trial averages (each level weighted equally).
    okC = nC > 0 & isfinite(mrtC);
    if sum(okC) > 2
        xf = ulev(okC);  yf = mrtC(okC);
        R.fit = polyfit(xf, yf, 1);                 % [slope intercept]
        [rr, pp] = corrcoef(xf, yf);                % goodness of the trend
        R.r = rr(1, 2);
        R.p = pp(1, 2);
    end
end
