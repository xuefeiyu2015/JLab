function summary = behaviorCheck(cd, plotFlag)
% Behavior quality check: standalone, callable right after loading the trials
% table (no spike/analog data needed).
%
%   cd       - trials table (one row per trial).
%   plotFlag - (optional, default true) draw the figure. false runs headless:
%              no figure is ever created, only the numbers are computed.
%
% Returns summary, the behavior summary about the task conditions
%   summary = B.condition    - table, one row per task: TotalValidTrials/MinRep/MinRepCondition


% Xuefei Yu Jul 2026

    if nargin < 2;  plotFlag = true;  end
    B = behaviorStats(cd);
    if plotFlag
        plotBehaviorStats(B);
    end
    summary = B.conditions;
end


% =========================================================================
% COMPUTE — every number behind every panel; no graphics calls anywhere below
% =========================================================================

function B = behaviorStats(cd)
% All panels are computed regardless of plotFlag, since the headless path wants
% B fully populated (for export, or for a caller that only needs the numbers).
    TRIAL_BIN  = 20;    % trials per accuracy window
    TRIAL_STEP = 5;     % step between windows

    tasks = unique(cd.Task, 'stable');

    B.successRate = computeSuccessRate(cd, TRIAL_BIN, TRIAL_STEP);
    B.tasks       = perTaskSummary(cd, tasks, B.successRate.success);
    B.conditions  = conditionTable(cd);

    B.hitRateMaps       = computeHitRateMaps(cd);
    B.psychometric      = computePsychometric(cd);
    B.saccadeConditions = computeSaccadeConditions(cd);
    B.choiceConditions  = computeChoiceConditions(cd);
end


% -------------------------------------------------------------------------
% (1) Running success rate
% -------------------------------------------------------------------------
function SR = computeSuccessRate(cd, binN, stepN)
% Per-block outcome tallies (for the shading + label), the sliding-window
% accuracy curve, and success/fail per trial.
    n       = height(cd);
    correct = strcmp(cd.Trialoutcome, 'correct');
    wrong   = strcmp(cd.Trialoutcome, 'wrong');
    success = correct | wrong;

    blocks = contiguousBlocks(cd.Task);
    for b = 1:numel(blocks)
        rows = blocks(b).first:blocks(b).last;
        blocks(b).Session    = unique(cd.Session(rows))';
        blocks(b).total      = numel(rows);
        blocks(b).success    = sum(success(rows));
        blocks(b).broke      = sum(strcmp(cd.Trialoutcome(rows), 'broke_fixation'));
        blocks(b).timeout    = sum(strcmp(cd.Trialoutcome(rows), 'timeout'));
        blocks(b).incomplete = sum(cd.Save_complete(rows) ~= 1);
        blocks(b).rate       = mean(success(rows));
    end

    % Sliding-window accuracy across the whole recording, so the curve carries
    % over task boundaries and any drift at a handover is visible.
    starts = 1:stepN:max(1, n-binN+1);
    curveX = nan(numel(starts), 1);
    curveY = nan(numel(starts), 1);
    for i = 1:numel(starts)
        w         = starts(i):min(n, starts(i)+binN-1);
        curveX(i) = mean(w);
        curveY(i) = mean(success(w));
    end

  %
   SR = struct('n', n, 'success', success, 'blocks', blocks, ...
                'curveX', curveX, 'curveY', curveY, 'binN', binN, 'stepN', stepN);
  
end


function S = perTaskSummary(cd, tasks, success)
% One row per task, its blocks merged. tasks is unique(cd.Task,'stable'), so rows
% come out in the order the session first ran each task.
    S = struct('Task', {}, 'total', {}, 'success', {}, 'rate', {});
    for t = 1:numel(tasks)
        rows = strcmp(cd.Task, tasks{t});
        S(t) = struct('Task', tasks{t}, 'total', sum(rows), ...
                      'success', sum(success & rows), 'rate', mean(success(rows)));
    end
end


% -------------------------------------------------------------------------
% (2) Target hit-rate heat maps
% -------------------------------------------------------------------------
function H = computeHitRateMaps(cd)
% Hit rate by target location for each saccade task. trialCount is the group's
% total trial count (for the panel title), separate from n (per-position count).
    H    = struct('type', {}, 'xy', {}, 'hitRate', {}, 'n', {}, 'trialCount', {});
    grps = saccadeGroups(cd);
    if isempty(grps);  return;  end

    for g = 1:numel(grps)
        rows = grps(g).rows;
        loc     = round([cd.Target_1_position_x(rows), cd.Target_1_position_y(rows)], 3);
        ok      = all(~isnan(loc), 2);
        loc     = loc(ok, :);
        success = strcmp(cd.Trialoutcome(rows(ok)), 'correct');  % no wrong trials in a saccade task

        % A saccade group is picked by task name alone, so its trials may carry no
        % recorded target position at all. Report it (empty xy) and keep going.
        if isempty(loc)
            H(end+1) = struct('type', grps(g).name, 'xy', zeros(0,2), ...
                'hitRate', zeros(0,1), 'n', zeros(0,1), 'trialCount', numel(rows));  %#ok<AGROW>
            continue
        end

        [xy, ~, id] = unique(loc, 'rows');
        nTrial  = accumarray(id, 1);
        hitRate = accumarray(id, success, [], @mean);

        H(end+1) = struct('type', grps(g).name, 'xy', xy, 'hitRate', hitRate, ...
            'n', nTrial, 'trialCount', numel(rows));  %#ok<AGROW>
    end
end


% -------------------------------------------------------------------------
% (4) Psychometric function, first vs last half, per choice task
% -------------------------------------------------------------------------
function P = computePsychometric(cd)
% Psychometric fitted separately on the first and last half of each choice
% task's trials, so a shift in bias or threshold across the session shows up.
% status classifies why a group has nothing to fit: 'missing' (stimulus column
% absent), 'empty' (no completed trials), 'few' (<8 trials), else 'ok'. When
% 'ok', halves(1:2) carries the full VisPsychometricFunction fit (psy) so the
% draw stage plots without re-fitting.
    grps = choiceGroups(cd);
    P = struct('name', {}, 'xlabel', {}, 'stim', {}, 'status', {}, 'halves', {});

    for g = 1:numel(grps)
        grp = grps(g);
        if grp.missing
            P(end+1) = struct('name', grp.name, 'xlabel', grp.xlabel, ...
                'stim', grp.stim, 'status', 'missing', 'halves', []);  %#ok<AGROW>
            continue
        elseif isempty(grp.rows)
            P(end+1) = struct('name', grp.name, 'xlabel', grp.xlabel, ...
                'stim', grp.stim, 'status', 'empty', 'halves', []);  %#ok<AGROW>
            continue
        end

        r        = grp.rows;
        stim     = cd.(grp.stim)(r);
        stim_dir = cd.Stimulus_direction(r);
        choice   = cd.Choose_leftright(r);
        nTot     = numel(stim);

        if nTot < 8
            P(end+1) = struct('name', grp.name, 'xlabel', grp.xlabel, ...
                'stim', grp.stim, 'status', 'few', 'halves', []);  %#ok<AGROW>
            continue
        end

        idx    = (1:nTot).';
        half   = {idx(1:floor(end/2)), idx(floor(end/2)+1:end)};
        names  = {'First half', 'Last half'};
        halves = struct('label', {}, 'n', {}, 'pse', {}, 'threshold', {}, ...
                        'separable', {}, 'psy', {});
        for k = 1:2
            rr     = half{k};
            psymat = [stim(rr), stim_dir(rr), double(choice(rr) == 1)];

            % Fit only (plot_flag 0): psy carries the points and the fitted curve,
            % so the draw stage plots without re-deriving anything. psy.separable
            % flags a half whose choices the stimulus splits perfectly: glmfit has
            % no finite ML slope then, and its threshold is meaningless.
            ws = warning('off', 'stats:glmfit:IterationLimit');
            wp = warning('off', 'stats:glmfit:PerfectSeparation');
            [pse, threshold, psy] = VisPsychometricFunction(psymat, 0);
            warning(ws);  warning(wp);

            halves(k) = struct('label', names{k}, 'n', numel(rr), 'pse', pse, ...
                'threshold', threshold, 'separable', psy.separable, 'psy', psy);
        end

        P(end+1) = struct('name', grp.name, 'xlabel', grp.xlabel, ...
            'stim', grp.stim, 'status', 'ok', 'halves', halves);  %#ok<AGROW>
    end
end


% -------------------------------------------------------------------------
% (3) / (5) Trials per condition
% -------------------------------------------------------------------------
function SC = computeSaccadeConditions(cd)
% Trials per condition for each saccade task: target angle and eccentricity are
% the two looping variables, so eccentricity becomes one row and the counts run
% over angle. present/hasConditions separate "no saccade task at all" from
% "saccade task(s), but none carry a recorded eccentricity".
    grps = saccadeGroups(cd);
    SC = struct('present', ~isempty(grps), 'hasConditions', false, 'angles', [], ...
               'rows', struct('name', {}, 'ecc', {}, 'nCor', {}));
    if isempty(grps);  return;  end

    % Every (group, eccentricity) pair becomes one row of the nested grid.
    rowspec = struct('name', {}, 'rows', {}, 'ecc', {});
    for g = 1:numel(grps)
        r   = grps(g).rows;
        ecc = round(cd.Target_1_eccentricity(r), 1);
        for e = unique(ecc(~isnan(ecc)))'
            rowspec(end+1) = struct('name', grps(g).name, ...
                'rows', r(ecc == e), 'ecc', e);  %#ok<AGROW>
        end
    end
    if isempty(rowspec);  return;  end
    SC.hasConditions = true;

    % One angle axis shared by every row: each row builds its own categories
    % otherwise, and the same angle then lands at a different x per row.
    all_ang   = round(cd.Target_1_angle(vertcat(rowspec.rows)), 1);
    SC.angles = unique(all_ang(~isnan(all_ang)));

    SC.rows = struct('name', {}, 'ecc', {}, 'nCor', {});
    for i = 1:numel(rowspec)
        ang  = round(cd.Target_1_angle(rowspec(i).rows), 1);
        outc = cd.Trialoutcome(rowspec(i).rows);
        % Successful trials only; a saccade task has no wrong trials. Angles the
        % row never ran count 0 and leave an empty column.
        nCor = arrayfun(@(a) sum(ang == a & strcmp(outc, 'correct')), SC.angles);
        SC.rows(i) = struct('name', rowspec(i).name, 'ecc', rowspec(i).ecc, 'nCor', nCor);
    end
end


function CC = computeChoiceConditions(cd)
% Trials per condition for each choice task: the looping variables are the
% stimulus strength and its direction, which combine into one signed stimulus
% axis. status: 'missing' (column absent), 'empty' (no completed trials),
% 'noconditions' (rows exist but stimulus direction is all NaN), else 'ok'.
    grps = choiceGroups(cd);
    CC = struct('name', {}, 'stim', {}, 'xlabelSigned', {}, 'status', {}, ...
               'levels', {}, 'correct', {}, 'wrong', {});

    for g = 1:numel(grps)
        grp = grps(g);
        if grp.missing
            CC(end+1) = struct('name', grp.name, 'stim', grp.stim, ...
                'xlabelSigned', grp.xlabel_signed, 'status', 'missing', ...
                'levels', [], 'correct', [], 'wrong', []);  %#ok<AGROW>
            continue
        elseif isempty(grp.rows)
            CC(end+1) = struct('name', grp.name, 'stim', grp.stim, ...
                'xlabelSigned', grp.xlabel_signed, 'status', 'empty', ...
                'levels', [], 'correct', [], 'wrong', []);  %#ok<AGROW>
            continue
        end

        r        = grp.rows;
        stim     = cd.(grp.stim)(r);
        stim_dir = cd.Stimulus_direction(r);
        outcome  = cd.Trialoutcome(r);
        ok = ~isnan(stim) & ~isnan(stim_dir);
        if ~any(ok)
            CC(end+1) = struct('name', grp.name, 'stim', grp.stim, ...
                'xlabelSigned', grp.xlabel_signed, 'status', 'noconditions', ...
                'levels', [], 'correct', [], 'wrong', []);  %#ok<AGROW>
            continue
        end

        signed      = stim(ok) .* stim_dir(ok);
        outcome     = outcome(ok);
        [lv, ~, id] = unique(signed);
        % Bars are the successful trials only: correct + wrong. Broke and timeout
        % trials never got to a choice, so they say nothing about this condition.
        correct = accumarray(id, strcmp(outcome, 'correct'));
        wrong   = accumarray(id, strcmp(outcome, 'wrong'));

        CC(end+1) = struct('name', grp.name, 'stim', grp.stim, ...
            'xlabelSigned', grp.xlabel_signed, 'status', 'ok', ...
            'levels', lv, 'correct', correct, 'wrong', wrong);  %#ok<AGROW>
    end
end


% -------------------------------------------------------------------------
% Pure grouping / table helpers, shared by several compute functions above
% -------------------------------------------------------------------------
function grps = saccadeGroups(cd)
% Saccade trials split by task.
    grps    = struct('name', {}, 'rows', {});
    is_sacc = contains(cd.Task, 'saccade');
    if ~any(is_sacc);  return;  end

    spec = { 'Memory saccade',          'memory_saccade'
             'Visually guided saccade', 'visual_saccade' };

    known = false(height(cd), 1);
    for s = 1:size(spec, 1)
        rows = find(is_sacc & contains(cd.Task, spec{s,2}));
        known(rows) = true;
        if ~isempty(rows)
            grps(end+1) = struct('name', spec{s,1}, 'rows', rows); %#ok<AGROW>
        end
    end

    % Any other saccade variant still gets a panel, named after itself, rather
    % than being dropped for not matching the two known kinds.
    for t = unique(cd.Task(is_sacc & ~known), 'stable')'
        grps(end+1) = struct('name', strrep(t{1}, '_', ' '), ...
            'rows', find(strcmp(cd.Task, t{1}))); %#ok<AGROW>
    end
end


function grps = choiceGroups(cd)
% The choice tasks present in this session, one entry each.
%
% This is the only place in the file that knows a task by name. Everything it
% returns is what the psychometric and condition panels need in order to compute
% without knowing which task they are drawing: which column holds the stimulus
% strength, and what to call that axis. A new choice task is a row of spec and
% nothing else.
    spec = { % name                    match         stimulus column
             % xlabel                          xlabel signed
             'Time delay',            'time_delay', 'Requested_target_2_time_offset', ...
             'Target asynchrony (ms)',        'Signed target asynchrony (ms)'
             'Motion discrimination', 'motion',     'Requested_motion_coherence', ...
             'Motion coherence (%)',          'Signed motion coherence (%)' };

    grps = struct('name', {}, 'rows', {}, 'stim', {}, 'xlabel', {}, ...
                  'xlabel_signed', {}, 'missing', {});

    for s = 1:size(spec, 1)
        [name, match, stim, xlab, xlab_signed] = deal(spec{s,:});

        is_task = contains(cd.Task, match);
        if ~any(is_task);  continue;  end

        % The stimulus column can be absent: a task's trials reach the exported
        % table before the loader learns to record its stimulus.
        if ~ismember(stim, cd.Properties.VariableNames)
            grps(end+1) = struct('name', name, 'rows', [], 'stim', stim, ...
                'xlabel', xlab, 'xlabel_signed', xlab_signed, 'missing', true);  %#ok<AGROW>
            continue
        end

        % Only trials that were saved whole and reached a choice: the rest carry
        % no stimulus-response pair to fit or count.
        rows = find(is_task & cd.Save_complete == 1 & ...
                    ~isnan(cd.Choose_leftright) & ~isnan(cd.(stim)));

        grps(end+1) = struct('name', name, 'rows', rows, 'stim', stim, ...
            'xlabel', xlab, 'xlabel_signed', xlab_signed, 'missing', false);  %#ok<AGROW>
    end

    % No fallback for unrecognised choice tasks, unlike saccadeGroups: without a
    % spec row we have no stimulus column, and there is nothing to plot against.
end


function tbl = conditionTable(cd)
% One row per task actually present in the recording, as a plain table:
%   Task | SuccessfulTrials | MinRep | MinRepCondition|SuccessfulRate
% TotalValidTrials = valid trials in the task; MinRep = fewest valid trials among
% the realized conditions; MinRepCondition = that condition's label.
%
% "Valid" matches the condition panels: correct trials for the saccade / fixation
% tasks, completed choice trials (Save_complete + a made choice) for the choice
% tasks. The condition is (target angle, eccentricity) for saccade tasks, the
% signed stimulus for the choice tasks, and none otherwise.
    tasks = unique(cd.Task, 'stable');
    n     = numel(tasks);
    Task             = strings(n, 1);
    SuccessfulTrials = zeros(n, 1);
    MinRep           = nan(n, 1);
    MinRepCondition  = strings(n, 1);
    SuccessfulRate = zeros(n, 1);
    for i = 1:n
        t    = tasks{i};
        rows = find(strcmp(cd.Task, t));
        s    = oneTaskCondition(cd, rows, t);
        Task(i)             = string(t);
        SuccessfulTrials(i) = s.nTrials;
        MinRep(i)           = s.minRep;
        MinRepCondition(i)  = string(s.minRepCond);
        SuccessfulRate(i)  = s.rate;
    end
    tbl = table(Task, SuccessfulTrials, MinRep, MinRepCondition,SuccessfulRate);
end


function s = oneTaskCondition(cd, rows, t)
% Valid-trial count and sparsest condition for one task, dispatched by task name.
    if contains(t, 'saccade')
        s = saccadeConditionSummary(cd, rows(strcmp(cd.Trialoutcome(rows), 'correct')));
        s.rate = sum(strcmp(cd.Trialoutcome(rows), 'correct'))/length(cd.Trialoutcome(rows));
        
    elseif contains(t, 'time_delay') || contains(t, 'motion')
        if contains(t, 'time_delay')
            stim = 'Requested_target_2_time_offset';
        else
            stim = 'Requested_motion_coherence';
        end
        if ~ismember(stim, cd.Properties.VariableNames)
            s = struct('nTrials', 0, 'minRep', NaN, 'minRepCond', '');
            return
        end
        %{
        keep   = rows(cd.Save_complete(rows) == 1 & ~isnan(cd.Choose_leftright(rows)) & ...
                      ~isnan(cd.(stim)(rows)));
        %}
        keep = rows(strcmp(cd.Trialoutcome(rows), 'correct')|strcmp(cd.Trialoutcome(rows), 'wrong'));
        signed = cd.(stim)(keep) .* cd.Stimulus_direction(keep);
        s = signedConditionSummary(signed);
        s.rate = length(keep)/length(rows);
        
    else   % fixation or unknown: a single condition
        nv = sum(strcmp(cd.Trialoutcome(rows), 'correct'));
        s  = struct('nTrials', nv, 'minRep', nv, 'minRepCond', '-');
        s.rate = nv/length(cd.Trialoutcome(rows));
        
    end
end


function s = saccadeConditionSummary(cd, rows)
% nTrials / sparsest (angle, eccentricity) condition over the given (correct) rows.
    s = struct('nTrials', numel(rows), 'minRep', NaN, 'minRepCond', '');
    if isempty(rows) || ~all(ismember({'Target_1_angle', 'Target_1_eccentricity'}, ...
                                       cd.Properties.VariableNames))
        return
    end
    ang = round(cd.Target_1_angle(rows), 1);
    ecc = round(cd.Target_1_eccentricity(rows), 1);
    ok  = ~isnan(ang) & ~isnan(ecc);
    if ~any(ok);  return;  end
    [uc, ~, id] = unique([ang(ok) ecc(ok)], 'rows');
    reps = accumarray(id, 1);
    [mn, mi] = min(reps);
    s.minRep     = mn;
    s.minRepCond = sprintf('ang%g_ecc%g', uc(mi, 1), uc(mi, 2));
end


function s = signedConditionSummary(signed)
% nTrials / sparsest signed-stimulus level.
    signed = signed(~isnan(signed));
    s = struct('nTrials', numel(signed), 'minRep', NaN, 'minRepCond', '');
    if isempty(signed);  return;  end
    [uv, ~, id] = unique(signed);
    reps = accumarray(id, 1);
    [mn, mi] = min(reps);
    s.minRep     = mn;
    s.minRepCond = sprintf('%g', uv(mi));
end


% =========================================================================
% DRAW — only graphics calls; reads exclusively from B, derives no new numbers
% =========================================================================

function plotBehaviorStats(B)
% All behavior panels on one figure:
%   row 1 : running success rate over the whole recording   (1)
%   row 2 : target hit-rate maps          | psychometric    (2) | (4)
%   row 3 : saccade trials per condition  | choice conditions (3) | (5)
%
% The left column subdivides per saccade task, the right column per choice task,
% so a session running several of either gets a panel each rather than one panel
% silently covering only the first.
    fig = figure('Name', 'Quality check: behavior', 'Color', 'w', 'Position', [60 60 1250 900]);
    tl  = tiledlayout(fig, 3, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

    ax = nexttile(tl, 1, [1 2]);
    drawSuccessRate(ax, B);

    drawHitRateMaps(tl, 3, B.hitRateMaps);
    drawPsychometric(tl, 4, B.psychometric);
    drawSaccadeConditions(tl, 5, B.saccadeConditions);
    drawChoiceConditions(tl, 6, B.choiceConditions);

    title(tl, 'Behavior quality check', 'FontWeight', 'bold');
end


function drawSuccessRate(ax, B)
% Success rate in a sliding window over trial number, with each task's stretch
% of the recording shaded behind it and its trial counts printed on top.
    hold(ax, 'on');
    SR = B.successRate;
    taskNames = {B.tasks.Task};
    colors    = lines(numel(taskNames));

    for b = 1:numel(SR.blocks)
        blk = SR.blocks(b);
        ci  = find(strcmp(taskNames, blk.name));
        patch(ax, [blk.first-0.5 blk.last+0.5 blk.last+0.5 blk.first-0.5], ...
            [0 0 1 1], colors(ci,:), 'FaceAlpha', 0.10, 'EdgeColor', 'none');
        text(ax, mean([blk.first blk.last]), 1.03, ...
            sprintf(['%s\nSession %s | N=%d\nsuccess %d (%.0f%%)\nbreak %d | timeout %d\n' ...
                     'incomplete %d'], strrep(blk.name, '_', ' '), mat2str(blk.Session), ...
                blk.total, blk.success, 100*blk.rate, blk.broke, blk.timeout, blk.incomplete), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontSize', 8, 'Color', colors(ci,:)*0.6);
    end

    x = (1:SR.n).';
    plot(ax, SR.curveX, SR.curveY, '-k', 'LineWidth', 1.5);
    plot(ax, x(SR.success), 1.005*ones(sum(SR.success),1), '|', 'Color', [0 .6 0], 'MarkerSize', 3);
    plot(ax, x(~SR.success), -0.005*ones(sum(~SR.success),1), '|', 'Color', [.8 0 0], 'MarkerSize', 3);

    ylim(ax, [-0.02 1.35]);          % headroom for the per-block labels
    xlim(ax, [0.5 SR.n+0.5]);
    yticks(ax, [0 0.5 1]);
    xlabel(ax, 'Trial number');
    ylabel(ax, sprintf('Success rate \n (%d-trial window, %d-trial step)',SR.binN, SR.stepN));
    %title(ax, sprintf('Success rate (%d-trial window, %d-trial step)', SR.binN, SR.stepN));
    set(ax, 'LineWidth', 1, 'FontSize', 11);
    box(ax, 'off');
end


function drawHitRateMaps(tl, tile, H)
% Hit rate by target location for each kind of saccade task, as a surface over
% the sampled target space with the targets drawn on top.
    if isempty(H)
        blankPanel(nexttile(tl, tile), 'No saccade task');
        return
    end

    inner = tiledlayout(tl, 1, numel(H), 'TileSpacing', 'compact', 'Padding', 'none');
    inner.Layout.Tile = tile;

    for g = 1:numel(H)
        ax = nexttile(inner);
        if isempty(H(g).xy)
            blankPanel(ax, '%s:\nno target positions', H(g).type);
            continue
        end

        xy = H(g).xy;  hitRate = H(g).hitRate;
        hold(ax, 'on');
        % Interpolated surface, recomputed here (a display-only interpolation of
        % the stored xy/hitRate, not itself a parameter worth caching). griddata
        % leaves everything outside the convex hull of the sampled targets as
        % NaN, which is what we want: unexplored screen is null, not extrapolated.
        if size(xy,1) >= 3
            pad = 2;
            gx  = linspace(min(xy(:,1))-pad, max(xy(:,1))+pad, 120);
            gy  = linspace(min(xy(:,2))-pad, max(xy(:,2))+pad, 120);
            [GX, GY] = meshgrid(gx, gy);
            GZ  = griddata(xy(:,1), xy(:,2), hitRate, GX, GY, 'linear');
            imagesc(ax, gx, gy, GZ, 'AlphaData', ~isnan(GZ));
        end

        % Targets on top, marking location only. A fixed small circle: scaling
        % the area by trial count swamped the map on sessions that ran many
        % repeats per target, and the counts are in H(g).n for anyone who wants
        % them.
        scatter(ax, xy(:,1), xy(:,2), 25, 'k', 'LineWidth', 1);

        colormap(ax, parula);  clim(ax, [0 1]);
        cb = colorbar(ax);  cb.Label.String = 'Hit rate';
        axis(ax, 'equal');
        r = max(abs(xy(:))) + 4;
        xlim(ax, [-r r]);  ylim(ax, [-r r]);
        xlabel(ax, 'Target X (\circ)');
        ylabel(ax, 'Target Y (\circ)');
        title(ax, sprintf('%s  (n=%d)', H(g).type, H(g).trialCount));
        set(ax, 'LineWidth', 1, 'FontSize', 10, 'YDir', 'normal');
    end
end


function drawPsychometric(tl, tile, P)
% One psychometric per choice task, side by side; first vs last half so a shift
% in bias or threshold across the session shows up. Task-blind: it plots
% whatever P(g) carries, without naming a task or a column.
    if isempty(P)
        blankPanel(nexttile(tl, tile), 'No choice task');
        return
    end

    inner = tiledlayout(tl, 1, numel(P), 'TileSpacing', 'compact', 'Padding', 'none');
    inner.Layout.Tile = tile;

    for g = 1:numel(P)
        ax = nexttile(inner);
        if drawStatusBlank(ax, P(g).status, P(g).name, P(g).stim);  continue;  end

        cols = [0 0.45 0.74; 0.85 0.33 0.10];
        hold(ax, 'on');
        h = gobjects(0);  lbl = {};
        for k = 1:2
            hv  = P(g).halves(k);
            psy = hv.psy;
            plot(ax, psy.stim_levels, psy.pRight, '.', 'Color', cols(k,:), 'MarkerSize', 16);
            h(end+1) = plot(ax, psy.fit_x, psy.fit_y, '-', ...
                'Color', cols(k,:), 'LineWidth', 2);  %#ok<AGROW>

            % Two rows per half: on one line the entry runs wider than the panel.
            if hv.separable
                thr_txt = 'thr unreliable';
            else
                thr_txt = sprintf('thr %.1f', hv.threshold);
            end
            lbl{end+1} = sprintf('%s (n=%d)\nPSE %.1f, %s', ...
                hv.label, hv.n, hv.pse, thr_txt);  %#ok<AGROW>
        end

        plot(ax, xlim(ax), [0.5 0.5], '--k');
        plot(ax, [0 0], [0 1], '--k');
        ylim(ax, [0 1]);  yticks(ax, [0 0.5 1]);
        xlabel(ax, P(g).xlabel);
        ylabel(ax, 'P(rightward)');
        title(ax, sprintf('%s psychometric', P(g).name));
        legend(ax, h, lbl, 'Location', 'northwest', 'FontSize', 8);
        set(ax, 'LineWidth', 1, 'FontSize', 11);
        box(ax, 'off');
    end
end


function drawSaccadeConditions(tl, tile, SC)
% Trials per condition for each saccade task; row = eccentricity, bars run over
% angle, sharing one angle axis so rows read against each other.
    if ~SC.present
        blankPanel(nexttile(tl, tile), 'No saccade task');
        return
    end
    if ~SC.hasConditions
        blankPanel(nexttile(tl, tile), 'No saccade conditions');
        return
    end

    nAng  = numel(SC.angles);
    inner = tiledlayout(tl, numel(SC.rows), 1, 'TileSpacing', 'tight', 'Padding', 'none');
    inner.Layout.Tile = tile;

    col = outcomeColors();
    for i = 1:numel(SC.rows)
        ax = nexttile(inner);
        bar(ax, 1:nAng, SC.rows(i).nCor, 'FaceColor', col.correct);
        xlim(ax, [0.5 nAng+0.5]);
        ylabel(ax, sprintf('%.3g\\circ', SC.rows(i).ecc));
        set(ax, 'LineWidth', 1, 'FontSize', 9, 'XTick', 1:nAng);
        box(ax, 'off');
        if i == 1
            title(ax, 'Successful saccade trials per condition (row = eccentricity)', ...
                'FontSize', 10);
        end
        if i == numel(SC.rows)
            xticklabels(ax, compose('%.0f', SC.angles));
            xlabel(ax, 'Target angle (\circ)');
        else
            xticklabels(ax, []);
        end
    end
end


function drawChoiceConditions(tl, tile, CC)
% Trials per condition for each choice task, side by side; the looping variables
% are the stimulus strength and its direction, combined into one signed axis.
    if isempty(CC)
        blankPanel(nexttile(tl, tile), 'No choice task');
        return
    end

    inner = tiledlayout(tl, 1, numel(CC), 'TileSpacing', 'compact', 'Padding', 'none');
    inner.Layout.Tile = tile;

    col = outcomeColors();
    for g = 1:numel(CC)
        ax = nexttile(inner);
        if drawStatusBlank(ax, CC(g).status, CC(g).name, CC(g).stim);  continue;  end

        b = bar(ax, categorical(CC(g).levels), [CC(g).correct, CC(g).wrong], 'stacked');
        b(1).FaceColor = col.correct;
        b(2).FaceColor = col.wrong;
        xlabel(ax, CC(g).xlabelSigned);
        ylabel(ax, 'Successful trials');
        title(ax, sprintf('%s trials per condition', CC(g).name));
        legend(ax, {'correct', 'wrong'}, 'Location', 'best', 'FontSize', 8);
        set(ax, 'LineWidth', 1, 'FontSize', 10);
        box(ax, 'off');
    end
end


function drew = drawStatusBlank(ax, status, name, stimName)
% The shared vocabulary of "nothing to draw" reasons across the psychometric and
% choice-condition panels, reported on the tile so the reader knows which task
% went missing and why. Returns true when it drew (status ~= 'ok'), so callers
% can `if drawStatusBlank(...); continue; end`.
    drew = true;
    switch status
        case 'missing'
            blankPanel(ax, '%s:\n%s column missing', name, strrep(stimName, '_', ' '));
        case 'empty'
            blankPanel(ax, '%s:\nno completed choice trials', name);
        case 'few'
            blankPanel(ax, '%s:\ntoo few trials', name);
        case 'noconditions'
            blankPanel(ax, '%s:\nno conditions', name);
        otherwise
            drew = false;
    end
end


function col = outcomeColors()
% Colours for the successful-trial categories, shared by both condition panels
% so a stack means the same thing in each.
    col = struct('correct', [0.2 0.6 0.3], 'wrong', [0.8 0.4 0.4]);
end
