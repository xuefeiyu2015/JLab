% BlackRockFileAnalyzer.m
% -------------------------------------------------------------------------
% Script to analyze parsed BlackRock behavioral data from time-delay
% experiments. Loads trial data, filters by task and valid choices, then
% visualizes the psychometric function and computes PSE and threshold.
% -------------------------------------------------------------------------
% Mar 4th, 2026 by Xuefei Yu
% -------------------------------------------------------------------------

close all;
clear;

%% -------------------------------------------------------------------------
%% 1. CONFIGURE DATA PATH
%% -------------------------------------------------------------------------
% Set paths and identifiers for the .mat file to load. The file is
% expected at: main_path/monkey/task_type/folder/data_date/Blackrock_*.mat

monkey = 'Monkey Porthos';
main_path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
data_date = '2026-03-06';  % Session date in yyyy-mm-dd
task_type = 'in_lab/timedelay';
folder = 'export_data';

% Task name used to filter trials (must match the Task field in expdata)
analyze_task = 'time_delay_experiment';

% Build full path to the BlackRock export .mat file
data_mat = sprintf('Blackrock_%s.mat', data_date);
data_path = fullfile(main_path, monkey, task_type, folder, data_date, data_mat);

%% -------------------------------------------------------------------------
%% 2. LOAD AND FILTER TRIALS
%% -------------------------------------------------------------------------
if exist(data_path, 'file')
    % Load the parsed BlackRock session file
    data = load(data_path);
    %mata_data = data.experiment; %Stores  the meta data for the session.
    expdata = data.trials; %Structure array for all trials

    % Keep only trials that were fully saved (no truncation)
    complete_saved = [expdata.Save_complete] == 1;

    % Keep only trials from the task we want to analyze
    task_sel = contains({expdata.Task}, analyze_task);

    % Keep only trials with a valid choice (Choose_target is not NaN)
    trial_sel = ~isnan([expdata.Choose_target]);

    % Combine all criteria: complete, correct task, valid choice
    selected_data = complete_saved & task_sel & trial_sel;

    % Subset of trials used for psychometric analysis
    task_data = expdata(selected_data);

    TotalTrials = sum(selected_data);

    %% ---------------------------------------------------------------------
    %% 3. BUILD PSYCHOMETRIC INPUT MATRIX
    %% ---------------------------------------------------------------------
    % Extract trial-level variables for psychometric function fitting.
    % VisPsychometricFunction expects columns: [stimulus, direction, choice].

    stimulus = [task_data.Requested_target_2_time_offset];  % Requested time delay (ms)
    stimulus_real = ([task_data.Target_2_presented] - [task_data.Target_1_presented]) * 1000;  % Actual delay in ms
    direction = [task_data.Stimulus_direction];   % Stimulus order (e.g. left-first vs right-first)
    choice_response = [task_data.Choose_leftright] == 1;  % 0 = left, 1 = right

    % Matrix passed to psychometric visualization: [stimulus, direction, choice]
    % Psymatrix is a matrix for psychometric function analysis,
    % with one row per trial and columns: [stimulus, direction, choice].
    % Each vector is transposed to ensure as a column in the matrix.
    Psymatrix = [stimulus', direction', choice_response'];

    % Plot psychometric curve and return point of subjective equality (PSE) and threshold
    [pse, threshold] = VisPsychometricFunction(Psymatrix);
    % ------------------------------------------------------
    % Plot bias (PSE) and threshold evolution over every 10 repetitions
    % (10 trials per stimulus condition)
    % ------------------------------------------------------

    unique_stim = unique(stimulus);
    min_trials_per_stim = 10; % window size

    % Find the minimum number of repeats across all stimuli
    counts = arrayfun(@(s) sum(stimulus == s), unique_stim);
    n_repeats = floor(min(counts) / min_trials_per_stim);
    ploteach = 1; %xplot each psychometric function

    % Only proceed if there is enough data
    if n_repeats > 0
        pse_history = zeros(n_repeats,1);
        threshold_history = zeros(n_repeats,1);
        trial_indices_per_stim = cell(length(unique_stim),1);

        % Precompute indices for each stimulus
        for i = 1:length(unique_stim)
            trial_indices_per_stim{i} = find(stimulus == unique_stim(i));
        end

        % --- Prepare colormap: deeper red with increasing repetition ---
        cmap = [linspace(1,0.45,n_repeats)' linspace(0.25,0,n_repeats)' linspace(0.25,0,n_repeats)']; % From light to darker red

        % --- Plot each psychometric function on a separate figure ---
        phs = gobjects(n_repeats,1);
        for rep = 1:n_repeats
            % Build indices for this repetition in all stimuli
            selected_idx = [];
            for i = 1:length(unique_stim)
                idxs = trial_indices_per_stim{i};
                idx_blk = idxs( (rep-1)*min_trials_per_stim+1 : rep*min_trials_per_stim );
                selected_idx = [selected_idx; idx_blk(:)];
            end
            selected_idx = sort(selected_idx);

            mat_blk = Psymatrix(selected_idx,:);
            c_this = cmap(rep,:);

            figure('Color','w','Name',sprintf('Psychometric function repetition %d',rep));
            [pse_blk, threshold_blk, hfit_curve] = VisPsychometricFunction(mat_blk, 1, c_this);
            title(sprintf('Psychometric function by repetition %d', rep)); % Override default title

            pse_history(rep) = pse_blk;
            threshold_history(rep) = threshold_blk;
            phs(rep) = hfit_curve;
        end

        % --- Make a single figure for Bias (PSE) and Threshold ---
        figure('Position',[200 250 650 400],'Color','w');
        tlo = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');

        % Bias (PSE) over repetitions
        ax_bias = nexttile(tlo,1);
        hold(ax_bias, 'on');
        for rep = 1:n_repeats
            plot(ax_bias, (rep)*min_trials_per_stim, pse_history(rep), 'o-', 'Color', cmap(rep,:), ...
                'MarkerFaceColor', cmap(rep,:), 'MarkerEdgeColor', cmap(rep,:), ...
                'LineWidth', 1.5, 'MarkerSize',7);
        end
        % Overlay connecting line in the average color, or plot all as one with colors
        plot(ax_bias, (1:n_repeats)*min_trials_per_stim, pse_history, '-', 'Color', [0.7 0 0], 'LineWidth', 2, 'HandleVisibility','off');
        hold(ax_bias, 'off');
        xlabel(ax_bias,'Repetition group (# trials per stim)');
        ylabel(ax_bias,'Bias (PSE)');
        title(ax_bias,'Bias (PSE) over repetitions (BlackRock)');
        box(ax_bias,'off');
        grid(ax_bias,'on');

        % Threshold over repetitions
        ax_thr = nexttile(tlo,2);
        hold(ax_thr, 'on');
        for rep = 1:n_repeats
            plot(ax_thr, (rep)*min_trials_per_stim, threshold_history(rep), 'o-', 'Color', cmap(rep,:), ...
                'MarkerFaceColor', cmap(rep,:), 'MarkerEdgeColor', cmap(rep,:), ...
                'LineWidth', 1.5, 'MarkerSize',7);
        end
        plot(ax_thr, (1:n_repeats)*min_trials_per_stim, threshold_history, '-', 'Color', [0.7 0 0], 'LineWidth', 2, 'HandleVisibility','off');
        hold(ax_thr, 'off');
        xlabel(ax_thr,'Repetition group (# trials per stim)');
        ylabel(ax_thr,'Threshold');
        title(ax_thr,'Threshold over repetitions (BlackRock)');
        box(ax_thr,'off');
        grid(ax_thr,'on');

    else
        disp('Not enough trials per stimulus condition to compute evolution of PSE/threshold.');
    end

   

    % Optional: uncomment to plot requested vs actual delay (calibration check)
    %{
    figure
    scatter(stimulus, stimulus_real, 'or');
    axis equal;
    hold on
    plot([0:200], [0:200], '--k');
    xlabel('Requested delay');
    ylabel('Actual delay');
    xlim([-0.1, max(stimulus_real)+30]);
    ylim([-0.1, max(stimulus_real)+30]);
    title('InLab Trainer');
    keyboard
    %}

else
    % File missing: run the BlackRock parser on raw data first, then re-run this script
    disp('No data found, please parse the raw data first.')
end

%keyboard