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

%% Check if the path is setup ready
%% Step 1 - add JLab's own code. The repo root is added non-recursively (for the
% top-level scripts) and only the ToolsAndFunctions tree is genpath'd (for the
% BlackrockLoader class + analyze tools). We deliberately do NOT genpath the repo
% root, so dot-folders at the root (.git, .claude, ...) never end up on the path.
JLabRoot = fileparts(mfilename('fullpath'));
addpath(JLabRoot);
addpath(genpath(fullfile(JLabRoot, 'ToolsAndFunctions')));
% Per-task analysis protocols: add Protocol/ and every subfolder (e.g.
% Protocol/VisualSaccadeTask/RFPlot.m), but only when the tree is not already on
% the path, so re-running the script does not keep re-adding it.
protocolRoot = fullfile(JLabRoot, 'Protocol');
if isfolder(protocolRoot) && ~contains([pathsep path pathsep], [pathsep protocolRoot pathsep])
    addpath(genpath(protocolRoot));
end


%% -------------------------------------------------------------------------
%% 2. CONFIGURE DATA PATH
%% -------------------------------------------------------------------------
% Set paths and identifiers for the .mat file to load. The file is
% expected at: main_path/monkey/task_type/folder/data_date/Blackrock_*.mat

Basic_Path  = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
%Monkey = 'test';        % bare monkey name; folder is "Monkey <name>"
Monkey = 'Athos'; 
Location = 'in_lab';       % editable constant
DataType = 'export_data';     % editable constant

%Folder = '2026-07-17';
Folder = '2026-07-24';


%Toddles to turn quality check plots on
%
PlotBehaviorCheck= true; % for visualizing behavior summary
PlotCalibratedEyes = true;% for plotting eye trace after calibration
PlotPhotodiodeTiming = true; % for plotting photodiode timing QC
PlotSpikeCheck = false; %turn on the spike navigator interface
PlotSaccadeCheck = true; %turn on the plots for saccade detection and saccade related visualizations
TaskRouter = true; %turn on the task rounter for individual task based analysis
%}
%{
PlotBehaviorCheck= false; % for visualizing behavior summary
PlotCalibratedEyes = false;% for plotting eye trace after calibration
PlotPhotodiodeTiming = true; % for plotting photodiode timing QC
PlotSpikeCheck = false; %turn on the spike navigator interface
PlotSaccadeCheck = false; %turn on the plots for saccade detection and saccade related visualizations
TaskRouter = true; %turn on the task rounter for individual task based analysis
%}
% ReCompute flags: default true recomputes and refreshes the AnalysisCache
% (<main_path>/AnalysisCache). Set one false to load that product from cache
% instead of recomputing (the plots still redraw from the cached data). The eye
% calibration is cached as a readable text file; the others as .mat.

%
ReComputeBehavior = false;
ReComputeCal      = true;
ReComputePhotodiode = true;
ReComputeSpike    = false;
ReComputeRT       = true;
ReComputeRF       = false;
%}
%{
ReComputeBehavior = true;
ReComputeCal      = true;
ReComputePhotodiode = true;
ReComputeSpike    = true;
ReComputeRT       = true;
ReComputeRF       = true;
%}

%Check all the exported files in the folder

main_path = fullfile(Basic_Path, sprintf('Monkey %s', Monkey), Location, DataType, Folder);
all_files = dir(main_path);
all_files = {all_files(~[all_files.isdir]).name};

%Search for comments file
comments_path = findExportFile(all_files, main_path, 'trials_matlab');

%Search for the Eye data file. Exports before the eye/photodiode channel split
%named this '<stem>_analog_matlab.mat' (all channels of the ns2); it is now
%'<stem>_eye_matlab.mat' (EyeChannels only). Fall back to the old name so
%already-exported sessions keep working without re-running the loader.
eye_path      = findExportFile(all_files, main_path, 'eye_matlab');
if isempty(eye_path)
    eye_path  = findExportFile(all_files, main_path, 'analog_matlab');
end

%Search for photodiode file
photodiode_path = findExportFile(all_files, main_path, 'photodiode_matlab');

%Search for online spike file. 'spikes' alone would also catch the waveform
%file, so it has to be excluded explicitly.
spike_path    = findExportFile(all_files, main_path, 'spikes', 'spikes_waveform');

%Search for spike waveform file
waveform_path = findExportFile(all_files, main_path, 'spikes_waveform');





if ~isempty(comments_path)
    comments_data = readtable(comments_path);
    BehaviorSummary = behaviorCheck(comments_data, PlotBehaviorCheck, main_path, ReComputeBehavior);
   
else
    
    error('No parsed trials data found. Please parse the data using the loader first.');
    
end


if ~isempty(eye_path)
    tmp = load(eye_path);
    % new exports store 'eye'; older ones stored 'analog' (see above)
    if isfield(tmp, 'eye')
        eye_data = tmp.eye;
    else
        eye_data = tmp.analog;
    end

    %Eye calibration 
    disp('Start eye calibration');

    % Candidates in priority order: a session with a dedicated fixation block
    % calibrates off it, otherwise off whichever saccade task it ran.
    task_cal  = {'fixation', 'visual_saccade', 'memory_saccade'};
    
    caled_eyes = EyeCalibration(comments_data,eye_data,task_cal,[],[], PlotCalibratedEyes,[],[], main_path, ReComputeCal);

    if caled_eyes.cal.applied == false
        disp('Eye calibration failed!');
        
    else
        disp('Eye calibration completed.');
        
    end


else
    disp('No parsed eye data found');
    caled_eyes.cal.applied = false;
end

if ~isempty(photodiode_path)
    tmp = load(photodiode_path);
    photodiode_data = tmp.photodiode;

    disp('Start processing photodiode timing');
    PDTiming = GetPhotodiodeTiming(photodiode_data, comments_data, PlotPhotodiodeTiming, [], main_path, ReComputePhotodiode);
    disp('Photodiode timing processing completed.');
else
    disp('No parsed photodiode data found');
    photodiode_data = [];
    PDTiming = [];
end

if ~isempty(spike_path)
    tmp = load(spike_path);
    spike_data = tmp.online_spike;

    if ~isempty(waveform_path)
        tmp = load(waveform_path);
        spikewaveform_data = tmp.online_spike_waveform;
    else
        disp('No spike waveform found');
        spikewaveform_data = [];
    end

    
    SpikeSummary = spikeCheck(spike_data, spikewaveform_data, ...
                                   comments_data, main_path, PlotSpikeCheck, ReComputeSpike );

    % Surface the loader's precomputed per-unit average waveform (uV). Rows of
    % SpikeSummary align 1:1 with spike_data.info (one row per unit, same order).
    if ~isempty(SpikeSummary) && isfield(spike_data.info, 'MeanWaveform') ...
            && ~isempty(spike_data.info.MeanWaveform)
        SpikeSummary.AverageWaveform = spike_data.info.MeanWaveform;  % nRow x nSamp (uV)
    end
    if PlotSpikeCheck
        disp('Completed spikecheck!')
    end
   
    
else
    disp('No spike data found');
    spike_data = [];
    SpikeSummary = []; 
end


%Screen the tasks and spikes according to the behavior and spike check.
[excludeTasks, excludeSpikes] = ScreenSession(BehaviorSummary, SpikeSummary);

%comments_data
%caled_eyes
%spike_data
%spike_waveform_data

%% Preprossing: Add RT to saccade tasks.
RT = CalculateRT(caled_eyes, comments_data, PlotSaccadeCheck, [], [], main_path, ReComputeRT);

if TaskRouter
%% Auto-rounting to it's respective analyze protocol

tasklist  = BehaviorSummary.Task(~ismember(BehaviorSummary.Task,excludeTasks) );

filtered_spike_data = [];
if ~isempty(spike_data)
    %Screen spike_data
    filtered_spike_data = ScreenSpikeData(spike_data, excludeSpikes);
end


% Field names must match the protocol contract: the per-task analyzers
% (RFPlot, TimeDiscriminationBehavior, ...) read the trials table as data.comments.
% extend the comments table by adding RT table.
extended_comments = extendComments(comments_data,RT,PDTiming);
data_ana = struct('comments',extended_comments,'eyes',[],'spike',filtered_spike_data);


data_extra =[]; %returned data from another task
plotFlag = 1; %Flag of whether to turn the plot on;
%No need the raw waveform for now, may be extend later
cfg = [];%Reserved for future, for configuration for batch analysis

%Now loop over tasks to rount data into their task-related protocols
for i = 1:length(tasklist)
    task = tasklist(i);
    % Screen the recording down to this task's trials before dispatch, so each
    % protocol receives data already scoped to its task.
    data_task = SetupDataForTask(data_ana, task);
    switch task
        case 'visual_saccades_experiment'
            vse_result = RFPlot(data_task,data_extra,plotFlag,main_path,ReComputeRF);
        case 'memory_saccades_experiment'
           % mse_result = FunctionSubtypeIdentify(data_task,cfg,plotFlag);
            mse_result = RFPlot(data_task,cfg,plotFlag,main_path);
        case 'time_delay_experiment'
            tde_result = TimeDiscriminationBehavior(data_task,cfg,plotFlag);
        otherwise
            fprintf('No analyze protocol for %s yet\n',task);
     
    end


end

end %End of the task rounter

% RFPlot now lives in Protocol/VisualSaccadeTask/RFPlot.m (on the path via genpath),
% so the routing call above resolves to that file.

function result = FunctionSubtypeIdentify(data,cfg,plotFlag);
    result = 1;
end

% TimeDiscriminationBehavior now lives in
% ToolsAndFunctions/AnalyzeTools/TimeDiscriminationBehavior.m (on the path via
% genpath), so the routing call at the top resolves to that file.










%% 
keyboard

%% -------------------------------------------------------------------------
%% -------------------------------------------------------------------------
function p = findExportFile(all_files, main_path, pattern, exclude)
% Resolve one exported product in main_path by a rough name match.
%
%   all_files - cellstr of file names in main_path.
%   pattern   - substring the name must contain (e.g. 'analog').
%   exclude   - (optional) substring that disqualifies a match. Needed for
%               'spikes', which would otherwise also catch 'spikes_waveform'.
%
% Returns '' when nothing matches, so callers can guard with exist().

    hit = all_files(contains(all_files, pattern));
    if nargin > 3 && ~isempty(exclude)
        hit = hit(~contains(hit, exclude));
    end

    if isempty(hit)
        p = '';
        return
    end
    if numel(hit) > 1
        error('findExportFile:Ambiguous', ...
            'Multiple files match "%s" in %s:\n  %s', ...
            pattern, main_path, strjoin(hit, '\n  '));
    end
    p = fullfile(main_path, hit{1});
end

function filtered = ScreenSpikeData(spike, exclude);

% Filter spike data
sel = ~exclude;
filtered = spike;
filtered.data = spike.data(sel,:,:);   

fields = fieldnames(spike.info);
keep_fields = {'samplingrate','Session','Trial_number','MeanWaveformUnit'};

for i = 1:numel(fields)

    field = fields{i};
    value = spike.info.(field);

    if contains(field,keep_fields)
        filtered.info.(field) = value;    

    else
        filtered.info.(field) = value(sel,:);
    end

end

end

% SetupDataForTask now lives in ToolsAndFunctions/AnalyzeTools/SetupDataForTask.m
% (on the path via genpath), so the routing call above resolves to that file.

