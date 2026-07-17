% A quality check script for checking the quality of the exported data
% files
function quality = QualityCheck(data, FileValid)
%FileValid = [Comments, Eye, Spike, SpikeWaveform]
%Function to perform Overall quality checks
%
%   data       - struct with the loaded products:
%                  .comments      - trials table (one row per trial)
%                  .eyes          - calibrated analog product (optional)(not used now)
%                  .spike         - online spike product (optional)
%                  .spikewaveform - spike waveform product (optional)
%   FileValid  - logical per product; FileValid(1) gates the behavior checks.
%
% Returns:
%   quality    - struct of what was checked and the numbers behind each panel:
%                  .behavior.tasks         - per-task trial counts / success rate
%                  .behavior.hitRate       - per saccade type, hit rate by target
%                  .behavior.psychometric  - per choice task, PSE / threshold,
%                                            first vs last half
%                  .pass                   - true when every check that ran passed
%
% Xuefei Yu Jul 16, 2026

    quality = struct('behavior', [], 'pass', true);

    if isempty(FileValid) || ~FileValid(1)
        disp('No valid comments file, skipping the behavior check.');
        quality.pass = false;
        return
    end
    quality = behaviorCheck(data.comments);

    %Quality check for the spikes 

    if FileValid(3) == 1
        %Check spikes
        if FileValid(4) == 1
            %Check waveform
            CheckWaveform = true;
        end
        
        %Make a plot with gui handles, a list showing all channels, and a
        %second list showing all units in the selected channel, default is
        %unit 1 and channel 1
        %Use a left arrow button to swith to the previous unit and right
        %arrow button to switch to the next unit. Channel and unit can also
        %be modifyed through the channel and unit list. 

        %Do the following spike quality check
        %(1)Plot the the baseline firing rate changes as a function of Trial NO 
        % like in the behavior check, use different block color to indicate
        % different trials. Use open circle to indicate unsuccessful trial
        % and filled dots to indicate successful trial. 
        % On the top, list the average firing rate (+- std) of the baseline in the current task. 
        % Bold and highlight the text if the average firing rate is less than a threshold, e.g 5Hz 
        % On the title or above, also show the overall spike rate, if it's
        % less than the Treshold, highlight it.(If there is space, also show the threhsold)

        %(2) Plot the histogram for the inter spike interval for all
        %spikes.
        %Stack the interspike interval with different tasks, and do an
        %exponential fitting for the spike interval for each task.
        % Show the voliation rate: i.e. the proportion of spike intervals
        % within 1ms 
        % Show the number of total spikes, and number of total spikes in
        % each task. Show the Fano Factor for total spikes and for each
        % task. 



        %Do the waveform check if waveforms are available for the selected
        %unit
        %(3)Plot the waveform, use different color for different tasks. Use
        %a thicker curve to indicate the average, overlap with each
        %waveforms with light/opac same color.      
   
        % Calculate the Signal Noise Ratio, SpikeWaveWidth, Top to valley
        % Difference for all the waveforms, and also for each task. List it
        % below the waveform plot as a table. Make this waveform feature
        % extraction function a reusable one and save separately in the
        % folder. 

        %(3)Do PCA and plot the waveform on the first three PC axis, and
        %color different waveforms in different tasks with different color.
        % Mark the centroid for the "clusters" in each task and calculate
        % the within clusters distance and between clusters distance ratio.

        % Try to make those waveform check functions reusable for further
        % use. 
        


        




    end




end


function B = behaviorCheck(cd)
% All behavior panels on one figure:
%   row 1 : running success rate over the whole recording   (1)
%   row 2 : target hit-rate maps          | psychometric    (2) | (4)
%   row 3 : saccade trials per condition  | choice conditions (3) | (5)
%
% The left column subdivides per saccade task, the right column per choice task,
% so a session running several of either gets a panel each rather than one panel
% silently covering only the first.

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
    %B.hitRate = plotHitRateMaps(tl, 3, cd);
    plotHitRateMaps(tl, 3, cd);

    % (4) psychometric, second row right -----------------------------------
   % B.psychometric = plotPsychometric(tl, 4, cd);
    plotPsychometric(tl, 4, cd);

    % (3) saccade conditions, third row left --------------------------------
    plotSaccadeConditions(tl, 5, cd);

    % (5) choice conditions, third row right ---------------------------------
    plotChoiceConditions(tl, 6, cd);

    title(tl, 'Behavior quality check', 'FontWeight', 'bold');
end


% =========================================================================
% (1) Running success rate
% =========================================================================
function S = plotSuccessRate(ax, cd, tasks, colors, binN, stepN)
% Success rate in a sliding window over trial number, with each task's stretch
% of the recording shaded behind it and its trial counts printed on top.
%
% The shading and labels are per contiguous block, so a task run twice shows as
% two stretches. The RETURNED S is per task instead: one row for each unique
% task, its blocks merged, since that is what "how did each task go" asks for.

    hold(ax, 'on');

    n       = height(cd);
    correct = strcmp(cd.Trialoutcome, 'correct');
    wrong = strcmp(cd.Trialoutcome, 'wrong');
    success = correct | wrong;
    x       = (1:n).';

    % Shade each contiguous run of one task, and label it with that block's own
    % numbers (break/timeout/incomplete are only meaningful per block).
    blocks = contiguousBlocks(cd.Task);

    for b = 1:numel(blocks)
        rows = blocks(b).first:blocks(b).last;
        ci   = find(strcmp(tasks, blocks(b).name));

        patch(ax, [blocks(b).first-0.5 blocks(b).last+0.5 blocks(b).last+0.5 blocks(b).first-0.5], ...
            [0 0 1 1], colors(ci,:), 'FaceAlpha', 0.10, 'EdgeColor', 'none');

        s = struct( ...
            'Session',    unique(cd.Session(rows))', ...
            'total',      numel(rows), ...
            'success',    sum(success(rows)), ...
            'broke',      sum(strcmp(cd.Trialoutcome(rows), 'broke_fixation')), ...
            'timeout',    sum(strcmp(cd.Trialoutcome(rows), 'timeout')), ...
            'incomplete', sum(cd.Save_complete(rows) ~= 1), ...
            'rate',       mean(success(rows)));

        text(ax, mean([blocks(b).first blocks(b).last]), 1.03, ...
            sprintf(['%s\nSession %s | N=%d\nsuccess %d (%.0f%%)\nbreak %d | timeout %d\n' ...
                     'incomplete %d'], ...
                strrep(blocks(b).name, '_', ' '), mat2str(s.Session), s.total, ...
                s.success, 100*s.rate, s.broke, s.timeout, s.incomplete), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontSize', 8, 'Color', colors(ci,:)*0.6);
    end

    % One row per task, its blocks merged. tasks is unique(cd.Task,'stable'), so
    % rows come out in the order the session first ran each task.
    S = struct('Task', {}, 'total', {}, 'success', {}, 'rate', {});
    for t = 1:numel(tasks)
        rows = strcmp(cd.Task, tasks{t});
        S(t) = struct('Task', tasks{t}, ...
                      'total',   sum(rows), ...
                      'success', sum(success & rows), ...
                      'rate',    mean(success(rows)));
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
        blankPanel(nexttile(tl, tile), 'No saccade task');
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

        % A saccade group is picked by task name alone, so its trials may carry no
        % recorded target position at all. There is no map to draw then, and the
        % axis limits below would come out empty. Report it and keep going: the
        % rest of this session's panels are still worth having.
        if isempty(loc)
            H(end+1) = struct('type', grps(g).name, 'xy', zeros(0,2), ...
                              'hitRate', zeros(0,1), 'n', zeros(0,1));  %#ok<AGROW>
            blankPanel(ax, '%s:\nno target positions', grps(g).name);
            continue
        end

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


function grps = choiceGroups(cd)
% The choice tasks present in this session, one entry each.
%
% This is the only place in the file that knows a task by name. Everything it
% returns is what the psychometric and condition panels need in order to plot
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
        % table before the loader learns to record its stimulus. Say so on the
        % panel rather than erroring out of the whole quality check.
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


% =========================================================================
% (4) Psychometric function, first vs last half, per choice task
% =========================================================================
function P = plotPsychometric(tl, tile, cd)
% One psychometric per choice task, side by side.

    P    = struct('task', {}, 'half', {}, 'pse', {}, 'threshold', {}, ...
                  'n', {}, 'separable', {});
    grps = choiceGroups(cd);

    if isempty(grps)
        blankPanel(nexttile(tl, tile), 'No choice task');
        return
    end

    inner = tiledlayout(tl, 1, numel(grps), 'TileSpacing', 'compact', 'Padding', 'none');
    inner.Layout.Tile = tile;

    for g = 1:numel(grps)
        ax = nexttile(inner);
        if emptyPanel(ax, grps(g));  continue;  end

        r = grps(g).rows;
        Pg = psychometricPanel(ax, cd.(grps(g).stim)(r), cd.Stimulus_direction(r), ...
                               cd.Choose_leftright(r), grps(g).name, grps(g).xlabel);
        P = [P, Pg];  %#ok<AGROW>
    end
end


function P = psychometricPanel(ax, stim, stim_dir, choice, name, xlab)
% Psychometric fitted separately on the first and last half of the trials, so a
% shift in bias or threshold across the session shows up.
%
% Task-blind: it plots against whatever stimulus it is handed. Pass target
% asynchrony and it is a time-delay psychometric; pass coherence and it is a
% motion psychometric. Nothing below names a task or a column.
%
%   stim     - stimulus strength per trial (asynchrony in ms, coherence, ...)
%   stim_dir - +1 / -1 stimulus direction per trial
%   choice   - chosen side per trial (+1 = right)
%   name     - display name, for the title and the returned struct
%   xlab     - what to call the stimulus axis

    P     = struct('task', {}, 'half', {}, 'pse', {}, 'threshold', {}, ...
                   'n', {}, 'separable', {});
    nTot  = numel(stim);

    if nTot < 8
        blankPanel(ax, '%s:\ntoo few trials', name);
        return
    end

    idx    = (1:nTot).';
    half   = {idx(1:floor(end/2)), idx(floor(end/2)+1:end)};
    names  = {'First half', 'Last half'};
    cols   = [0 0.45 0.74; 0.85 0.33 0.10];

    hold(ax, 'on');
    h = gobjects(0);  lbl = {};
    for k = 1:2
        r      = half{k};
        psymat = [stim(r), stim_dir(r), double(choice(r) == 1)];

        % Fit only. psy carries the points and the fitted curve, so both halves
        % land on this one axes instead of each opening its own figure, and
        % nothing here has to re-derive what the fit already computed.
        % psy.separable flags a half whose choices the stimulus splits perfectly:
        % glmfit then has no finite ML slope and its threshold is meaningless.
        ws = warning('off', 'stats:glmfit:IterationLimit');
        wp = warning('off', 'stats:glmfit:PerfectSeparation');
        [pse, threshold, psy] = VisPsychometricFunction(psymat, 0);
        warning(ws);  warning(wp);

        P(end+1) = struct('task', name, 'half', names{k}, 'pse', pse, ...
            'threshold', threshold, 'n', numel(r), 'separable', psy.separable);  %#ok<AGROW>

        plot(ax, psy.stim_levels, psy.pRight, '.', 'Color', cols(k,:), 'MarkerSize', 16);
        h(end+1) = plot(ax, psy.fit_x, psy.fit_y, '-', ...
            'Color', cols(k,:), 'LineWidth', 2);  %#ok<AGROW>

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
    xlabel(ax, xlab);
    ylabel(ax, 'P(rightward)');
    title(ax, sprintf('%s psychometric', name));
    legend(ax, h, lbl, 'Location', 'northwest', 'FontSize', 8);
    set(ax, 'LineWidth', 1, 'FontSize', 11);
    box(ax, 'off');
end


function is_empty = emptyPanel(ax, grp)
% The two reasons a choice group has nothing to draw, reported on its own tile so
% the panel says which task went missing and why.
    is_empty = true;
    if grp.missing
        blankPanel(ax, '%s:\n%s column missing', grp.name, strrep(grp.stim, '_', ' '));
    elseif isempty(grp.rows)
        blankPanel(ax, '%s:\nno completed choice trials', grp.name);
    else
        is_empty = false;
    end
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
        blankPanel(nexttile(tl, tile), 'No saccade task');
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
    % Same story as the hit-rate maps: saccade trials with no recorded eccentricity
    % leave nothing to lay out. Claim the tile and say so, rather than returning
    % and leaving an unexplained hole in the figure.
    if isempty(rowspec)
        blankPanel(nexttile(tl, tile), 'No saccade conditions');
        return
    end

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


function plotChoiceConditions(tl, tile, cd)
% Trials per condition for each choice task, side by side.

    grps = choiceGroups(cd);
    if isempty(grps)
        blankPanel(nexttile(tl, tile), 'No choice task');
        return
    end

    inner = tiledlayout(tl, 1, numel(grps), 'TileSpacing', 'compact', 'Padding', 'none');
    inner.Layout.Tile = tile;

    for g = 1:numel(grps)
        ax = nexttile(inner);
        if emptyPanel(ax, grps(g));  continue;  end

        r = grps(g).rows;
        conditionPanel(ax, cd.(grps(g).stim)(r), cd.Stimulus_direction(r), ...
                       cd.Trialoutcome(r), grps(g).name, grps(g).xlabel_signed);
    end
end


function conditionPanel(ax, stim, stim_dir, outcome, name, xlab_signed)
% Trials per condition for a choice task: the looping variables are the stimulus
% strength and its direction, which combine into one signed stimulus axis.
%
% Task-blind, like psychometricPanel: signed asynchrony and signed coherence are
% the same plot over a different column.
%
%   outcome  - Trialoutcome per trial, for the correct/wrong stack

    ok = ~isnan(stim) & ~isnan(stim_dir);
    if ~any(ok)
        blankPanel(ax, '%s:\nno conditions', name);
        return
    end

    signed      = stim(ok) .* stim_dir(ok);
    outcome     = outcome(ok);
    [lv, ~, id] = unique(signed);

    % Bars are the successful trials only: correct + wrong. Broke and timeout
    % trials never got to a choice, so they say nothing about this condition;
    % their counts are on the success-rate panel above.
    correct = accumarray(id, strcmp(outcome, 'correct'));
    wrong   = accumarray(id, strcmp(outcome, 'wrong'));

    col = outcomeColors();
    b = bar(ax, categorical(lv), [correct, wrong], 'stacked');
    b(1).FaceColor = col.correct;
    b(2).FaceColor = col.wrong;
    xlabel(ax, xlab_signed);
    ylabel(ax, 'Successful trials');
    title(ax, sprintf('%s trials per condition', name));
    legend(ax, {'correct', 'wrong'}, 'Location', 'best', 'FontSize', 8);
    set(ax, 'LineWidth', 1, 'FontSize', 10);
    box(ax, 'off');
end


function col = outcomeColors()
% Colours for the successful-trial categories, shared by both condition panels
% so a stack means the same thing in each.
    col = struct('correct', [0.2 0.6 0.3], 'wrong', [0.8 0.4 0.4]);
end


function blankPanel(ax, varargin)
% An axes that says why it has nothing to show, rather than an empty box the
% reader has to guess at. Takes sprintf arguments.
    text(ax, 0.5, 0.5, sprintf(varargin{:}), 'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle');
    axis(ax, 'off');
end
