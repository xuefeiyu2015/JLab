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
    D = prepTDData(data.events);

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
    uiwait(fig);

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
        redraw();
    end

    function onTrialEdit(g)
        s = getSlot(g);
        if isempty(s);  redraw();  return;  end
        lo = clampTrial(parseField(edStart(g), s.first), s.first);
        hi = clampTrial(parseField(edEnd(g),   s.last),  s.first);
        if lo > hi;  [lo, hi] = deal(hi, lo);  end
        set(edStart(g), 'String', num2str(lo));
        set(edEnd(g),   'String', num2str(hi));
        redraw();
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

    function redraw()
        sel    = currentSelection();
        result = computeAll(D, sel, WIN, STEP);

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
            plot(ax, R.lev, R.mrt, '.-', 'Color', col, 'MarkerSize', 12, 'LineWidth', 1.2);
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
function D = prepTDData(ev)
% Filter the events table to valid time-delay trials and index them by session.
    isTime      = contains(string(ev.Task), 'time');
    saved       = ev.Save_complete == 1;
    validChoice = ~isnan(ev.Choose_target);
    validMask   = isTime & saved & validChoice;

    D.totalTrials = max(ev.Trial_number);         % clamp upper bound (whole recording)
    D.minTrial    = min(ev.Trial_number);         % clamp lower bound (may be 0-indexed)
    D.trialNum    = ev.Trial_number;
    D.stimulus    = ev.Requested_target_2_time_offset;
    D.direction   = ev.Stimulus_direction;
    D.choiceLR    = ev.Choose_leftright;          % 0 = left, 1 = right

    hasRT = ismember('Choicetime', ev.Properties.VariableNames) && ...
            ismember('Fixation_point_off', ev.Properties.VariableNames);
    if hasRT
        D.rt = ev.Choicetime - ev.Fixation_point_off;   % seconds
    else
        D.rt = nan(height(ev), 1);
    end

    sessIds = unique(ev.Session(validMask));
    sessIds = sessIds(:)';
    S = struct('id', {}, 'rows', {}, 'first', {}, 'last', {}, 'endTrial', {});
    for k = 1:numel(sessIds)
        sid  = sessIds(k);
        rows = find(validMask & ev.Session == sid);
        tn   = ev.Trial_number(rows);
        S(k) = struct('id', sid, 'rows', rows, 'first', min(tn), ...
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
        res.sessions(k).sliding   = computeSlidingBT(D, rows, win, step);
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
end

function W = computeSlidingBT(D, rows, win, step)
% Bias/threshold in a trailing window of `win` trials stepped by `step`, within
% one session's rows only (never crossing a session boundary). x = window centre.
    tn        = D.trialNum(rows);
    [~, ord]  = sort(tn);
    rows      = rows(ord);
    n         = numel(rows);
    starts    = 1:step:max(1, n - win + 1);
    W.x   = nan(numel(starts), 1);
    W.pse = nan(numel(starts), 1);
    W.thr = nan(numel(starts), 1);
    if n < win;  return;  end
    for i = 1:numel(starts)
        w      = starts(i):min(n, starts(i) + win - 1);
        wrows  = rows(w);
        [p, t] = computeSessionPsy(D, wrows);
        W.x(i)   = mean(D.trialNum(wrows));
        W.pse(i) = p;
        W.thr(i) = t;
    end
end

function R = computeRTByLevel(D, rows, sideSign)
% Mean RT per signed asynchrony level, for trials whose onset-first side matches
% sideSign (-1 left-first, +1 right-first).
    R = struct('lev', [], 'mrt', [], 'n', []);
    sd   = D.stimulus(rows) .* D.direction(rows);
    rt   = D.rt(rows);
    side = sign(D.direction(rows));
    m    = side == sideSign & ~isnan(rt);
    if ~any(m);  return;  end
    lev = sd(m);  rtv = rt(m);
    [ulev, ~, ix] = unique(lev);
    R.lev = ulev;
    R.mrt = accumarray(ix, rtv, [], @mean);
    R.n   = accumarray(ix, 1);
end
