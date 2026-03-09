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
    Psymatrix = [stimulus', direction', choice_response'];

    % Plot psychometric curve and return point of subjective equality (PSE) and threshold
    [pse, threshold] = VisPsychometricFunction(Psymatrix);

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