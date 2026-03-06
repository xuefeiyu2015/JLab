% Script for analysis for data from cage trainers
% Visualizing psychometric function 
% Feb,09,2026 by Xuefei Yu
close all;
clear;

%csv data path
monkey = 'Monkey Porthos';
main_path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
data_date = '2026-02-25'; % in yyyy-mm-dd
task_type = 'cage_training/timedelay';

data_csv = sprintf('all_trials_%s.csv', data_date);
data_path = fullfile(main_path,monkey,task_type,data_csv);


if exist(data_path, 'file')
    %% Load the data if exist
    data = readtable(data_path); % Load the data into a table
    % Process the data for visualization
    % Assuming the data has columns 'stimulus' and 'response'
    stimulus = data.dr_InitialTargetDuration; %Temporal delay absolute value
    direction = data.direction; %left first:0 or right first:1
    direction(direction==0) = -1;%change to left first: -1, right first 1x
    

%{
    %% Check the acutal time delay
    stimulus_real = data.dm_Target1ToTarget2;
    figure
    scatter(stimulus,stimulus_real,'or');
    axis equal;
    hold on
    plot(stimulus,stimulus,'--k');
    xlabel('Requested delay');
    ylabel('Actual delay');
    xlim([-0.1,max(stimulus_real)+30]);
    ylim([-0.1,max(stimulus_real)+30]);
    title('Cage Trainer');
    keyboard
%}

    %% For Psychometric function
    response = strcmp(data.response,'right'); %left or right
    psymat = [stimulus,direction,response];

    [pse,threshold] = VisPsychometricFunction(psymat);


else
    disp('No data found, please transform data first.')
end



