% Script for combinging and transform json data from cage trainers
% Feb,09,2026 by Xuefei Yu

clc; clear;

% -----------------------------
% configure
% -----------------------------

%Raw Data loading path
%from server
%{
monkey = 'Monkey Porthos';
main_path = '/Volumes/server/';
data_date = '2025-11-05'; % in yyyy-mm-dd
task_type = 'cage_training/timedelay';
%}
%from dropbox to local
monkey = 'Monkey Porthos';
main_path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data/';
data_date = '2026-04-01'; % in yyyy-mm-dd
task_type = 'cage_training/timedelay';
local_label = 'raw';

folder_path = fullfile(main_path, monkey, task_type,local_label,data_date);


%Data output path
main_output_path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
monkey_specific_path = fullfile(monkey,task_type);
output_path = fullfile(main_output_path,monkey_specific_path);
% Create output directory if it doesn't exist
if ~exist(output_path, 'dir')
    mkdir(output_path);
end

output_csv = sprintf('all_trials_%s.csv', data_date);
output_file = fullfile(output_path,output_csv);


% load all json files from the folder
files = dir(fullfile(folder_path, '*.json'));

% initiating the table
allData = table();


% -----------------------------
% load JSON files one by one
% -----------------------------
for i = 1:length(files)
    filename = files(i).name;
    filepath = fullfile(folder_path, filename);

    % read JSON file
    jsonText = fileread(filepath);
    dataStruct = jsondecode(jsonText);

    %Fill in empty value
    
     for j = 1:size(dataStruct,1)
    
  
     dataStruct(j) = structfun(@(x) fillEmptyWithNaN(x), dataStruct(j), 'UniformOutput', false);
     if j==2 
        disp('Find one duplicate trial');
     end
     
  
    % flatten into table
    T = struct2table(dataStruct(j));
    T.trial_file = filename;

    %Change the response into strings
    T.response = string(T.response);

    % insert into the main table
    
    allData = [allData; T];
     end
    
end

% -----------------------------
% save into new file
% -----------------------------
if isempty(allData)
    error('No data found, check whether the data folder exist!')
else
    writetable(allData, output_file);
    disp(['All trials has been combined into ', output_file]);
    disp(head(allData));
end





function y = fillEmptyWithNaN(x)
    if isempty(x)
        y = NaN;
    else
        y = x;
    end
    
end