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


%% -------------------------------------------------------------------------
%% 3. PREPROCESSING CONFIGURATION -- one struct per block
%% -------------------------------------------------------------------------
% Every preprocessing block has .Plot and .ReCompute; the blocks that read an
% exported file also have .KeepFullFile. The remaining fields are that block's own
% parameters. Omit a field (or set it []) and the wrapped function's own
% documented default applies -- no default is invented here or in the wrappers.
% NOTE: a cell value needs DOUBLE braces inside struct(), e.g.
% 'TaskCal', {{'fixation'}} -- a single brace builds a struct ARRAY.
%
% .ReCompute = false loads that product from <main_path>/AnalysisCache instead of
% recomputing it (the plots still redraw from the cached data), and -- the point
% of the cascade -- also stops the exported file behind it being read at all.
% .KeepFullFile = true forces the export to be read regardless and returns it in
% the block's second output, for further analysis afterwards; false frees it as
% soon as the block returns. The one rule lives in needFullFile.m.
% The eye calibration is cached as a readable text file; the others as .mat/.csv.

cfg = struct();

cfg.Behavior = struct( ...      % reads no export of its own -- comments only
    'Plot',         true, ...   % visualize the behavior summary
    'ReCompute',    false);

% Calibration candidates in priority order: a session with a dedicated fixation
% block calibrates off it, otherwise off whichever saccade task it ran.
cfg.Eye = struct( ...
    'Plot',         true, ...   % plot eye traces after calibration
    'ReCompute',    false, ...
    'KeepFullFile', false, ...  % true also returns the uncalibrated uV traces
    'TaskCal',      {{'fixation', 'visual_saccade', 'memory_saccade'}}, ...
    'HoldWinMs',    [100 300], ...
    'EyeChans',     [1 2], ...
    'CalSessions',  [], ...
    'NCalTrials',   []);

cfg.Photodiode = struct( ...
    'Plot',             true, ...   % photodiode timing QC figures
    'PlotN',            50, ...
    'ReCompute',        false, ...
    'KeepFullFile',     false, ...  % true also returns the photodiode traces
    'BaselineWindow',   [-0.2 -0.02], ...
    'SearchWindow',     [-0.05 0.3], ...
    'OffsetSearchSpan', 2, ...
    'PlotWindow',       [-0.3 0.5], ...
    'OffsetPlotWindow', [-0.5 0.3], ...
    'NWorst',           20, ...
    'NSD',              3, ...
    'NContig',          5, ...
    'ChannelMap',       [1 2 3], ...
    'Polarity',         'auto', ...
    'SuccessOutcomes',  {{'correct', 'wrong'}});

% Plot is the one flag here that also drives loading: the navigator's waveform
% and PCA panels draw individual waveforms, and the cache keeps only each unit's
% per-task mean waveform and PCA result, so an open GUI reads the waveform export
% even on a cached run. NSample bounds what that costs to draw -- it is purely a
% drawing cap: the rates, SNR, width, P2V, the mean traces and the PCA all run on
% every spike, so no reported number moves with it.
cfg.Spike = struct( ...
    'Plot',         true, ...  % turn on the spike navigator interface
    'ReCompute',    false, ...
    'NSample',      1000, ...  % waveforms/task/unit drawn in the panel; NaN = all
    'KeepFullFile', false);     % true also returns the spike waveforms (the
                                % largest export); the raster always comes back

cfg.RT = struct( ...            % reads no export -- consumes the calibrated eyes
    'Plot',          true, ...  % saccade detection + saccade-map figures
    'PlotN',         50, ...
    'ErrorCheck',    true, ...
    'ReCompute',     false, ...
    'EndpointStyle', 'kde', ...
    'PeakVelStyle',  'surface');

cfg.Screen = struct( ...        % were hardcoded inside ScreenSession
    'RemoveTaskLessThanTrials', 3, ...   % drop tasks with fewer successful trials
    'RemoveAvgFRLessThan',      1);      % Hz; drop units firing slower than this

% The task router is analysis, not preprocessing, so its flags stay standalone.
TaskRouter  = true;   % turn on the task router for individual task based analysis
plotFlag    = 1;      % turn the per-protocol plots on
ReComputeRF = false;  % RFPlot's per-task cache


%% -------------------------------------------------------------------------
%% 4. RESOLVE THE EXPORTED FILES  (paths only -- nothing is read yet)
%% -------------------------------------------------------------------------
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



%% -------------------------------------------------------------------------
%% 5. PREPROCESSING -- each block reads only the file it needs
%% -------------------------------------------------------------------------
% Every block below gets a PATH plus its config struct and decides for itself
% whether the exported file has to be read: only when KeepFullFile asked for it,
% when that block recomputes, or when the cached product it would otherwise
% reuse is missing. Otherwise it hands [] to the analyze function, which takes
% its own cache branch and never looks at it, so the export stays unread. The
% trials CSV is the one eager load -- every block needs it.
%
% The trailing output of each block is the exported file it read, or [] when
% KeepFullFile is false, so those arrays only stay in memory when asked for.

if isempty(comments_path)
    error('No parsed trials data found. Please parse the data using the loader first.');
end
comments_data = readtable(comments_path);

BehaviorSummary = PrepareBehavior(comments_data, cfg.Behavior, main_path);

% Eye calibration and RT are one dependency chain, so they sit together: RT is
% the only consumer of calibrated traces, and EyeCalibration has to touch the
% whole array even when its coefficients come from cache. Asking up front
% whether RT is going to recompute is what lets the eye export go unread
% otherwise. Running RT here rather than at the end also means the calibrated
% copy is finished with before the photodiode and waveform loads below, instead
% of staying resident across them.
rtWillCompute = needFullFile(cfg.RT, main_path, 'RT', {'.mat', '.csv'});
[caled_eyes, eye_data] = PrepareEyes(eye_path, comments_data, cfg.Eye, ...
                                     main_path, rtWillCompute);

%Add RT to saccade tasks.
RT = PrepareRT(caled_eyes, comments_data, cfg.RT, main_path);

[PDTiming, photodiode_data] = PreparePhotodiode(photodiode_path, comments_data, ...
                                                cfg.Photodiode, main_path);

[SpikeSummary, spike_data, spikewaveform_data] = PrepareSpikes(spike_path, ...
                              waveform_path, comments_data, cfg.Spike, main_path);

%Screen the tasks and spikes according to the behavior and spike check.
[excludeTasks, excludeSpikes] = ScreenSession(BehaviorSummary, SpikeSummary, cfg.Screen);

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
%No need the raw waveform for now, may be extend later
%Reserved for future, for configuration for batch analysis. Named protocol_cfg
%so it does not collide with the preprocessing config struct above.
protocol_cfg = [];

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
           % mse_result = FunctionSubtypeIdentify(data_task,protocol_cfg,plotFlag);
            mse_result = RFPlot(data_task,protocol_cfg,plotFlag,main_path,ReComputeRF);
        case 'time_delay_experiment'
            tde_result = TimeDiscriminationBehavior(data_task,protocol_cfg,plotFlag);
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
% findExportFile now lives in ToolsAndFunctions/AnalyzeTools/findExportFile.m (on
% the path via genpath), so the path resolution above resolves to that file and a
% batch driver can use the same resolver.

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

