% A quality check script for checking the quality of the exported data
% files
function quality = QualityCheck(data, FileValid)
%FileValid = [Comments, Eye, Spike, SpikeWaveform]
%Function to perform Overall quality checks
%
%   data       - struct with the loaded products:
%                  .comments      - trials table (one row per trial)
%                  .eyes          - calibrated analog product (optional)
%                  .spike         - online spike product (optional)
%                  .spikewaveform - spike waveform product (optional)
%   FileValid  - logical per product; FileValid(1) gates the behavior checks.
%
% Returns:
%   quality    - struct of what was checked and the numbers behind each panel:
%                  .behavior.tasks         - per-task trial counts / success rate
%                  .behavior.hitRate       - per saccade type, hit rate by target
%                  .behavior.psychometric  - PSE / threshold, first vs last half
%                  .pass                   - true when every check that ran passed
%
% Xuefei Yu Jul 16, 2026

    quality = struct('behavior', [], 'pass', true);

    if isempty(FileValid) || ~FileValid(1)
        disp('No valid comments file, skipping the behavior check.');
        quality.pass = false;
        return
    end
    quality.behavior = behaviorCheck(data.comments);
end


function B = behaviorCheck(cd)
% All behavior panels on one figure:
%   row 1 : running success rate over the whole recording   (1)
%   row 2 : target hit-rate maps          | psychometric    (2) | (4)
%   row 3 : saccade trials per condition  | delay conditions (3) | (5)

    TRIAL_BIN  = 20;    % trials per accuracy window
    TRIAL_STEP = 5;     % step between windows

    tasks  = unique(cd.Task, 'stable');
    colors = lines(numel(tasks));

    fig = figure('Name', 'Quality check: behavior');
    set(fig, 'color', 'w', 'Position', [60 60 1250 900]);
    tl = tiledlayout(fig, 3, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

    % (1) success rate, spanning the whole first row -----------------------
    ax = nexttile(tl, 1, [1 2]);
    B.tasks = plotSuccessRate(ax, cd, tasks, colors, TRIAL_BIN, TRIAL_STEP);

    % (2) hit-rate maps, second row left -----------------------------------
    B.hitRate = plotHitRateMaps(tl, 3, cd);

    % (4) psychometric, second row right -----------------------------------
    B.psychometric = plotPsychometric(nexttile(tl, 4), cd);

    % (3) saccade conditions, third row left --------------------------------
    plotSaccadeConditions(tl, 5, cd);

    % (5) delay conditions, third row right ---------------------------------
    plotDelayConditions(nexttile(tl, 6), cd);

    title(tl, 'Behavior quality check', 'FontWeight', 'bold');
end


% =========================================================================
% (1) Running success rate
% =========================================================================
function S = plotSuccessRate(ax, cd, tasks, colors, binN, stepN)
% Success rate in a sliding window over trial number, with each task's stretch
% of the recording shaded behind it and its trial counts printed on top.

    hold(ax, 'on');

    n       = height(cd);
    correct = strcmp(cd.Trialoutcome, 'correct');
    wrong = strcmp(cd.Trialoutcome, 'wrong');
    success = correct | wrong;
    x       = (1:n).';

    % Shade each contiguous run of one task, and label it.
    blocks = contiguousBlocks(cd.Task);
    S      = struct('Task', {}, 'Session', {}, 'total', {}, 'success', {}, ...
                    'broke', {}, 'timeout', {}, 'incomplete', {}, 'rate', {});

    for b = 1:numel(blocks)
        rows = blocks(b).first:blocks(b).last;
        ci   = find(strcmp(tasks, blocks(b).name));

        patch(ax, [blocks(b).first-0.5 blocks(b).last+0.5 blocks(b).last+0.5 blocks(b).first-0.5], ...
            [0 0 1 1], colors(ci,:), 'FaceAlpha', 0.10, 'EdgeColor', 'none');

        s = struct( ...
            'Task',       blocks(b).name, ...
            'Session',    unique(cd.Session(rows))', ...
            'total',      numel(rows), ...
            'success',    sum(success(rows)), ...
            'broke',      sum(strcmp(cd.Trialoutcome(rows), 'broke_fixation')), ...
            'timeout',    sum(strcmp(cd.Trialoutcome(rows), 'timeout')), ...
            'incomplete', sum(cd.Save_complete(rows) ~= 1), ...
            'rate',       mean(success(rows)));
        S(end+1) = s;  

        text(ax, mean([blocks(b).first blocks(b).last]), 1.03, ...
            sprintf(['%s\nSession %s | N=%d\nsuccess %d (%.0f%%)\nbreak %d | timeout %d\n' ...
                     'incomplete %d'], ...
                strrep(blocks(b).name, '_', ' '), mat2str(s.Session), s.total, ...
                s.success, 100*s.rate, s.broke, s.timeout, s.incomplete), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontSize', 8, 'Color', colors(ci,:)*0.6);
    end

    % Sliding-window accuracy across the whole recording, so the curve carries
    % over task boundaries and any drift at a handover is visible.
    starts = 1:stepN:max(1, n-binN+1);
    ctr    = nan(numel(starts),1);
    acc    = nan(numel(starts),1);
    for i = 1:numel(starts)
        w      = starts(i):min(n, starts(i)+binN-1);
        ctr(i) = mean(w);
        acc(i) = mean(success(w));
    end
    plot(ax, ctr, acc, '-k', 'LineWidth', 1.5);
    plot(ax, x(success), 1.005*ones(sum(success),1),  '|', 'Color', [0 .6 0], 'MarkerSize', 3);
    plot(ax, x(~success), -0.005*ones(sum(~success),1), '|', 'Color', [.8 0 0], 'MarkerSize', 3);

    ylim(ax, [-0.02 1.35]);          % headroom for the per-block labels
    xlim(ax, [0.5 n+0.5]);
    yticks(ax, [0 0.5 1]);
    xlabel(ax, 'Trial number');
    ylabel(ax, 'Success rate');
    title(ax, sprintf('Success rate (%d-trial window, %d-trial step)', binN, stepN));
    set(ax, 'LineWidth', 1, 'FontSize', 11);
    box(ax, 'off');
end


function blocks = contiguousBlocks(labels)
% Runs of identical consecutive labels, as first/last row indices.
    blocks = struct('name', {}, 'first', {}, 'last', {});
    if isempty(labels);  return;  end
    start = 1;
    for i = 2:numel(labels)+1
        if i > numel(labels) || ~strcmp(labels{i}, labels{start})
            blocks(end+1) = struct('name', labels{start}, 'first', start, 'last', i-1);  %#ok<AGROW>
            start = i;
        end
    end
end


% =========================================================================
% (2) Target hit-rate heat maps
% =========================================================================
function H = plotHitRateMaps(tl, tile, cd)
% Hit rate by target location for each kind of saccade task, as a surface over
% the sampled target space with the targets drawn on top.

    H     = struct('type', {}, 'xy', {}, 'hitRate', {}, 'n', {});
    grps  = saccadeGroups(cd);

    if isempty(grps)
        ax = nexttile(tl, tile);
        text(ax, 0.5, 0.5, 'No saccade task', 'HorizontalAlignment', 'center');
        axis(ax, 'off');
        return
    end

    inner = tiledlayout(tl, 1, numel(grps), 'TileSpacing', 'compact', 'Padding', 'none');
    inner.Layout.Tile = tile;

    for g = 1:numel(grps)
        ax   = nexttile(inner);
        rows = grps(g).rows;

        loc     = round([cd.Target_1_position_x(rows), cd.Target_1_position_y(rows)], 3);
        ok      = all(~isnan(loc), 2);
        loc     = loc(ok, :);
        success = strcmp(cd.Trialoutcome(rows(ok)), 'correct');%In saccade task, there is no wrong trials

        [xy, ~, id] = unique(loc, 'rows');
        nTrial  = accumarray(id, 1);
        hitRate = accumarray(id, success, [], @mean);

        H(end+1) = struct('type', grps(g).name, 'xy', xy, ...
                          'hitRate', hitRate, 'n', nTrial);  

        hold(ax, 'on');
        % Interpolated surface. griddata leaves everything outside the convex
        % hull of the sampled targets as NaN, which is what we want: unexplored
        % screen is null, not extrapolated to a made-up hit rate.
        if size(xy,1) >= 3
            pad = 2;
            gx  = linspace(min(xy(:,1))-pad, max(xy(:,1))+pad, 120);
            gy  = linspace(min(xy(:,2))-pad, max(xy(:,2))+pad, 120);
            [GX, GY] = meshgrid(gx, gy);
            GZ  = griddata(xy(:,1), xy(:,2), hitRate, GX, GY, 'linear');
            imagesc(ax, gx, gy, GZ, 'AlphaData', ~isnan(GZ));
        end

        % Targets on top: circle area grows with how many trials were run there.
        scatter(ax, xy(:,1), xy(:,2), 20 + 40*nTrial, 'k', 'LineWidth', 1);

        colormap(ax, parula);  clim(ax, [0 1]);
        cb = colorbar(ax);  cb.Label.String = 'Hit rate';
        axis(ax, 'equal');
        r = max(abs(xy(:))) + 4;
        xlim(ax, [-r r]);  ylim(ax, [-r r]);
        xlabel(ax, 'Target X (\circ)');
        ylabel(ax, 'Target Y (\circ)');
        title(ax, sprintf('%s  (n=%d)', grps(g).name, numel(rows)));
        set(ax, 'LineWidth', 1, 'FontSize', 10, 'YDir', 'normal');
    end
end


function grps = saccadeGroups(cd)
% Saccade trials split by task.
%


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
            grps(end+1) = struct('name', spec{s,1}, 'rows', rows);  
        end
    end

    % Any other saccade variant still gets a panel, named after itself, rather
    % than being dropped for not matching the two known kinds.
    for t = unique(cd.Task(is_sacc & ~known), 'stable')'
        grps(end+1) = struct('name', strrep(t{1}, '_', ' '), ...
            'rows', find(strcmp(cd.Task, t{1})));  
    end
end


% =========================================================================
% (4) Psychometric function, first vs last half
% =========================================================================
function P = plotPsychometric(ax, cd)
% Time-delay psychometric, fitted separately on the first and last half of the
% task's trials so a shift in bias or threshold across the session shows up.

    P    = struct('half', {}, 'pse', {}, 'threshold', {}, 'n', {}, 'separable', {});
    rows = find(contains(cd.Task, 'time_delay') & cd.Save_complete == 1 & ...
                ~isnan(cd.Choose_leftright) & ~isnan(cd.Requested_target_2_time_offset));

    if numel(rows) < 8
        text(ax, 0.5, 0.5, 'No time delay task', 'HorizontalAlignment', 'center');
        axis(ax, 'off');
        return
    end

    half   = {rows(1:floor(end/2)), rows(floor(end/2)+1:end)};
    names  = {'First half', 'Last half'};
    cols   = [0 0.45 0.74; 0.85 0.33 0.10];

    hold(ax, 'on');
    h = gobjects(0);  lbl = {};
    for k = 1:2
        r      = half{k};
        psymat = [cd.Requested_target_2_time_offset(r), ...
                  cd.Stimulus_direction(r), ...
                  double(cd.Choose_leftright(r) == 1)];

        % Fit only. psy carries the points and the fitted curve, so both halves
        % land on this one axes instead of each opening its own figure, and
        % nothing here has to re-derive what the fit already computed.
        % psy.separable flags a half whose choices the stimulus splits perfectly:
        % glmfit then has no finite ML slope and its threshold is meaningless.
        ws = warning('off', 'stats:glmfit:IterationLimit');
        wp = warning('off', 'stats:glmfit:PerfectSeparation');
        [pse, threshold, psy] = VisPsychometricFunction(psymat, 0);
        warning(ws);  warning(wp);

        P(end+1) = struct('half', names{k}, 'pse', pse, 'threshold', threshold, ...
                          'n', numel(r), 'separable', psy.separable);  

        plot(ax, psy.stim_levels, psy.pRight, '.', 'Color', cols(k,:), 'MarkerSize', 16);
        h(end+1) = plot(ax, psy.fit_x, psy.fit_y, '-', ...
            'Color', cols(k,:), 'LineWidth', 2);  

        % Two rows per half: on one line the entry runs wider than the panel.
        if psy.separable
            thr_txt = 'thr unreliable';
        else
            thr_txt = sprintf('thr %.1f', threshold);
        end
        lbl{end+1} = sprintf('%s (n=%d)\nPSE %.1f, %s', ...
            names{k}, numel(r), pse, thr_txt);  %#ok<AGROW>
    end

    plot(ax, xlim(ax), [0.5 0.5], '--k');
    plot(ax, [0 0], [0 1], '--k');
    ylim(ax, [0 1]);  yticks(ax, [0 0.5 1]);
    xlabel(ax, 'Target asynchrony (ms)');
    ylabel(ax, 'P(rightward)');
    title(ax, 'Time delay psychometric');
    legend(ax, h, lbl, 'Location', 'northwest', 'FontSize', 8);
    set(ax, 'LineWidth', 1, 'FontSize', 11);
    box(ax, 'off');
end



% =========================================================================
% (3) / (5) Trials per condition
% =========================================================================
function plotSaccadeConditions(tl, tile, cd)
% Trials per condition for each saccade task. Target angle and eccentricity are
% the two looping variables, so eccentricity gets one row of the grid each and
% the bars run over angle.

    grps = saccadeGroups(cd);
    if isempty(grps)
        ax = nexttile(tl, tile);
        text(ax, 0.5, 0.5, 'No saccade task', 'HorizontalAlignment', 'center');
        axis(ax, 'off');
        return
    end

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

    % One angle axis shared by every row: each row builds its own categories
    % otherwise, and the same angle then lands at a different x per row, which
    % makes the rows impossible to read against each other.
    all_ang = round(cd.Target_1_angle(vertcat(rowspec.rows)), 1);
    angles  = unique(all_ang(~isnan(all_ang)));
    nAng    = numel(angles);

    inner = tiledlayout(tl, numel(rowspec), 1, 'TileSpacing', 'tight', 'Padding', 'none');
    inner.Layout.Tile = tile;

    col = outcomeColors();

    for i = 1:numel(rowspec)
        ax   = nexttile(inner);
        ang  = round(cd.Target_1_angle(rowspec(i).rows), 1);
        outc = cd.Trialoutcome(rowspec(i).rows);

        % Successful trials only. A saccade task has nothing to choose between,
        % so there are no wrong trials and success is just correct. Angles the
        % row never ran count 0 and leave an empty column.
        nCor = arrayfun(@(a) sum(ang == a & strcmp(outc, 'correct')), angles);

        bar(ax, 1:nAng, nCor, 'FaceColor', col.correct);
        xlim(ax, [0.5 nAng+0.5]);
        ylabel(ax, sprintf('%.3g\\circ', rowspec(i).ecc));
        set(ax, 'LineWidth', 1, 'FontSize', 9, 'XTick', 1:nAng);
        box(ax, 'off');
        if i == 1
            title(ax, 'Successful saccade trials per condition (row = eccentricity)', ...
                'FontSize', 10);
        end
        if i == numel(rowspec)
            xticklabels(ax, compose('%.0f', angles));
            xlabel(ax, 'Target angle (\circ)');
        else
            xticklabels(ax, []);
        end
    end
end


function plotDelayConditions(ax, cd)
% Trials per condition for the time-delay task: the looping variables are the
% requested offset and the stimulus direction, which combine into a signed delay.

    rows = find(contains(cd.Task, 'time_delay') & ...
                ~isnan(cd.Requested_target_2_time_offset) & ~isnan(cd.Stimulus_direction));
    if isempty(rows)
        text(ax, 0.5, 0.5, 'No time delay task', 'HorizontalAlignment', 'center');
        axis(ax, 'off');
        return
    end

    signed      = cd.Requested_target_2_time_offset(rows) .* cd.Stimulus_direction(rows);
    [lv, ~, id] = unique(signed);

    % Bars are the successful trials only: correct + wrong. Broke and timeout
    % trials never got to a choice, so they say nothing about this condition;
    % their counts are on the success-rate panel above.
    correct = accumarray(id, strcmp(cd.Trialoutcome(rows), 'correct'));
    wrong   = accumarray(id, strcmp(cd.Trialoutcome(rows), 'wrong'));

    col = outcomeColors();
    b = bar(ax, categorical(lv), [correct, wrong], 'stacked');
    b(1).FaceColor = col.correct;
    b(2).FaceColor = col.wrong;
    xlabel(ax, 'Signed target asynchrony (ms)');
    ylabel(ax, 'Successful trials');
    title(ax, 'Time delay trials per condition');
    legend(ax, {'correct', 'wrong'}, 'Location', 'best', 'FontSize', 8);
    set(ax, 'LineWidth', 1, 'FontSize', 10);
    box(ax, 'off');
end


function col = outcomeColors()
% Colours for the successful-trial categories, shared by both condition panels
% so a stack means the same thing in each.
    col = struct('correct', [0.2 0.6 0.3], 'wrong', [0.8 0.4 0.4]);
end
