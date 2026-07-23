function caled_eyes = EyeCalibration(comments_data, eye_data, task_cal, holdWinMs, ...
        eyeChans, plotCal, calSessions, nCalTrials, savePath, reCompute)
%Function for eye calibration
% Select out correct trials from comments, eye_data for the task for
% calibration
% Calibrate the eyes using:
%
% tx = offset_x_loc + gain_x * x_v + couple_xy * x_v * y_v
% ty = offset_y_loc + gain_y * y_v + couple_yx * y_v * x_v
%
% the default for couple_xy and couple_yx will be 0, if the condition is
% too few to fit the couples, it can be set as 0;
% it return the calibrated eye signal with the structure the same as
% eye_data, just with calibrated eye in degree.
%
% Two kinds of task can supply calibration points:
%   fixation task - the fixation hold, gaze at Fixation_position_x/_y.
%   saccade task  - two epochs per trial: the fixation period before the
%                   target appears (gaze at Fixation_position_x/_y), and the
%                   target hold (gaze at Target_1_position_x/_y).
%
% Pass several and the calibration task is detected from what the session
% actually ran: they are tried in the order given and the first that yields a
% fit is used, so a session with no fixation block still calibrates off its
% saccade trials. Each task passed over says so in a warning as it happens.
%
%   comments_data - table of parsed trials (one row per trial, 1:1 with dim 2
%                   of eye_data.data). Needs Task, Session, Save_complete,
%                   Trialoutcome, and the event/target columns of the task.
%   eye_data      - segmented analog product from BlackrockLoader.segmentAnalog:
%                   .data (chan x nTrials x maxSamples, uV, NaN-padded),
%                   .timeseq.relative_time (s from Start), .timeseq.alignedrawtime (s).
%   task_cal      - task name(s) to calibrate from, each matched as a substring
%                   of Task (e.g. 'fixation' matches 'fixation_experiment').
%                   Either a char (one task) or a cellstr tried in order, e.g.
%                   {'fixation','visual_saccade','memory_saccade'}: the first
%                   one that fits is used and the rest are not tried. Any way a
%                   task can turn out unusable -- absent from the session, no
%                   correct trials, too few conditions, degenerate grid --
%                   falls through to the next. An entry matching several tasks
%                   (a bare 'saccade' where the session ran both kinds) fits
%                   them pooled, with a warning; name them separately to fit
%                   just one.
%   holdWinMs     - [start end] ms from each epoch's anchor marker to average
%                   over (default [100 300], skips the saccade into the target).
%                   The end is cut short per trial when the epoch closes early,
%                   so a long window costs precision, not trials; a trial is only
%                   dropped if under 50 ms of the window survives the cut.
%   eyeChans      - [xChan yChan] rows of eye_data.data (default [1 2]).
%   plotCal       - true to draw two QC figures (default false; nothing is
%                   plotted when the fit fails):
%                     1. the fitted points against their known grid, for the
%                        calibrated task;
%                     2. calibrated eye traces (Start -> End) for each remaining
%                        task, up to 50 completed trials sampled evenly across
%                        the recording, over that task's fixation/target marks.
%   calSessions   - Session numbers to calibrate from (default [] = every
%                   session containing the task).
%   nCalTrials    - max trials used for the fit. Default is task-dependent:
%                   every trial for the fixation task (it is a dedicated
%                   calibration block), min(50, available) for the saccade task.
%                   When it bites, trials are picked round-robin over target
%                   locations so the spatial spread is kept. Inf = use all.
%   savePath      - (optional) session export folder. When set, the fitted
%                   coefficients are cached to <savePath>/AnalysisCache/
%                   EyeCalibration.txt (a readable text file). '' disables caching.
%   reCompute     - (optional, default true) when true, re-fit and refresh the
%                   text cache. When false, load the coefficients from the cached
%                   text file if it exists and skip the fit; they are still applied
%                   to the eye trace, so downstream stages get calibrated degrees.
%
% Returns:
%   caled_eyes    - eye_data with .data on the eye channels converted to deg,
%                   plus .cal:
%                     .applied  - false when nothing could calibrate, in which
%                                 case .data is untouched and still in uV
%                     .units    - 'deg' once applied, otherwise 'uV'
%                     .task_cal - cellstr of the task(s) actually fitted
%                     .coef_x/y - [offset; gain; coupling], coupling 0 if unfit
%                     .R2_x/y   - fit quality per axis
%                   Why a task was passed over is warned about as it happens,
%                   not stored.
%
% Xuefei Yu Jul 16, 2026

    if nargin < 4 || isempty(holdWinMs);   holdWinMs   = [100 300]; end
    if nargin < 5 || isempty(eyeChans);    eyeChans    = [1 2];    end
    if nargin < 6 || isempty(plotCal);     plotCal     = false;    end
    if nargin < 7;                         calSessions = [];       end
    if nargin < 8;                         nCalTrials  = [];       end
    if nargin < 9;                         savePath    = '';       end
    if nargin < 10 || isempty(reCompute);  reCompute   = true;     end
    % nCalTrials stays empty here: its default depends on the task, which is
    % only known once task_cal has been resolved below.

    caled_eyes = eye_data;

    % Kept even when the fit fails, so callers can always ask cal.applied.
    cal = struct('applied', false, 'units', 'uV', 'task_cal', {{}}, ...
                 'coef_x', [], 'coef_y', [], 'R2_x', NaN, 'R2_y', NaN);

    task_list = cellstr(task_cal);

    calFile = '';
    if ~isempty(savePath)
        calFile = fullfile(char(savePath), 'AnalysisCache', 'EyeCalibration.txt');
    end

    % ---------------------------------------------------------------------
    % 1. Obtain the fit: from the cached text file, or by fitting the session
    % ---------------------------------------------------------------------
    % fitpts (the raw points behind the fit) only exists on the compute path; a
    % cached load has just the coefficients, so the fitted-points QC plot is
    % skipped there (see section 3).
    fitpts   = [];
    fromCache = false;
    if ~reCompute && ~isempty(calFile) && exist(calFile, 'file')
        cal = readCalibration(calFile);
        fromCache = true;
    end

    if ~fromCache
        % Every way a task can turn out unusable -- absent from the session, no
        % correct trials, too few conditions, a degenerate grid -- falls through
        % to the next, so a session with no fixation block still calibrates off
        % the saccade task it did run. Each attempt gets the untouched cal
        % template, so nothing a failed attempt computed can leak into the next.
        for c = 1:numel(task_list)
            [cal_c, pts_c] = fitOneTask(comments_data, eye_data, task_list{c}, cal, ...
                holdWinMs, eyeChans, calSessions, nCalTrials);
            if cal_c.applied
                cal    = cal_c;
                fitpts = pts_c;
                break
            end
        end
    end

    if ~cal.applied
        if ~fromCache
            warning('EyeCalibration:NoCalibration', ...
                'None of (%s) could calibrate this session; eye data left in uV.', ...
                strjoin(task_list, ', '));
        end
        caled_eyes.cal = cal;  return
    end

    % Persist the fresh fit so later runs can load it instead of re-fitting.
    if ~fromCache && ~isempty(calFile)
        writeCalibration(cal, calFile);
    end

    fprintf('Eye calibration: using "%s" (R^2 x=%.3f y=%.3f).\n', ...
        strjoin(cal.task_cal, ', '), cal.R2_x, cal.R2_y);

    % ---------------------------------------------------------------------
    % 2. Apply to every trial (all tasks, all sessions)
    % ---------------------------------------------------------------------
    % NaN padding propagates through the arithmetic and stays NaN.
    raw_x = eye_data.data(eyeChans(1), :, :);
    raw_y = eye_data.data(eyeChans(2), :, :);

    caled_eyes.data(eyeChans(1), :, :) = applyAxis(raw_x, raw_y, cal.coef_x);
    caled_eyes.data(eyeChans(2), :, :) = applyAxis(raw_y, raw_x, cal.coef_y);

    caled_eyes.cal = cal;

    % ---------------------------------------------------------------------
    % 3. Optional QC plots
    % ---------------------------------------------------------------------
    if plotCal
        % (a) the calibrated points the fit was built from, against their grid.
        % Only available on the compute path: a cached load has the coefficients
        % but not fitpts, so this fit-quality figure is skipped there.
        if ~isempty(fitpts)
            gaze_x = applyAxis(fitpts.xv, fitpts.yv, cal.coef_x);
            gaze_y = applyAxis(fitpts.yv, fitpts.xv, cal.coef_y);
            plotCalibratedGaze(gaze_x, gaze_y, fitpts.tx, fitpts.ty, cal);
        end

        % (b) eye traces for the tasks the fit was NOT built from
        plotCalibratedEyes(caled_eyes, comments_data, eyeChans, cal.task_cal);
    end
end


function [cal, fitpts] = fitOneTask(comments_data, eye_data, task_entry, cal, ...
        holdWinMs, eyeChans, calSessions, nCalTrials)
% Fit the calibration from one task. Returns cal.applied false rather than
% throwing, so the caller can move on to the next task in its list.
%
%   task_entry - the caller's task name, matched as a substring of Task.
%   cal        - the pristine template; filled in and returned.
%   fitpts     - the points the fit was built from (xv, yv, tx, ty), for the plot.

    fitpts = [];

    % calibrationEpochs is the authority on what can calibrate at all, and reads
    % the entry as a substring exactly as the Task match below does. A task with
    % no known-gaze epoch must never be fitted, or it would be calibrated against
    % a gaze location that was never pinned down.
    epochs = calibrationEpochs(task_entry);
    if isempty(epochs)
        warning('EyeCalibration:UnsupportedTask', ...
            ['"%s" has no defined calibration epoch; skipping it. Only fixation ' ...
             'and saccade tasks can calibrate.'], task_entry);
        return
    end

    task_hit = contains(comments_data.Task, task_entry);
    if ~any(task_hit);  return;  end     % not in this session: the normal case

    % A loose entry can span several tasks ('saccade' where the session ran both
    % kinds). Pooling them is sound -- the eye-to-degree mapping belongs to the
    % tracker, not the task -- as long as it is not silent.
    matched = unique(comments_data.Task(task_hit));
    if numel(matched) > 1
        warning('EyeCalibration:PooledTasks', ...
            '"%s" matches %d tasks (%s); pooling them for the fit.', ...
            task_entry, numel(matched), strjoin(matched(:)', ', '));
    end
    cal.task_cal = matched(:)';

    % The fixation task is a dedicated calibration block, so use all of it. The
    % saccade task is an experiment that can run long, and 50 trials already
    % cover the target grid several times over; capping keeps the fit from
    % drifting with the session. min() is applied later against what survives.
    % Resolved per attempt, so a fall-back to saccade does not inherit
    % fixation's uncapped default.
    if isempty(nCalTrials)
        if contains(task_entry, 'fixation')
            nCalTrials = Inf;
        else
            nCalTrials = 50;
        end
    end

    % Restrict to the requested sessions (default: every session with the task).
    if isempty(calSessions)
        session_ok = true(height(comments_data), 1);
    else
        session_ok = ismember(comments_data.Session, calSessions);
    end

    % Trials usable at all: right task, right session, fully saved, correct.
    % A correct trial is one where the animal held the gaze the epoch expects,
    % which is the whole requirement -- nothing further to check.
    trial_ok = task_hit & session_ok ...
        & comments_data.Save_complete == 1 ...
        & strcmp(comments_data.Trialoutcome, 'correct');

    if ~any(trial_ok);  return;  end

    % ---------------------------------------------------------------------
    % Collect calibration points from every epoch
    % ---------------------------------------------------------------------
    nTrials = size(eye_data.data, 2);
    eye_x   = reshape(eye_data.data(eyeChans(1), :, :), nTrials, []);
    eye_y   = reshape(eye_data.data(eyeChans(2), :, :), nTrials, []);

    pts = struct('xv', [], 'yv', [], 'tx', [], 'ty', [], 'trial', [], 'epoch', []);

    % Shortest window worth taking a median over once clamped to the epoch.
    % At 1 kHz this is ~50 samples, enough for the median to be stable.
    MIN_WIN_MS = 50;

    for e = 1:numel(epochs)
        ep = epochs(e);

        anchor = comments_data.(ep.anchor);
        limit  = comments_data.(ep.limit);
        tgt_x  = comments_data.(ep.target_x);
        tgt_y  = comments_data.(ep.target_y);

        % The window must stay inside the epoch. Rather than dropping a trial
        % whose epoch is shorter than holdWinMs(2), cut the window short at the
        % marker that closes the epoch (target onset, fixation offset, targets
        % off) and average over whatever is left. A trial is only dropped when
        % too little of the window survives to give a stable median.
        avail_ms = (limit - anchor) * 1000;                  % epoch length from anchor
        win_end  = min(holdWinMs(2), avail_ms);              % per-trial window end
        win_ok   = win_end - holdWinMs(1) >= MIN_WIN_MS;

        ep_ok = trial_ok & win_ok ...
            & ~isnan(anchor) & ~isnan(limit) & ~isnan(tgt_x) & ~isnan(tgt_y);

        if ~any(ep_ok);  continue;  end

        % relative_time is seconds from each trial's own Start marker, while the
        % comment event times are on the absolute NSP clock. Move the anchor into
        % the relative frame rather than the traces, so one shared axis works.
        anchor_rel = anchor - eye_data.timeseq.alignedrawtime(:);
        anchor_rel(~ep_ok) = NaN;                 % AlignEyeTrace NaNs these rows

        % AlignEyeTrace takes pre/post about t=0, so pull the whole span from the
        % anchor out to holdWinMs(2) and keep only the samples inside the window.
        [hold_eye, hold_t] = AlignEyeTrace(eye_x, eye_y, eye_data.timeseq.relative_time, ...
            anchor_rel, 0, holdWinMs(2));

        % One window per trial: shared start, end clamped to that trial's epoch.
        in_win = hold_t*1000 >= holdWinMs(1) & hold_t*1000 <= win_end;   % nTrials x nOut
        wx = hold_eye.x;  wx(~in_win) = NaN;
        wy = hold_eye.y;  wy(~in_win) = NaN;

        % Median over the epoch: robust to blinks and microsaccades.
        xv_all = median(wx, 2, 'omitnan');        % nTrials x 1, uV
        yv_all = median(wy, 2, 'omitnan');

        % Drop trials whose window fell outside the recorded samples.
        keep = ep_ok & ~isnan(xv_all) & ~isnan(yv_all);
        if ~any(keep);  continue;  end

        idx = find(keep);
        pts.xv    = [pts.xv;    xv_all(keep)];
        pts.yv    = [pts.yv;    yv_all(keep)];
        pts.tx    = [pts.tx;    tgt_x(keep)];
        pts.ty    = [pts.ty;    tgt_y(keep)];
        pts.trial = [pts.trial; idx];
        pts.epoch = [pts.epoch; repmat(e, numel(idx), 1)];
    end

    if isempty(pts.xv)
        warning('EyeCalibration:NoTrials', ...
            ['No usable calibration epochs for "%s": no epoch keeps %g ms of the ' ...
             '%g-%g ms window.'], ...
            task_entry, MIN_WIN_MS, holdWinMs(1), holdWinMs(2));
        return
    end

    % ---------------------------------------------------------------------
    % Cap the number of calibration trials
    % ---------------------------------------------------------------------
    % Selection is per TRIAL, not per point: a saccade trial contributes both
    % its epochs, so picking a trial keeps its fixation and target points.
    cal_trials = unique(pts.trial);

    if numel(cal_trials) > nCalTrials
        cal_trials = pickBalancedTrials(pts, cal_trials, nCalTrials);
    end

    keep = ismember(pts.trial, cal_trials);

    xv = pts.xv(keep);
    yv = pts.yv(keep);
    tx = pts.tx(keep);                            % deg, the regressand
    ty = pts.ty(keep);

    % Round before grouping: target coordinates carry float jitter (8.66, 4.95).
    [~, ~, cond_id] = unique(round([tx ty], 3), 'rows');

    % ---------------------------------------------------------------------
    % Fit (pooled across the selected sessions)
    % ---------------------------------------------------------------------
    nCond = max(cond_id);

    % Each axis needs its own targets to vary, otherwise that axis's offset and
    % gain are unidentifiable and the fit collapses to a constant. Distinct grid
    % points alone are not enough: a column of targets (all x equal, y varying)
    % gives nCond = 3 but no x information at all.
    nTargetX = numel(unique(tx));
    nTargetY = numel(unique(ty));
    if nTargetX < 2 || nTargetY < 2
        warning('EyeCalibration:TooFewConditions', ...
            ['"%s" calibration targets span %d distinct x and %d distinct y value(s) over ' ...
             '%d usable points; each axis needs >= 2.'], ...
            task_entry, nTargetX, nTargetY, numel(xv));
        return
    end

    % The coupling column needs a third condition to be identifiable at all.
    use_coupling = nCond >= 3;
    Dx = designMatrix(xv, yv, use_coupling);
    Dy = designMatrix(yv, xv, use_coupling);

    % Even with enough conditions the grid can be degenerate (e.g. collinear
    % targets), which would leave the coupling column redundant.
    if use_coupling && (rank(Dx) < size(Dx,2) || rank(Dy) < size(Dy,2))
        use_coupling = false;
        Dx = designMatrix(xv, yv, use_coupling);
        Dy = designMatrix(yv, xv, use_coupling);
    end

    if rank(Dx) < size(Dx,2) || rank(Dy) < size(Dy,2)
        warning('EyeCalibration:RankDeficient', ...
            '"%s" calibration grid is degenerate (rank-deficient design).', task_entry);
        return
    end

    coef_x = Dx \ tx;                       % [offset_x; gain_x; couple_xy]
    coef_y = Dy \ ty;                       % [offset_y; gain_y; couple_yx]

    cal.R2_x = rsquared(tx, Dx * coef_x);
    cal.R2_y = rsquared(ty, Dy * coef_y);

    if ~use_coupling                        % keep a fixed 3-element shape
        coef_x(3) = 0;
        coef_y(3) = 0;
    end

    cal.coef_x  = coef_x;
    cal.coef_y  = coef_y;
    cal.applied = true;
    cal.units   = 'deg';

    % The points behind the fit, for the caller's QC plot.
    fitpts = struct('xv', xv, 'yv', yv, 'tx', tx, 'ty', ty);
end


function plotCalibratedGaze(gaze_x, gaze_y, tx, ty, cal)
% Plot calibrated gaze on the 2D screen against the known target grid.
% One color per target location: each cloud should sit on its target marker.

    pts  = unique([tx ty], 'rows');
    nGrp = size(pts, 1);
    cmap = hsv(nGrp);

    figure('Name', 'Calibrated gaze (2D screen)'); hold on;

    hleg = gobjects(nGrp, 1);
    for d = 1:nGrp
        k = tx == pts(d,1) & ty == pts(d,2);
        hleg(d) = plot(gaze_x(k), gaze_y(k), '.', 'Color', cmap(d,:), 'MarkerSize', 12);
        % Target location, and a line from it to each trial's gaze (the residual).
        plot([repmat(pts(d,1), 1, sum(k)); gaze_x(k)'], ...
             [repmat(pts(d,2), 1, sum(k)); gaze_y(k)'], '-', ...
             'Color', [cmap(d,:) 0.3], 'LineWidth', 0.5);
        plot(pts(d,1), pts(d,2), '+', 'Color', 'k', 'MarkerSize', 14, 'LineWidth', 1.5);
    end

    % Origin crosshair for reference.
    xl = xlim;  yl = ylim;
    plot(xl, [0 0], 'k:');  plot([0 0], yl, 'k:');
    xlim(xl);  ylim(yl);

    axis equal;
    xlabel('Eye X (\circ)');
    ylabel('Eye Y (\circ)');
    title(sprintf('%s  |  R^2_x=%.3f  R^2_y=%.3f  (%d points, %d conditions)', ...
        strrep(strjoin(cal.task_cal, ', '), '_', ' '), cal.R2_x, cal.R2_y, ...
        numel(tx), size(unique(round([tx ty], 3), 'rows'), 1)));
    legend(hleg, arrayfun(@(i) sprintf('(%.1f, %.1f)\\circ', pts(i,1), pts(i,2)), ...
        (1:nGrp)', 'UniformOutput', false), 'Location', 'bestoutside');
    set(gcf, 'color', 'w');
    set(gca, 'LineWidth', 1, 'FontSize', 15);
    hold off;
end


function plotCalibratedEyes(caled_eyes, comments_data, eyeChans, fitted_tasks)
% Sample plot of calibrated eye traces on the 2D screen, one subplot per task.
%
% Only the tasks the fit was NOT built from are drawn: the calibrated task has
% its own figure showing the fitted points against their grid, whereas these
% tasks are the real test of whether the calibration generalises off the trials
% it was fitted on.
%
% Up to MAX_TRIALS successfully completed trials per task, spread evenly over
% the recording rather than taken from the start or the end, so drift over the
% session is visible instead of hidden. Each trace runs Start -> End, and is
% overlaid with that task's fixation and target locations.

    MAX_TRIALS = 50;
    PAD_DEG    = 5;             % breathing room outside the outermost target

    % ismember, not strcmp: fitted_tasks can name more than one task when a
    % loose entry pooled them, and every task the fit was built from has to be
    % excluded or this plot would claim to test generalisation on its own
    % training trials.
    tasks = unique(comments_data.Task);
    tasks = tasks(~ismember(tasks, fitted_tasks));
    nTask = numel(tasks);
    if nTask == 0;  return;  end

    cmap = lines(nTask);        % one colour per task

    nT   = size(caled_eyes.data, 2);
    eyeX = reshape(caled_eyes.data(eyeChans(1), :, :), nT, []);
    eyeY = reshape(caled_eyes.data(eyeChans(2), :, :), nT, []);
    rel  = caled_eyes.timeseq.relative_time(:).';        % s from Start

    % Trial ends on the same clock as rel: End is absolute, Start is rel = 0.
    end_rel = comments_data.End - caled_eyes.timeseq.alignedrawtime(:);

    figure('Name', 'Calibrated eye traces, other tasks (2D screen)');
    nc = ceil(sqrt(nTask));
    nr = ceil(nTask / nc);

    for t = 1:nTask
        ok = strcmp(comments_data.Task, tasks{t}) ...
            & comments_data.Save_complete == 1 ...
            & strcmp(comments_data.Trialoutcome, 'correct');
        idx = find(ok);
        if isempty(idx);  continue;  end

        % Even spread across the task's trials, not the first or last N.
        if numel(idx) > MAX_TRIALS
            idx = idx(round(linspace(1, numel(idx), MAX_TRIALS)));
        end

        subplot(nr, nc, t);  hold on;

        marks = markerLocations(comments_data, idx);

        for i = idx(:).'
            w = rel >= 0 & rel <= end_rel(i);            % Start -> End
            plot(eyeX(i, w), eyeY(i, w), '-', 'Color', [cmap(t,:) 0.5], 'LineWidth', 0.5);
        end

        % Fixation and target locations actually used by these trials.
        h = gobjects(0);  lbl = {};
        for m = 1:numel(marks)
            h(end+1)   = plot(marks(m).xy(:,1), marks(m).xy(:,2), marks(m).sym, ...
                'Color', 'k', 'MarkerSize', 8, 'LineWidth', 1.5, ...
                'MarkerFaceColor', 'none');  %#ok<AGROW>
            lbl{end+1} = marks(m).name;      %#ok<AGROW>
        end

        lim = axisLimits(marks, PAD_DEG);
        xlim(lim(1:2));  ylim(lim(3:4));
        plot(lim(1:2), [0 0], 'k:');  plot([0 0], lim(3:4), 'k:');

        axis square;
        xlabel('Eye X (\circ)');
        ylabel('Eye Y (\circ)');
        title(sprintf('%s  (n=%d)', strrep(tasks{t}, '_', ' '), numel(idx)));
        % Outside the axes: traces reach every corner, so an inset legend would
        % sit on the data or on the title.
        if ~isempty(h)
            legend(h, lbl, 'Location', 'southoutside', 'Orientation', 'horizontal');
        end
        set(gca, 'LineWidth', 1, 'FontSize', 12);
        hold off;
    end

    sgtitle(sprintf(['Calibrated eye traces, Start to End  |  evenly sampled completed trials' ...
        '  |  calibrated on %s'], strrep(strjoin(fitted_tasks, ', '), '_', ' ')));
    set(gcf, 'color', 'w');
end


function marks = markerLocations(comments_data, idx)
% Distinct fixation / target locations (deg) used by the given trials.
%
% Target 1 and Target 2 are pooled into a single group: they are the same kind
% of thing to look at, and a task can place both at the same locations.
% Columns absent or all-NaN for a task simply yield nothing to draw.

    spec = { 'Fixation', '+', {'Fixation_position'}
             'Target',   'o', {'Target_1_position', 'Target_2_position'} };

    marks = struct('name', {}, 'sym', {}, 'xy', {});
    for s = 1:size(spec, 1)
        xy = [];
        for p = spec{s,3}
            cx = [p{1} '_x'];  cy = [p{1} '_y'];
            if ~all(ismember({cx, cy}, comments_data.Properties.VariableNames))
                continue
            end
            xy = [xy; comments_data.(cx)(idx), comments_data.(cy)(idx)];  %#ok<AGROW>
        end
        if isempty(xy);  continue;  end
        xy = unique(xy(all(~isnan(xy), 2), :), 'rows');
        if isempty(xy);  continue;  end

        marks(end+1) = struct('name', spec{s,1}, 'sym', spec{s,2}, 'xy', xy);  %#ok<AGROW>
    end
end


function lim = axisLimits(marks, pad)
% Frame the task's targets with padding. Traces stray outside on blinks, and
% clipping those keeps the region of interest readable.

    xy = vertcat(marks.xy);
    if isempty(xy)
        lim = [-15 15 -15 15];
        return
    end
    r = max(abs(xy(:))) + pad;
    lim = [-r r -r r];
end


function sel = pickBalancedTrials(pts, cal_trials, nWanted)
% Choose nWanted trials, spreading them evenly over target locations.
%
% Taking simply the earliest trials risks over-weighting whichever targets ran
% early in the session, and the gain and coupling terms need spatial spread.
% So cycle through the locations, taking the next-earliest unused trial of each
% in turn, until the quota is filled.
%
% A trial is grouped by its most eccentric location: the fixation epoch of every
% saccade trial sits at the same origin, so grouping on that would put every
% trial in one bin and defeat the balancing.

    ecc         = hypot(pts.tx, pts.ty);
    [~, order]  = sort(ecc, 'descend');
    [~, first]  = unique(pts.trial(order), 'first');
    trial_of    = pts.trial(order(first));            % each trial, once
    loc_of      = round([pts.tx(order(first)) pts.ty(order(first))], 3);

    [~, ~, grp] = unique(loc_of, 'rows');

    % Trials per location, earliest first, so the cycle is deterministic.
    buckets = cell(max(grp), 1);
    for g = 1:max(grp)
        buckets{g} = sort(trial_of(grp == g));
    end

    sel = [];
    while numel(sel) < nWanted
        took = false;
        for g = 1:numel(buckets)
            if isempty(buckets{g});  continue;  end
            sel(end+1) = buckets{g}(1);       %#ok<AGROW>
            buckets{g}(1) = [];
            took = true;
            if numel(sel) >= nWanted;  break;  end
        end
        if ~took;  break;  end               % every bucket drained
    end

    sel = intersect(cal_trials, sel);         % back to ascending trial order
end


function epochs = calibrationEpochs(task_name)
% Epochs of a trial where gaze location is known, per task.
%   anchor   - marker the averaging window starts from (s)
%   limit    - marker the window must end before (s)
%   target_x/_y - columns holding the known gaze location (deg)
%
% Each task must be listed explicitly. A task with no known-gaze epoch (e.g.
% time_delay_experiment) returns empty and must never be calibrated from:
% fitOneTask warns and skips it, so it is reported rather than mis-calibrated.
%
% task_name is matched as a substring, so the caller's own string ('saccade',
% 'visual_saccade', 'visual_saccades_experiment') all resolve here identically.

    if contains(task_name, 'fixation')
        epochs = struct( ...
            'name',     {'fixation_hold'}, ...
            'anchor',   {'Fixation_acquired'}, ...
            'limit',    {'Fixation_point_off'}, ...
            'target_x', {'Fixation_position_x'}, ...
            'target_y', {'Fixation_position_y'});

    elseif contains(task_name, 'saccade')
        % Pre-target fixation, then the hold on the acquired target.
        % Choicetime is the "Target 1 acquired" timestamp (see BlackrockLoader
        % maps.TimeEvents). The hold closes at Targets_off, NOT at End: on
        % correct trials End == Reward_start, which fires mid-hold.
        epochs = struct( ...
            'name',     {'pre_target_fixation', 'target_hold'}, ...
            'anchor',   {'Fixation_acquired',   'Choicetime'}, ...
            'limit',    {'Target_1_presented',  'Targets_off'}, ...
            'target_x', {'Fixation_position_x', 'Target_1_position_x'}, ...
            'target_y', {'Fixation_position_y', 'Target_1_position_y'});

    else
        epochs = [];
    end
end


function v_deg = applyAxis(v_main, v_other, coef)
% Apply one axis of the calibration model to raw voltage.
    v_deg = coef(1) + coef(2)*v_main + coef(3)*v_main.*v_other;
end


function D = designMatrix(v_main, v_other, use_coupling)
% Design matrix for one axis: [1, v_main, v_main.*v_other].
% The coupling column is left out entirely when it can't be identified.
    if use_coupling
        D = [ones(numel(v_main),1), v_main, v_main.*v_other];
    else
        D = [ones(numel(v_main),1), v_main];
    end
end


function r2 = rsquared(observed, predicted)
% Coefficient of determination of a fit against the known target positions.
    ss_res = sum((observed - predicted).^2);
    ss_tot = sum((observed - mean(observed)).^2);
    if ss_tot == 0
        r2 = NaN;                    % all targets identical: R^2 undefined
    else
        r2 = 1 - ss_res/ss_tot;
    end
end
