% Script to analyze parsed BlackRock Data
% Visualize psychometric function
% Mar 4th, 2026 by Xuefei Yu
close all;
clear;

%mat data path
monkey = 'Monkey Porthos';
main_path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
data_date = '2026-03-05'; % in yyyy-mm-dd
task_type = 'in_lab/timedelay';
folder = 'export_data';

analyze_task = 'time_delay_experiment'; %Define the task wanting to analyze here


data_mat = sprintf('Blackrock_%s.mat', data_date);
data_path = fullfile(main_path,monkey,task_type,folder,data_date,data_mat);

if exist(data_path, 'file')
    %% Load the data if exist
    data = load(data_path);
    %mata_data = data.experiment; %Stores  the meta data for the session.
    expdata = data.trials; %Structure array for all trials

   % Select completely saved data;
    complete_saved = [expdata.Save_complete]==1; % flag for completed saved data  
    % Select trials for time delay task  
    task_sel = contains({expdata.Task},analyze_task);
    % Select trials for choices
    trial_sel = ~isnan([expdata.Choose_target]);

    selected_data = complete_saved & task_sel & trial_sel;
    
    
    task_data = expdata(selected_data); % Filtered data for the selected task

    TotalTrials = sum(selected_data);
    
    %% Construct matrix for psychometric function visualization
    stimulus = [task_data.Requested_target_2_time_offset]; %Time delay
    stimulus_real = ([task_data.Target_2_presented]-[task_data.Target_1_presented])*1000;%into ms
    direction = [task_data.Stimulus_direction]; %Left first or right first
    choice_response = [task_data.Choose_leftright]==1; %choose left 0 or right 1

    Psymatrix = [stimulus',direction',choice_response'];
   
    [pse, threshold] = VisPsychometricFunction(Psymatrix);
    %{
    figure
    scatter(stimulus,stimulus_real,'or');
    axis equal;
    hold on
    plot([0:200],[0:200],'--k');
    xlabel('Requested delay');
    ylabel('Actual delay');
    xlim([-0.1,max(stimulus_real)+30]);
    ylim([-0.1,max(stimulus_real)+30]);
    title('InLab Trainer');
    keyboard
    %}

   


%keyboard







else
    disp('No data found, please parse the raw data first.')
end

%keyboard