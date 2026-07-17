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
% driver that constructs one loader, then per date folder calls
% loader.processFolder (load -> parseEvents -> parseAnalog -> parseSpikes ->
% prepareExport -> export). All load/parse/prepare/export/templates/maps logic
% lives in ToolsAndFunctions/LoadingTools/BlackrockLoader.m -- June 27th, 2026
clear
close all

%% Check if the path is setup ready
%% Step 1 - add JLab's own code. The repo root is added non-recursively (for the
% top-level scripts) and only the ToolsAndFunctions tree is genpath'd (for the
% BlackrockLoader class + analyze tools). We deliberately do NOT genpath the repo
% root, so dot-folders at the root (.git, .claude, ...) never end up on the path.
JLabRoot = fileparts(mfilename('fullpath'));
addpath(JLabRoot);
addpath(genpath(fullfile(JLabRoot, 'ToolsAndFunctions')));

%% Step 2 - NPMK is a third-party dependency you supply yourself. If openNEV is
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
Folder = {'2026-07-15'};
FolderList = BlackrockLoader.resolveFolders(Folder, DataTypePath);

%% Load configuration (passed to the loader; exports reuse the buffers)
% Analog (eye) data lives in NSP-*.ns2; online spikes live in HUB-*.nev. Both
% are gated here and are soft failures inside loadSession (that product is just
% skipped, recorded in the returned status string).
LoadAnalogData      = true;
LoadOnlineSpikeData = true;  %default is false for online spikes
LoadOnlineSpikeWaveform   = true;   % default is false: also export per-spike waveforms (uV) to a
                               % separate *_spikes_waveform_matlab.mat (needs online spikes; memory heavy)
%IncludeUnsorted = false;       % default false: drop unit 0 (unsorted) + 255 (noise)
                               % spikes; set true to keep them
%AnalogIdentifier    = '*.ns2'; %default ns2
SpikePrefix         = 'HUB';   % default HUB-*.nev: online spike timing

% Trial-segmentation buffers (ms). Window per trial = [Start - Pre, End + Post].
% Defaults are 500 ms; edit here to change how much is kept around each trial.
Segment_PreBuffer  = 500;   % ms kept before each trial's Start marker
Segment_PostBuffer = 500;   % ms kept after  each trial's End  marker
Segment_BinWidth   = 1;     % spike raster bin width (ms)

%% Construct the loader once (config now; per-folder state is reset each load)
% Override any schema/flag via name-value pairs; the parsing schema (templates +
% event maps) is filled from BlackrockLoader's static factories. To capture a
% new comment-string event, add a key in BlackrockLoader.defaultEventMaps() and
% a matching field in defaultTrialTemplate()/defaultExpTemplate().
loader = BlackrockLoader( ...
    'LoadAnalogData',      LoadAnalogData, ...
    'LoadOnlineSpikeData', LoadOnlineSpikeData, ...
    'LoadOnlineSpikeWaveform',   LoadOnlineSpikeWaveform, ...
    'SpikePrefix',         SpikePrefix, ...
    'Segment_PreBuffer',   Segment_PreBuffer, ...
    'Segment_PostBuffer',  Segment_PostBuffer, ...
    'Segment_BinWidth',    Segment_BinWidth);

    %'AnalogIdentifier',    AnalogIdentifier);

%% Batch process each date folder
% load -> parse -> export, once per folder in FolderList. A failure in one folder
% is caught and reported; the batch keeps going.
results = struct('folder', {}, 'status', {}, 'message', {});
for fi = 1:numel(FolderList)
    CurrentFolder = FolderList{fi};
    fprintf('\n===== [%d/%d] %s =====\n', fi, numel(FolderList), CurrentFolder);

  try
    % --- per-folder paths and output filename stem ---
    DataFolder = fullfile(DataTypePath, CurrentFolder);
    OutputPath = fullfile(ExportPath, CurrentFolder);
    BaseName   = char("Blackrock_" + string(CurrentFolder));

    % --- (debug) inspect the RAW comments with timestamps ---
    % Load, then pair each comment string with its timestamp (seconds) into a
    % table, in recording order, BEFORE parsing. Useful when a task-software
    % format change is sending events into trials.undefined.

    %{
    loader.load(DataFolder);
    rawComments = BlackrockLoader.commentsWithTime(loader.Loaded.Events, loader.Loaded.EventTime);

    disp(rawComments);              % print to the command window, or
    %openvar('rawComments');        % open in the Variables editor to scroll/filter
    keyboard
    %}

    % --- Run the whole pipeline for this folder ---
    % load -> parseEvents -> parseAnalog -> parseSpikes -> prepareExport -> export.
    % All loading/parsing/preparation/writing lives in the class; each step's
    % result is stored on the loader (loader.Loaded/Trials/Experiment/Analog/
    % Spike/SpikeWaveformData/Export) if you want to inspect it afterwards.


    loader.processFolder(DataFolder, OutputPath, BaseName);

    %--- If you want to check raw files one by one--
   
    %{
    C = loader.loadComments(DataFolder); %loaded raw comments
    A = loader.loadAnalog(DataFolder); %loaded raw analog
    channels,Optional1, "*.ns2" or "*.ns4","*.ns6",Optional2, preFix:
    "HUB",'NSP',etc
    %A = loader.loadAnalog(DataFolder,'*.ns6'); 
    S = loader.loadSpikes(DataFolder);%load raw online spikes
    %}

    %---If you want to run the whole process step by step--
    %{
    loader.load(DataFolder);
    loader.parseEvents();
    loader.parseAnalog();
    loader.parseSpikes();
    loader.prepareExport();
    loader.export(OutputPath, BaseName);
    %}
    
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
