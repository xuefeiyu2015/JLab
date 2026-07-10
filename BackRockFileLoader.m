% Script to open and load blackrock data
% by Xuefei Yu 03-02-2026
% Currently only for behavior data, --03-02-2026
% Change the export data from .mat into txt and csv file
% Change the loader into automatically looking for .nev and .ns2 files
% Update the comments, --June 18th, 2026
% Add batch loading: Folder can be a list of dates, or empty to process all
% YYYY-MM-DD folders; each is loaded/parsed/exported in turn, --June 19th, 2026
% Add batch run and export, now  it supports loading and exporting multiple
% files -- June 19th, 2026
% Migrate to the object-oriented BlackrockLoader: this script is now a thin
% driver that constructs one loader, then per date folder calls loadSession +
% parseEvents and writes the exports. All load/parse/templates/maps logic lives
% in ToolsAndFunctions/LoadingTools/BlackrockLoader.m -- June 27th, 2026
clear
close all

%% Check if the path is setup ready
% Step 1 - add JLab's own code. The repo root is added non-recursively (for the
% top-level scripts) and only the ToolsAndFunctions tree is genpath'd (for the
% BlackrockLoader class + analyze tools). We deliberately do NOT genpath the repo
% root, so dot-folders at the root (.git, .claude, ...) never end up on the path.
JLabRoot = fileparts(mfilename('fullpath'));
addpath(JLabRoot);
addpath(genpath(fullfile(JLabRoot, 'ToolsAndFunctions')));

% Step 2 - NPMK is a third-party dependency you supply yourself. If openNEV is
% already on the path (e.g. NPMK lives under ToolsAndFunctions/NPMK), we're done.
% Otherwise ask the user to point at their NPMK folder and add it.
if isempty(which('openNEV'))
    disp('BlackRock NPMK not found (openNEV is missing).');
    disp('Select your NPMK folder to add it (Cancel to abort).');
    npmk_dir = uigetdir('', 'Select the BlackRock NPMK folder');
    if isequal(npmk_dir, 0)
        error(['NPMK not added. Install it from ' ...
               'https://github.com/BlackrockNeurotech/NPMK and add it to the path.']);
    end
    addpath(genpath(npmk_dir));
    if isempty(which('openNEV'))
        error('openNEV still not found in: %s. Make sure you selected the NPMK root folder.', npmk_dir);
    end
end

%% Set up data path (built once for the whole batch)
% Per-run inputs: set the basic path once, supply the monkey name, and choose
% which year-month-date folder(s) to process. The loader auto-detects .nev/.ns2.
Basic_Path  = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
Monkey = 'Porthos';        % bare monkey name; folder is "Monkey <name>"
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
Folder = {'2026-06-18'};
FolderList = BlackrockLoader.resolveFolders(Folder, DataTypePath);

%% Load configuration (passed to the loader; exports reuse the buffers)
% Analog (eye) data lives in NSP-*.ns2; online spikes live in HUB-*.nev. Both
% are gated here and are soft failures inside loadSession (that product is just
% skipped, recorded in the returned status string).
LoadAnalogData      = true;
LoadOnlineSpikeData = false;
LoadOnlineSpikeWaveform   = false;   % default is false: also export per-spike waveforms (uV) to a
                               % separate *_spikes_waveform_matlab.mat (needs online spikes; memory heavy)
%AnalogIdentifier    = '*.ns2'; %default ns2
SpikePrefix         = 'HUB';   % HUB-*.nev: online spike timing

% Trial-segmentation buffers (ms). Window per trial = [Start - Pre, End + Post].
% Defaults are 500 ms; edit here to change how much is kept around each trial.
Segment_PreBuffer  = 500;   % ms kept before each trial's Start marker
Segment_PostBuffer = 500;   % ms kept after  each trial's End  marker
Segment_BinWidth   = 1;     % spike raster bin width (ms)

%% Construct the loader once (config-only / stateless)
% Override any schema/flag via name-value pairs; the parsing schema (templates +
% event maps) is filled from BlackrockLoader's static factories. To capture a
% new comment-string event, add a key in BlackrockLoader.defaultEventMaps() and
% a matching field in defaultTrialTemplate()/defaultExpTemplate().
loader = BlackrockLoader( ...
    'LoadAnalogData',      LoadAnalogData, ...
    'LoadOnlineSpikeData', LoadOnlineSpikeData, ...
    'LoadOnlineSpikeWaveform',   LoadOnlineSpikeWaveform, ...
    'SpikePrefix',         SpikePrefix);
    
    %'AnalogIdentifier',    AnalogIdentifier);

%% Batch process each date folder
% load -> parse -> export, once per folder in FolderList. A failure in one folder
% is caught and reported; the batch keeps going.
results = struct('folder', {}, 'status', {}, 'message', {});
for fi = 1:numel(FolderList)
    CurrentFolder = FolderList{fi};
    fprintf('\n===== [%d/%d] %s =====\n', fi, numel(FolderList), CurrentFolder);

  try
    % --- per-folder paths and output filenames ---
    DataFolder = fullfile(DataTypePath, CurrentFolder);
    OutputPath = fullfile(ExportPath, CurrentFolder);
    OutputFileName_exp    = 'Blackrock_'+string(CurrentFolder)+'_expmeta_matlab.txt';
    OutputFileName_trials = 'Blackrock_'+string(CurrentFolder)+'_trials_matlab.csv';

    % --- Load (schema-checked, role-aware) and parse the comment strings ---
    S = loader.loadSession(DataFolder);

    % --- (debug) inspect the RAW comments with timestamps ---
    % Pairs each comment string with its timestamp (seconds) into a table, in
    % recording order, BEFORE parsing. Useful when a task-software format change
    % is sending events into trials.undefined and you want to see the originals.

    %{
    rawComments = BlackrockLoader.commentsWithTime(S.Events, S.EventTime);
    disp(rawComments);              % print to the command window, or
    openvar('rawComments');        % open in the Variables editor to scroll/filter
    %}
    
    [trials, experiment] = loader.parseEvents(S.Events, S.EventTime);

    % --- Report the files / data products that were actually loaded ---
    fprintf('\n--- Loaded Blackrock data ---\n');
    fprintf('  Comments: %s\n', S.comments_source);
    fprintf('  Analog:   %s\n', S.analog_status);
    fprintf('  Spikes:   %s\n', S.spike_status);
    fprintf('-----------------------------\n');

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

    fprintf('File:%s Experiment meta has been parsed into %s\n', S.comments_source, OutputFileName_exp);

    % Save trials as .csv
    % Flatten array/vector fields (e.g. positions) into separate columns
    trials_flat = rmfield(trials, {'undefined', 'duplicates'});
    trials_table = struct2table(trials_flat);

    % Explicit 0-based sequential row index (pandas-friendly: read_csv(index_col='index')).
    % Kept separate from Trial_number, which holds the real (resetting) trial number.
    trials_table = addvars(trials_table, (0:height(trials_table)-1)', ...
        'Before', 1, 'NewVariableNames', 'index');

    % Split any 2-column numeric fields (positions) into _x/_y columns for CSV
    for col = trials_table.Properties.VariableNames
        c = col{1};
        if isnumeric(trials_table.(c)) && size(trials_table.(c), 2) == 2
            trials_table.([c '_x']) = trials_table.(c)(:,1);
            trials_table.([c '_y']) = trials_table.(c)(:,2);
            trials_table.(c) = [];
        end
    end

    writetable(trials_table, fullfile(OutputPath, OutputFileName_trials));

    fprintf('File:%s Trials Data has been parsed into %s\n', S.comments_source, OutputFileName_trials);

    % Segment the analog stream into trials and save as .mat (only if loaded)
    if S.LoadAnalogData
        analog = BlackrockLoader.segmentAnalog(trials, S.nsxdata, S.nsx_abs_time, ...
                     S.nsx_samplingrate, Segment_PreBuffer, Segment_PostBuffer);
        OutputFileName_analog = 'Blackrock_'+string(CurrentFolder)+'_analog_matlab.mat';
        save(fullfile(OutputPath, char(OutputFileName_analog)), 'analog');
        fprintf('File:%s Analog segmented (%d trials) into %s\n', ...
            S.comments_source, size(analog.data, 2), OutputFileName_analog);
    end

    % Rasterize online spikes into per-trial bins and save as .mat (only if loaded)
    if S.LoadOnlineSpikeData
        online_spike = BlackrockLoader.segmentSpikes(trials, S.SpikeTimeSec, S.SpikeChannel, ...
                     S.SpikeUnit, Segment_PreBuffer, Segment_PostBuffer, Segment_BinWidth);
        OutputFileName_spikes = 'Blackrock_'+string(CurrentFolder)+'_spikes_matlab.mat';
        save(fullfile(OutputPath, char(OutputFileName_spikes)), 'online_spike');
        fprintf('File:%s Spikes rasterized (%d units x %d trials) into %s\n', ...
            S.comments_source, size(online_spike.data, 1), size(online_spike.data, 2), OutputFileName_spikes);
    end

    % Per-spike waveforms: a separate, opt-in product (LoadOnlineSpikeWaveform). Saved
    % to its own .mat as -v7.3 because the dense 4-D array can exceed the 2 GB
    % per-variable cap of the default MAT format.
    if S.LoadOnlineSpikeWaveform && ~isempty(S.SpikeWaveform)
        online_spike_waveform = BlackrockLoader.segmentSpikeWaveforms(trials, ...
                     S.SpikeTimeSec, S.SpikeChannel, S.SpikeUnit, S.SpikeWaveform, ...
                     Segment_PreBuffer, Segment_PostBuffer);
        OutputFileName_wf = 'Blackrock_'+string(CurrentFolder)+'_spikes_waveform_matlab.mat';
        save(fullfile(OutputPath, char(OutputFileName_wf)), 'online_spike_waveform', '-v7.3');
        fprintf('File:%s Spike waveforms (%d samples, up to %d spk/unit-trial) into %s\n', ...
            S.comments_source, online_spike_waveform.waveform_nsamp, ...
            online_spike_waveform.info.maxSpikes, OutputFileName_wf);
    end

    results(end+1) = struct('folder', CurrentFolder, 'status', 'ok', 'message', '');

  catch ME
    warning('Skipping %s: %s', CurrentFolder, ME.message);
    results(end+1) = struct('folder', CurrentFolder, 'status', 'failed', 'message', ME.message);
  end %end try
end %end per-folder loop


%% Batch summary
fprintf('\n===== Batch summary =====\n');
for k = 1:numel(results)
    if isempty(results(k).message)
        fprintf('  [%-6s] %s\n', results(k).status, results(k).folder);
    else
        fprintf('  [%-6s] %s - %s\n', results(k).status, results(k).folder, results(k).message);
    end
end
