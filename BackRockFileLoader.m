% Driver script to load, parse and export blackrock behavior data.
% by Xuefei Yu 03-02-2026
% Currently only for behavior data, --03-02-2026
% Change the export data from .mat into txt and csv file
% Change the loader into automatically looking for .nev and .ns2 files
% Update the comments, --June 18th, 2026
% Add batch loading: Folder can be a list of dates, or empty to process all
% YYYY-MM-DD folders; each is loaded/parsed/exported in turn, --June 19th, 2026
% Add batch run and export, now  it supports loading and exporting multiple
% files -- June 19th, 2026
% Refactor: loading + parsing now live in the BlackrockLoader class
% (ToolsAndFunctions/LoadingTools). This script only configures, loops, and
% exports. -- June 26th, 2026

clear
close all

%% Check if the path is setup ready
if isempty(which('openNEV'))
   addpath('/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Program_Matlab_Local/JLab/ToolsAndFunctions/NPMK');
end
if isempty(which('BlackrockLoader'))
   addpath('/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Program_Matlab_Local/JLab/ToolsAndFunctions/LoadingTools');
end

%% Set up data path (built once for the whole batch)
% Per-run inputs: set the basic path once, supply the monkey name, and choose
% which year-month-date folder(s) to process. The loader auto-detects .nev/.ns2.
Basic_Path  = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
Monkey = 'test';        % bare monkey name; folder is "Monkey <name>"
Location = 'in_lab';       % editable constant
DataType = 'raw_data';     % editable constant
OutputFolder = 'export_data';   % where parsed data is written

MonkeyFolder = ['Monkey ' Monkey];
DataTypePath = fullfile(Basic_Path,MonkeyFolder,Location,DataType);

%If you have your own path to the 'Year-Month-Date' folder, replace the
%DataTypePath here.

ExportPath = fullfile(Basic_Path,MonkeyFolder,Location,OutputFolder);
%If you have your own export path, replace it here


% Year-month-date folder(s) to process:
%   '2026-06-17'                   a single folder
%   {'2026-06-17','2026-06-18'}    several folders, loaded in order
%   {}  (or '')                    every YYYY-MM-DD folder under DataTypePath
Folder = {'2026-06-24'};

%% Build the loader (config-property class)
% Override any schema/flag property through name/value pairs, e.g.
%   BlackrockLoader('LoadOnlineSpikeData', false)
% See ToolsAndFunctions/LoadingTools/BlackrockLoader.m for all properties:
% the file-role prefixes (NSP/HUB), the load flags, and the parsing schema
% (trial/experiment templates + the comment-string event maps).
loader = BlackrockLoader('LoadAnalogData', true, 'LoadOnlineSpikeData', true);

FolderList = BlackrockLoader.resolveFolders(Folder, DataTypePath);

%% Batch process each date folder
% load -> parse -> export, once per folder in FolderList.
% A failure in one folder is caught and reported; the batch keeps going.
results = struct('folder', {}, 'status', {}, 'message', {}, ...
                 'comments_source', {}, 'analog', {}, 'spike', {});
for fi = 1:numel(FolderList)
    CurrentFolder = FolderList{fi};
    fprintf('\n===== [%d/%d] %s =====\n', fi, numel(FolderList), CurrentFolder);

    % --- per-folder load status (defined before the try so the catch can use
    %     them even if loadSession throws on missing comments) ---
    comments_source = '';
    analog_status   = 'not requested';
    spike_status    = 'not requested';
    SpikeTime       = [];                  % spike times in seconds (workspace only)

  try
    % --- per-folder paths and output filenames ---
    DataFolder = fullfile(DataTypePath, CurrentFolder);
    OutputPath = fullfile(ExportPath, CurrentFolder);
    OutputFileName_exp    = 'Blackrock_'+string(CurrentFolder)+'_expmeta_matlab.txt';
    OutputFileName_trials = 'Blackrock_'+string(CurrentFolder)+'_trials_matlab.csv';

    % --- Schema-checked, role-aware load (comments / spikes / analog) ---
    % Throws only when comments cannot be obtained, so a missing comments source
    % fails just this folder. Spike/analog failures are recorded and skipped.
    S = loader.loadSession(DataFolder);

    comments_source = S.comments_source;
    analog_status   = S.analog_status;
    spike_status    = S.spike_status;
    SpikeTime       = S.SpikeTimeSec;
    if S.LoadAnalogData
        nsxdata          = S.nsxdata;
        nsx_samplingrate = S.nsx_samplingrate;
        nsx_abs_time     = S.nsx_abs_time;
    end

    % --- Show the resolved files before processing/export ---
    fprintf('\n--- Resolved Blackrock data products ---\n');
    fprintf('  Comments: %s\n', comments_source);
    fprintf('  Analog:   %s\n', analog_status);
    fprintf('  Spikes:   %s\n', spike_status);
    fprintf('----------------------------------------\n');

    % --- Parse the comment strings into trials + experiment ---
    [trials, experiment] = loader.parseEvents(S.Events, S.EventTime);

    %% Export the parsed data into folders
    % Set up export path
    if ~exist(OutputPath, 'dir')
        mkdir(OutputPath);
    end

    % Save experiment meta as .txt
    % One section per session, separated by a "Session N:" header and a blank line.
    fid = fopen(fullfile(OutputPath, OutputFileName_exp), 'w');
    for s = 1:numel(experiment)
        fprintf(fid, 'Session %d:\n', s);
        fields = fieldnames(experiment(s));
        for i = 1:numel(fields)
            val = experiment(s).(fields{i});
            if isnumeric(val)
                fprintf(fid, '%s: %s\n', fields{i}, mat2str(val));
            else
                fprintf(fid, '%s: %s\n', fields{i}, string(val));
            end
        end
        fprintf(fid, '\n');
    end
    fclose(fid);

    fprintf('File:%s Experiment meta has been parsed into %s\n', comments_source, OutputFileName_exp);

    % Save trials as .csv
    % Flatten array/vector fields (e.g. positions) into separate columns
    trials_flat = rmfield(trials, {'undefined', 'duplicates'});
    trials_table = struct2table(trials_flat);

    % Explicit 0-based sequential row index (pandas-friendly: read_csv(index_col='index')).
    % Kept separate from Trial_number, which holds the real (resetting) trial number.
    trials_table = addvars(trials_table, (0:height(trials_table)-1)', ...
        'Before', 1, 'NewVariableNames', 'index');

    % Convert any 2-column vector fields (e.g. positions) into _x/_y columns
    for col = trials_table.Properties.VariableNames
        c = col{1};
        if isnumeric(trials_table.(c)) && size(trials_table.(c), 2) == 2
            trials_table.([c '_x']) = trials_table.(c)(:,1);
            trials_table.([c '_y']) = trials_table.(c)(:,2);
            trials_table.(c) = [];
        end
    end

    writetable(trials_table, fullfile(OutputPath, OutputFileName_trials));

    fprintf('File:%s Trials Data has been parsed into %s\n', comments_source, OutputFileName_trials);

    results(end+1) = struct('folder', CurrentFolder, 'status', 'ok', 'message', '', ...
        'comments_source', comments_source, 'analog', analog_status, 'spike', spike_status);

  catch ME
    warning('Skipping %s: %s', CurrentFolder, ME.message);
    results(end+1) = struct('folder', CurrentFolder, 'status', 'failed', 'message', ME.message, ...
        'comments_source', comments_source, 'analog', analog_status, 'spike', spike_status);
  end %end try
end %end per-folder loop


%% Batch summary
% One line per folder, with the per-product load status (comments / analog /
% spike) so partial failures are visible without rerunning.
fprintf('\n===== Batch summary =====\n');
for k = 1:numel(results)
    if isempty(results(k).message)
        fprintf('  [%-6s] %s | comments: %s | analog: %s | spike: %s\n', ...
            results(k).status, results(k).folder, results(k).comments_source, ...
            results(k).analog, results(k).spike);
    else
        fprintf('  [%-6s] %s - %s | comments: %s | analog: %s | spike: %s\n', ...
            results(k).status, results(k).folder, results(k).message, ...
            results(k).comments_source, results(k).analog, results(k).spike);
    end
end


function compare_fields(s1,s2)
% Function to debug
%This function is to compare the fields between two structures
   fields1 = fieldnames(s1);
   fields2 = fieldnames(s2);

   diff1 = setdiff(fields1, fields2);
   diff2 = setdiff(fields2, fields1);

   disp('s1 has but s2 does not:')
   disp(diff1)

   disp('s2 has but s1 does not:')
   disp(diff2)
end
