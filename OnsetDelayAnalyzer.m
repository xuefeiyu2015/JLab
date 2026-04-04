% OnsetDelayAnalyzer.m
% -------------------------------------------------------------------------
% Analyzes the timing accuracy of stimulus onset delivery by comparing
% requested vs. actual time delays for each target position condition.
% Produces a summary table (one row per position, one column per trial)
% and a heatmap of mean differences.
% -------------------------------------------------------------------------
% Apr 3rd, 2026 by Xuefei Yu
% -------------------------------------------------------------------------

close all;
clear;


%% -------------------------------------------------------------------------
%% 1. CONFIGURE DATA PATH
%% -------------------------------------------------------------------------
monkey = 'Monkey Porthos';
main_path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
data_date = '2026-04-03';  % Session date in yyyy-mm-dd
task_type = 'in_lab/timedelay';
folder = 'export_data';

analyze_task = 'time_delay_experiment';

data_mat  = sprintf('Blackrock_%s.mat', data_date);
data_path = fullfile(main_path, monkey, task_type, folder, data_date, data_mat);

%% -------------------------------------------------------------------------
%% 2. LOAD AND FILTER TRIALS
%% -------------------------------------------------------------------------
if exist(data_path, 'file')
    data    = load(data_path);
    expdata = data.trials;

    complete_saved = [expdata.Save_complete] == 1;
    task_sel       = contains(string({expdata.Task}), analyze_task);
    trial_sel      = ~isnan([expdata.Choose_target]);
    selected_data  = complete_saved & task_sel & trial_sel;
    task_data      = expdata(selected_data);

    %% ---------------------------------------------------------------------
    %% 3. EXTRACT STIMULUS AND POSITION VARIABLES
    %% ---------------------------------------------------------------------
    stimulus      = [task_data.Requested_target_2_time_offset];           % Requested delay (ms)
    stimulus_real = ([task_data.Target_2_presented] - [task_data.Target_1_presented])*1000;  % Actual delay (ms)

    target1_position = vertcat(task_data.Target_1_position);
    target2_position = vertcat(task_data.Target_2_position);
   % target_position  = [target1_position, target2_position];
     target_position  = target1_position;
    % Per-trial difference: actual − requested (ms)
    stim_diff = (stimulus_real - stimulus) ;

    A= [target_position,stim_diff'];

    %% ---------------------------------------------------------------------
    %% 4. SUMMARY STATS PER POSITION CONDITION
    %% ---------------------------------------------------------------------
    unique_positions = unique(target_position, 'rows');
    n_positions      = size(unique_positions, 1);

    unique_t1    = unique(unique_positions(:, 1));
    unique_t2    = unique(unique_positions(:, 2));
    heatmap_data = NaN(length(unique_t1), length(unique_t2));

    fprintf('\n--- Stimulus vs Stimulus_real Differences by Target Position ---\n');
    fprintf('%-20s %-10s %-12s %-12s\n', 'Position', 'N_Trials', 'Mean_Diff', 'Std_Diff');
    fprintf('%s\n', repmat('-', 1, 54));

    for i = 1:n_positions
        pos    = unique_positions(i, :);
        idx    = target_position(:,1) == pos(1) & target_position(:,2) == pos(2);
        diffs  = stim_diff(idx);
        n_tri  = sum(idx);
        m_diff = mean(diffs);
        s_diff = std(diffs);

        fprintf('(%.0f,%.0f)%*s%-10d %-12.3f %-12.3f\n', ...
                pos(1), pos(2), 2, '', n_tri, m_diff, s_diff);

        row_idx = find(unique_t1 == pos(1));
        col_idx = find(unique_t2 == pos(2));
        heatmap_data(row_idx, col_idx) = m_diff;
    end

    %% ---------------------------------------------------------------------
    %% 5. HEATMAP: mean difference per position
    %% ---------------------------------------------------------------------
    figure;
    imagesc(heatmap_data');
    colorbar;
    colormap('jet');
    xlabel('Target 1 X');
    ylabel('Target 1 Y');
    title('Mean (Stimulus\_real - Stimulus) [ms] by Target Position');
    set(gca, 'YTick', 1:length(unique_t2), 'YTickLabel', arrayfun(@num2str, unique_t2, 'UniformOutput', false));
    set(gca, 'XTick', 1:length(unique_t1), 'XTickLabel', arrayfun(@num2str, unique_t1, 'UniformOutput', false));
    axis square;

    %% ---------------------------------------------------------------------
    %% 6. TABLE: rows = positions, columns = individual trials (NaN-padded)
    %% ---------------------------------------------------------------------
    n_trials_per_pos = arrayfun(@(i) sum( ...
        target_position(:,1) == unique_positions(i,1) & ...
        target_position(:,2) == unique_positions(i,2)), 1:n_positions);
    max_trials = max(n_trials_per_pos);

    diff_matrix = NaN(n_positions, max_trials);
    for i = 1:n_positions
        pos  = unique_positions(i, :);
        idx  = find(target_position(:,1) == pos(1) & target_position(:,2) == pos(2));
        diff_matrix(i, 1:length(idx)) = stim_diff(idx);
    end

    pos_labels = arrayfun(@(i) sprintf('(%.0f,%.0f)',unique_positions(i,1), unique_positions(i,2)), ...                  
                    (1:n_positions)', 'UniformOutput', false);
    trial_cols  = arrayfun(@(k) sprintf('Trial_%d', k), 1:max_trials, 'UniformOutput', false);
    trial_table = array2table(diff_matrix, 'RowNames', pos_labels, 'VariableNames', trial_cols);
    disp(trial_table);

else
    disp('No data found, please parse the raw data first.')
end
