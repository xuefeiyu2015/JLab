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


%% -------------------------------------------------------------------------
%% 2. CONFIGURE DATA PATH
%% -------------------------------------------------------------------------
% Set paths and identifiers for the .mat file to load. The file is
% expected at: main_path/monkey/task_type/folder/data_date/Blackrock_*.mat

Basic_Path  = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
Monkey = 'test';        % bare monkey name; folder is "Monkey <name>"
%Monkey = 'Athos'; 
Location = 'in_lab';       % editable constant
DataType = 'export_data';     % editable constant

%Folder = '2026-07-17';
Folder = '2026-07-15';


%Toddles to turn quality check plots on
PlotBehaviorCheck= false; % for visualizing behavior summary
PlotCalibratedEyes = false;% for plotting eye trace after calibration
PlotSpikeCheck = false; %turn on the spike navigator interface


%Check all the exported files in the folder

main_path = fullfile(Basic_Path, sprintf('Monkey %s', Monkey), Location, DataType, Folder);
all_files = dir(main_path);
all_files = {all_files(~[all_files.isdir]).name};

%Search for comments file
comments_path = findExportFile(all_files, main_path, 'trials_matlab');

%Search for the Eye data/analog file
analog_path   = findExportFile(all_files, main_path, 'analog_matlab');

%Search for online spike file. 'spikes' alone would also catch the waveform
%file, so it has to be excluded explicitly.
spike_path    = findExportFile(all_files, main_path, 'spikes', 'spikes_waveform');

%Search for spike waveform file
waveform_path = findExportFile(all_files, main_path, 'spikes_waveform');



if ~isempty(comments_path)
    comments_data = readtable(comments_path);
    BehaviorSummary = behaviorCheck(comments_data, PlotBehaviorCheck, main_path);
   
else
    
    error('No parsed trials data found. Please parse the data using the loader first.');
    
end


if ~isempty(analog_path)
    tmp = load(analog_path);
    eye_data = tmp.analog;

    %Eye calibration 
    disp('Start eye calibration');

    % Candidates in priority order: a session with a dedicated fixation block
    % calibrates off it, otherwise off whichever saccade task it ran.
    task_cal  = {'fixation', 'visual_saccade', 'memory_saccade'};
    
    caled_eyes = EyeCalibration(comments_data,eye_data,task_cal,[],[], PlotCalibratedEyes); 

    if caled_eyes.cal.applied == false
        disp('Eye calibration failed!');
        
    else
        disp('Eye calibration completed.');
        
    end


else
    disp('No parsed eye data found');
    caled_eyes.cal.applied = false;
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
                                   comments_data, main_path, PlotSpikeCheck );

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


%Screen the tasks and spikes according to the behavior and spike check
excludeTrials = [];
excludeSpikes = zeros(size(SpikeSummary,1));

[excludeTrials, excludeSpikes] = ScreenSession(BehaviorSummary,SpikeSummary);

%comments_data
%caled_eyes
%spike_data
%spike_waveform_data

%% Preprossing: Add RT to saccade tasks.
PlotRTCheck = true;
RT = CalculateRT(caled_eyes,comments_data,PlotRTCheck );


%% Auto-rounting to it's respective analyze protocol


%task_lists 






keyboard


% Task name used to filter trials (must match the Task field in expdata)
%analyze_task = 'time_delay_experiment';
analyze_task = 'visual_saccades_experiment';

% Eye-trace plot settings (see section 4)
eye_preMs      = 300;   % ms before go cue (fixation offset) to plot
eye_postMs     = 500;   % ms after  go cue to plot
angle_bin_deg  = 30;    % round target angle to this grid to form direction groups
eye_num_sample = 100;    % [] = plot all trials; N = plot only first N traces per direction

%% -------------------------------------------------------------------------
%% 2. LOAD AND FILTER TRIALS
%% -------------------------------------------------------------------------
if exist(comments_path, 'file')
    % Load the parsed BlackRock session file
    expdata = readtable(comments_path);
    
    
    % Keep only trials that were fully saved (no truncation)
    complete_saved = [expdata.Save_complete] == 1;

    % Keep only trials from the task we want to analyze
    task_sel = strcmp([expdata.Task], analyze_task);
   

    % Keep only trials with a valid choice (Choose_target is not NaN)
    trial_sel = ~isnan([expdata.Choose_target]);

    % Combine all criteria: complete, correct task, valid choice
    selected_data = complete_saved & task_sel & trial_sel;

    % Subset of trials used for psychometric analysis
    task_data = expdata(selected_data,:);

    TotalTrials = sum(selected_data);

    %% ---------------------------------------------------------------------
    %% 3. BUILD PSYCHOMETRIC INPUT MATRIX
    %% ---------------------------------------------------------------------
    % Extract trial-level variables for psychometric function fitting.
    % VisPsychometricFunction expects columns: [stimulus, direction, choice].

    stimulus = [task_data.Requested_target_2_time_offset];  % Requested time delay (ms)

    %{
    stimulus_real = ([task_data.Target_2_presented] - [task_data.Target_1_presented]) * 1000;  % Actual delay in ms
    
   fixation_on = [task_data.Fixation_point_on ];
   fixation_acquired = [task_data.Fixation_acquired ];

   diff_fix = fixation_acquired-fixation_on;


    target1_position_x =[task_data.Target_1_position_x];
    target1_position_y =[task_data.Target_1_position_y];

    target2_position_x = [task_data.Target_2_position_x];
    target2_position_y = [task_data.Target_2_position_y];

    %}
   


    %RT
    reactiont_time = [task_data.Choicetime] - [task_data.Fixation_point_off];

    direction = [task_data.Stimulus_direction];   % Stimulus order (e.g. left-first vs right-first)
    choice_response = [task_data.Choose_leftright] == 1;  % 0 = left, 1 = right

    % Matrix passed to psychometric visualization: [stimulus, direction, choice]
    Psymatrix = [stimulus, direction, choice_response];

    % Plot psychometric curve and return point of subjective equality (PSE) and threshold
   % [pse, threshold] = VisPsychometricFunction(Psymatrix);



    % Optional: uncomment to plot requested vs actual delay (calibration check)
    %{
    figure
    scatter(stimulus, stimulus_real, 'or');
    axis equal;
    hold on
    plot([0:250], [0:250], '--k');
    xlabel('Requested delay');
    ylabel('Actual delay');
    xlim([-0.1, max(stimulus_real)+30]);
    ylim([-0.1, max(stimulus_real)+30]);
    title('InLab Trainer');
    keyboard
    %}

    %% ---------------------------------------------------------------------
    %% 4. PLOT EYE TRACES ALIGNED TO GO CUE (fixation offset)
    %% ---------------------------------------------------------------------
    % Load the segmented analog/eye product and plot raw eye traces in a
    % window around the go cue, grouped by the chosen target's direction.
    if exist(analog_path, 'file')
        L = load(analog_path);
        analog = L.analog;

        % Keep the same trials the psychometric fit used (successful trials).
      %  eyedata = subsetAnalogTrials(analog, selected_data);
      eyedata = analog;
      task_data = expdata;
     

        % Pull eye X/Y (uV) and the shared sample time base (s, from Start).
        nTr      = size(eyedata.data, 2);
        eye_x    = reshape(eyedata.data(1,:,:), nTr, []);   % nTrials x nSamp
        eye_y    = reshape(eyedata.data(2,:,:), nTr, []);
        eye_time = eyedata.timeseq.relative_time;           % 1 x nSamp, s from Start

        % Go cue (fixation offset) time in the same frame as eye_time.
        marker_time = task_data.Fixation_point_off - task_data.Start;   % nTrials x 1, s

        % Align every trace to the go cue over [-preMs, +postMs].
        [aligned_eye, rts] = AlignEyeTrace(eye_x, eye_y, eye_time, ...
             marker_time, eye_preMs, eye_postMs);

        aligned_eye.marker = 'fixation off';%to indicate it on the plot.

        % Choice conditions = binned chosen-target direction (one per trial).
        choose = task_data.Choose_target;
        ang = nan(nTr, 1);
        ang(choose==1) = task_data.Target_1_angle(choose==1);
        ang(choose==2) = task_data.Target_2_angle(choose==2);
        conditions = mod(round(ang/angle_bin_deg)*angle_bin_deg + 180, 360) - 180;

        plotAlignedEyeTraces(aligned_eye, rts, conditions, ...
            sprintf('%s  %s', Monkey, Folder), eye_num_sample);
    else
        disp('No analog (eye) .mat found; run the loader with LoadAnalogData on first.');
    end

else
    % File missing: run the BlackRock parser on raw data first, then re-run this script
    disp('No data found, please parse the raw data first.')
end

%keyboard


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


% AlignEyeTrace now lives in ToolsAndFunctions/AnalyzeTools/AlignEyeTrace.m
% so that EyeCalibration can share it.


function plotAlignedEyeTraces(aligned_eye, relative_time_seq, conditions, ttl, num_of_sample)
% Plot marker-aligned eye traces grouped by a per-trial condition.
%
%   aligned_eye       - struct from AlignEyeTrace: .x, .y (nTrials x nOut) and
%                       .marker (label for the alignment event).
%   relative_time_seq - 1 x nOut time from the marker (s); 0 at the marker.
%   conditions        - nTrials x 1 grouping value per trial (e.g. binned chosen
%                       target direction, deg). NaN -> trial skipped.
%   ttl               - figure super-title (e.g. 'Monkey X  YYYY-MM-DD').
%   num_of_sample     - (optional) max traces to draw per condition; [] or omitted
%                       plots all. The first num_of_sample trials of each condition
%                       are used (same trials in both figures).
%
% Produces two figures: (1) X (solid) & Y (dashed) vs time, one subplot per
% condition; (2) 2D gaze trajectory (X vs Y), one color per condition.

    if nargin < 5;  num_of_sample = [];  end

    Xall   = aligned_eye.x;
    Yall   = aligned_eye.y;
    marker = aligned_eye.marker;
    tt_ms  = relative_time_seq * 1000;              % display axis in ms

    % Keep trials with a defined condition and some data.
    keep = ~isnan(conditions(:)) & any(~isnan(Xall), 2);
    if ~any(keep)
        warning('plotAlignedEyeTraces: no trials with a valid condition / data.');
        return
    end
    Xall = Xall(keep,:);  Yall = Yall(keep,:);  cond = conditions(keep);

    grps = unique(cond);
    nGrp = numel(grps);
    cmap = hsv(nGrp);            % condition -> hue; swap for lines(nGrp) if preferred

    % ---------------------------------------------------------------------
    % Figure 1: X (solid) & Y (dashed) vs time, one subplot per condition
    % ---------------------------------------------------------------------
    figure('Name', 'Eye traces vs time');
    nc = ceil(sqrt(nGrp));
    nr = ceil(nGrp / nc);
    for d = 1:nGrp
        idx = find(cond == grps(d));
        if ~isempty(num_of_sample)
            idx = idx(1:min(num_of_sample, numel(idx)));   % first N of this condition
        end
        subplot(nr, nc, d); hold on;
        plot(tt_ms, Xall(idx,:)', '-',  'Color', cmap(d,:), 'LineWidth', 0.5);
        plot(tt_ms, Yall(idx,:)', '--', 'Color', cmap(d,:), 'LineWidth', 0.5);
        yl = ylim;  plot([0 0], yl, 'k:');  ylim(yl);   % marker at t=0
        xlim([tt_ms(1) tt_ms(end)]);
        xlabel(sprintf('Time from %s (ms)', marker));
        ylabel('Eye position (\muV)');
        title(sprintf('%.0f\\circ  (n=%d)', grps(d), numel(idx)));
        % legend via dummy handles (solid=X, dashed=Y)
        hx = plot(nan, nan, '-k');  hy = plot(nan, nan, '--k');
        legend([hx hy], {'X', 'Y'}, 'Location', 'best');
        hold off;
    end
    sgtitle(sprintf('%s  |  eye traces aligned to %s', ttl, marker));

    % ---------------------------------------------------------------------
    % Figure 2: 2D gaze trajectory (X vs Y), one color per condition
    % ---------------------------------------------------------------------
    figure('Name', '2D gaze trajectory'); hold on;
    hleg = gobjects(nGrp, 1);
    for d = 1:nGrp
        idx = find(cond == grps(d));
        if ~isempty(num_of_sample)
            idx = idx(1:min(num_of_sample, numel(idx)));   % first N of this condition
        end
        for k = 1:numel(idx)
            h = plot(Xall(idx(k),:), Yall(idx(k),:), '-', ...
                'Color', cmap(d,:), 'LineWidth', 0.5);
            if k == 1;  hleg(d) = h;  end     % one handle per group for legend
        end
    end
    axis equal;
    xlabel('Eye X (\muV)');
    ylabel('Eye Y (\muV)');
    title(sprintf('%s  |  2D gaze (%.0f to %.0f ms around %s)', ...
        ttl, tt_ms(1), tt_ms(end), marker));
    legend(hleg, arrayfun(@(a) sprintf('%.0f\\circ', a), grps, 'UniformOutput', false), ...
        'Location', 'bestoutside');
    hold off;
end


