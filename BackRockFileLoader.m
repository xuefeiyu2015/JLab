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
clear
close all

%% Check if the path is setup ready

if isempty(which('openNEV'))
   % addpath(genpath('/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Program_Matlab_Local/JLab/ToolsAndFunctions/NPMK'));
   addpath('/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Program_Matlab_Local/JLab/ToolsAndFunctions/NPMK');
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
FolderList = resolveFolders(Folder, DataTypePath);

%% Load Analog Data
% Whether to load analog data. This is the per-batch default; the .ns2 picker
% below may switch it off for an individual folder, so it is re-applied each
% iteration and never leaks between folders.
LoadAnalogData_default = true;
AnalogIdentifier = '*.ns2';
Segment_Marker = ['Start','End'];
Segment_Buffer = [-500,500];%Time buffer to keep before the segment marker and after the segment marker

%% Load Online Spike Data
LoadOnlineSpikeData_default = false;

%% Experimental meta data (one entry per session within the recording)
% A single .nev recording can contain several experiment sessions (the task is
% started/ended multiple times). Each session writes its own metadata block, so
% experiment is a struct array indexed by session_index.
exp_template = struct();
exp_template.git_commit                   = NaN;
exp_template.viewing_distance             = NaN;          % in cm
exp_template.screen_size                  = [NaN, NaN];   % W x H cm
exp_template.screen_resolution            = [NaN, NaN];   % pixels
exp_template.FPS                          = NaN;          % Hz
exp_template.eyetracker_rate              = NaN;          % Hz
exp_template.eye_tracked                  = NaN;          % string
exp_template.photodiode_circles           = NaN;          % 'visible'/'hidden'
exp_template.photodiode_fixation_position = [NaN, NaN];   % deg
exp_template.photodiode_target_1_position = [NaN, NaN];   % deg
exp_template.photodiode_target_2_position = [NaN, NaN];   % deg
exp_template.start                        = NaN;          % in s
exp_template.end                          = NaN;          % in s
exp_template.end_by                       = NaN;          % reason the session ended, e.g. 'experimenter closed task'
% experiment and session_index are reset per folder inside the batch loop below.


%% Config a structure to save each trial
trial = struct();
trial.Trial_number = NaN; %Current trial number
trial.Session = NaN; %which experiment session this trial belongs to
trial.Task = NaN; %TaskType
trial.Trial_type = NaN;
trial.Start = NaN; % trial start time, in s
trial.Fixation_position = [NaN,NaN];%array:1-2: postion;%in deg
trial.Fixation_size = NaN;% in deg
trial.Fixation_acceptance_window=NaN; % in deg
trial.Fixation_color = NaN;%color
trial.Requested_fixation_hold_time = NaN; % in ms
trial.Requested_fixation_duration = NaN; %in ms
trial.Requested_timeout = NaN; % in ms
trial.Requested_time_between_trials = NaN; % in ms
trial.Target_1_position = [NaN,NaN];

trial.Target_1_size = NaN; % in deg
trial.Target_1_acceptance_window = NaN; % in deg
trial.Target_1_color = NaN; % in deg
trial.Requested_target_1_hold_time  = NaN; %in ms
trial.Requested_target_1_timeout = NaN; %in ms
trial.Requested_target_1_duration = NaN; %in ms



trial.Target_2_position = [NaN,NaN];
trial.Target_2_size = NaN; % in deg
trial.Target_2_acceptance_window = NaN; % in deg
trial.Target_2_color = NaN; % in deg

trial.Requested_target_2_time_offset = NaN; %in ms
trial.Requested_target_2_hold_time  = NaN; %in ms
trial.Requested_penalty_box_duration = NaN; %in ms

trial.Requested_target_dim_opacity = NaN;% 0 to 1
trial.Requested_target_1_visible_duration = NaN; %in ms

trial.Fixation_point_on = NaN; %in ms
trial.Fixation_acquired = NaN; %in ms
trial.Fixation_point_off = NaN; %in ms
trial.Broke_fixation = NaN; %in ms
trial.Target_1_presented =NaN; %in ms
trial.Target_2_presented =NaN; %in ms
trial.Targets_off = NaN; %in ms
trial.Target_1_off = NaN; %in ms


trial.Choiceoutcome = NaN; 
trial.Choosen_choice = NaN; %1 or 2
trial.Choicetime = NaN; %in s
trial.End = NaN; %in ms
trial.Trialoutcome = NaN; %Correct or time out or others
trial.Reward_start = NaN; %in s 
trial.Reward_amount = NaN; %in s 
trial.Reward_end =NaN; %in s
trial.Save_complete = 0; %true: completely saved(have start marker); otherwise, false

% Newly added trial events  06-17-2026
trial.Feedback_flash_on              = NaN; %in s (event time)
trial.Feedback_flash_off             = NaN; %in s (event time)
trial.Fixation_exited                = NaN; %in s (event time)
trial.Target_deadline_exceeded       = NaN; %in s (event time)
trial.Requested_feedback_flash_duration = NaN; %in ms
trial.Requested_choice_timeout       = NaN; %in ms
trial.Requested_target_reach_deadline = NaN; %in ms (None -> NaN)
trial.Target_1_side                  = NaN; %'left' or 'right'
trial.Requested_time_offset_min      = NaN; %in ms
trial.Requested_time_offset_max      = NaN; %in ms
trial.Requested_time_offset_active   = NaN; %string, space-separated active offsets (ms)


trial.undefined = strings(0,1);%Duplicates or undefind events
trial.duplicates = strings(0,1);%Duplicates or undefind events


% define field map
% For experimental meta file map
exp_events = containers.Map({'git commit','viewing distance','screen size','screen resolution','FPS','eyetracker sample rate','eyetracker tracking'},...
    {'git_commit','viewing_distance','screen_size','screen_resolution','FPS','eyetracker_rate','eye_tracked'});



%For trial map
time_events = containers.Map( {'Start', 'Fixation point on','Fixation point off','Reward end','Target 1 presented','Target 2 presented','Targets off',...
    'Fixation acquired','Broke fixation','Target 1 acquired','Target 2 acquired','Target 1 off',...
    'Feedback flash on','Feedback flash off','Fixation exited','Target deadline exceeded'}, ...
    {'Start','Fixation_point_on','Fixation_point_off','Reward_end','Target_1_presented','Target_2_presented','Targets_off',...
    'Fixation_acquired','Broke_fixation','Choicetime','Choicetime','Target_1_off',...
    'Feedback_flash_on','Feedback_flash_off','Fixation_exited','Target_deadline_exceeded'} ...
);

segment_events = containers.Map( {'Experiment','Fixation color','Target 1 color','Target 2 color','Trial type','Target 1 on the'},...
    {'Task','Fixation_color','Target_1_color','Target_2_color','Trial_type','Target_1_side'});

information_events = containers.Map( ...
    {'Fixation position','Fixation size','Fixation acceptance window'...
       'Target 1 size','Target 1 acceptance window','Requested fixation hold time',...
       'Requested timeout','Requested time between trials',...
       'Target 1 position','Target 1 size','Target 1 acceptance window','Requested fixation duration',...
       'Requested target 1 hold time','Requested target 2 hold time'...
       'Target 2 position','Target 2 size','Target 2 acceptance window',...
       'Requested target 1 duration','Requested target 2 time offset',...
       'Requested target 1 timeout','Requested penalty box duration',...
       'Reward start','Requested target dim opacity','Requested target 1 visible duration',...
       'Requested feedback flash duration','Requested choice timeout','Requested target reach deadline'

       },...
    {'Fixation_position','Fixation_size','Fixation_acceptance_window' ...
    'Target_1_size','Target_1_acceptance_window','Requested_fixation_hold_time',...
    'Requested_timeout','Requested_time_between_trials',...
    'Target_1_position','Target_1_size','Target_1_acceptance_window','Requested_fixation_duration',...
    'Requested_target_1_hold_time','Requested_target_2_hold_time'...
    'Target_2_position','Target_2_size','Target_2_acceptance_window',...
    'Requested_target_1_duration','Requested_target_2_time_offset',...
    'Requested_target_1_timeout','Requested_penalty_box_duration',...
    'Reward_start','Requested_target_dim_opacity','Requested_target_1_visible_duration',...
    'Requested_feedback_flash_duration','Requested_choice_timeout','Requested_target_reach_deadline'
    });

    dash_events = {'End','Correct choice','Wrong choice'};
    outcome_events = {'Correct choice','No choice','Wrong choice'};

    

%% Batch process each date folder
% load -> parse -> add features -> export, once per folder in FolderList.
% A failure in one folder is caught and reported; the batch keeps going.
% (Tip: the parse/feature/export body below keeps its original indentation;
%  press Ctrl+I in the MATLAB editor to auto-indent the whole file.)
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

    % --- reset per-folder state ---
    clear trials                          % reset the exist('trials','var') first-event guard
    experiment    = exp_template([]);     % empty struct array, grows one entry per session
    session_index = 0;
    LoadAnalogData = LoadAnalogData_default;  % re-apply default so a skip doesn't leak

    % --- Load events and timing: auto-detect the .nev (largest if several) ---
    nev_list = dir(fullfile(DataFolder, '*.nev'));
    if isempty(nev_list)
        error('No .nev file found in: %s', DataFolder);
    end
    [~, idx] = max([nev_list.bytes]);     % pick the largest when multiple
    Filename_nev = nev_list(idx).name;
    CompleteFilePath_nev = fullfile(DataFolder, Filename_nev);

    tmpdata = openNEV(CompleteFilePath_nev,'report','nosave');
    if isempty(tmpdata)
        error('No data found, please check your path: %s', CompleteFilePath_nev);
    end

    nevdata = tmpdata.Data;
    Events = nevdata.Comments.Text;
    EventTime = nevdata.Comments.TimeStampSec;

    % --- Detect eye-trace .ns2 file(s); let the user pick, or skip ---
    if LoadAnalogData
        ns_list = dir(fullfile(DataFolder, AnalogIdentifier));
        Filename_ns = '';
        if ~isempty(ns_list)
            ns_names = {ns_list.name};
            if length(ns_names) > 1
                [sel, ok] = listdlg('PromptString', 'Select eye (.ns2) file to load (Cancel = skip):', ...
                    'SelectionMode', 'single', 'ListString', ns_names, 'ListSize', [400 200]);
                if ok
                    LoadAnalogData = true;
                    Filename_ns = ns_names{sel};
                else
                    LoadAnalogData = false;
                    disp('Skip analog loading this time.')
                end
            else
                Filename_ns = ns_names{1};
            end
        else
            disp('No analog channel found');
            LoadAnalogData = false;
        end
    end

    % --- Load analog channels (eye data only, temporary) ---
    if LoadAnalogData
        CompleteFilePath_nstmp_ana_data = fullfile(DataFolder, Filename_ns);
        tmp_ana_data = openNSx(CompleteFilePath_nstmp_ana_data,'read','report', 'uv');

        nsxdata = tmp_ana_data.Data; % in uV
        nsx_starttime  = tmp_ana_data.MetaTags.Timestamp;
        nsx_timeresolution  = tmp_ana_data.MetaTags.TimeRes;
        nsx_samplingrate = tmp_ana_data.MetaTags.SamplingFreq;
        nsx_starttimeSec  = nsx_starttime/nsx_timeresolution;
        N = length(nsxdata);
        nsx_rel_time = (0:N-1)/nsx_samplingrate; %add-on time seqence from the starttime
        nsx_abs_time = nsx_starttimeSec + nsx_rel_time;
    end

    % --- Show the selected files before processing/export ---
    fprintf('\n--- Selected Blackrock files ---\n');
    fprintf('  NEV (events): %s\n', Filename_nev);
    if LoadAnalogData
        fprintf('  NS2 (eye):    %s\n', Filename_ns);
    else
        fprintf('  NS2 (eye):    (none loaded)\n');
    end
    fprintf('--------------------------------\n');

 EventsNumber = size(Events,1);

 %
 Event_full = table(Events);
 Event_full.Time = EventTime';
 %}


%% Transform the event into tables for event marker
for i = 1:EventsNumber
    curr_event = Events(i,:);
    curr_eventtime = EventTime(i);
    %First check if it is an experimental setup
    exp_pattern = '^Experiment (start|end):\s*(.+)$';
    exp_flag = regexp(curr_event, exp_pattern, 'tokens');
    if ~isempty(exp_flag)
        %Get the experiment meta data
        exp_marker = exp_flag{1}{1}; %start or end
        exp_token  = strtrim(exp_flag{1}{2});

        %A new session begins at each "Experiment start: git commit ..." line
        %(the first line of every metadata block within the recording).
        if strcmp(exp_marker,'start') && startsWith(exp_token,'git commit')
            session_index = session_index + 1;
            experiment(session_index) = exp_template;
            experiment(session_index).start = curr_eventtime;
        end

        if session_index >= 1
            if strcmp(exp_marker,'end')
                experiment(session_index).end = curr_eventtime; %last end line wins
                if ~startsWith(exp_token,'git commit')
                    %Capture why the session ended (e.g. 'experimenter closed task').
                    %The git-commit end line is just a commit re-stamp, not a reason.
                    experiment(session_index).end_by = exp_token;
                end
            end

            %Saved meta data into the current session
            if startsWith(exp_token,'git commit')
                experiment(session_index).git_commit = strtrim(strrep(exp_token,'git commit',''));
            elseif startsWith(exp_token,'eyetracker tracking')
                eye_tokens = regexp(exp_token,'eyetracker tracking (\w+)','tokens');
                experiment(session_index).eye_tracked = eye_tokens{1}{1};
            elseif startsWith(exp_token,'photodiode')
                %Photodiode metadata: 'circles visible/hidden' or a (x, y) deg position
                coord = regexp(exp_token, '\(\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\)', 'tokens');
                if startsWith(exp_token,'photodiode circles')
                    experiment(session_index).photodiode_circles = strtrim(strrep(exp_token,'photodiode circles',''));
                elseif startsWith(exp_token,'photodiode fixation position') && ~isempty(coord)
                    experiment(session_index).photodiode_fixation_position = cellfun(@str2double, coord{1});
                elseif startsWith(exp_token,'photodiode target_1 position') && ~isempty(coord)
                    experiment(session_index).photodiode_target_1_position = cellfun(@str2double, coord{1});
                elseif startsWith(exp_token,'photodiode target_2 position') && ~isempty(coord)
                    experiment(session_index).photodiode_target_2_position = cellfun(@str2double, coord{1});
                end
            elseif strcmp(exp_token,'experimenter closed task')
                %end marker text, nothing to store
            else
                %Numeric data (viewing distance / screen size / resolution / FPS / rate)
                num_tokens = regexp(exp_token, ...
                    '^\s*(.*?)\s+(\d+\.?\d*)\D*(\d+\.?\d*)?', 'tokens');
                if ~isempty(num_tokens)
                    event_exp      = strtrim(num_tokens{1}{1});
                    nums           = cellfun(@str2double,num_tokens{1}(2:end));
                    exp_event_keys = keys(exp_events);
                    flag_array     = contains(exp_event_keys,event_exp);
                    if any(flag_array)
                        field = exp_events(exp_event_keys{flag_array});
                        experiment(session_index).(field) = nums(~isnan(nums));
                    end
                end
            end
        end

    else %Trial data

        %Get trial number and event text
         mainTokens = regexp(curr_event, '^Trial\s+(\d+):\s*(.*)$', 'tokens');    
         TrialNum_curr = str2double(mainTokens{1}{1}); % Get trial number  
         event_text = strtrim(mainTokens{1}{2}); %Get the remaining events
    
        % Define the current trial.
        % A new trial begins whenever the parsed trial number changes from the
        % previous trial event, OR the session changes. Trials are keyed by
        % POSITION (trial_index), not by number, so a reset counter
        % (e.g. ...,30,0,1,...) starts new trials instead of merging into an
        % earlier same-numbered trial. The session test also splits trials that
        % share a number across two sessions (e.g. session 1 trial 1 vs session 2
        % trial 1).
        if exist('trials','var') ~= 1 || isempty(trials)
            % first trial event
            trials = trial;
            trial_index = 1;
            trials(trial_index).Trial_number = TrialNum_curr;
            trials(trial_index).Session = session_index;
            prev_trial_number = TrialNum_curr;
            prev_session = session_index;
        else
            if TrialNum_curr ~= prev_trial_number || session_index ~= prev_session
                % trial number or session changed -> start a new trial
                trial_index = trial_index + 1;
                currTrial = trial;
                currTrial.Trial_number = TrialNum_curr;
                currTrial.Session = session_index;
                trials(trial_index) = currTrial;
            end
            prev_trial_number = TrialNum_curr;
            prev_session = session_index;
        end
    
       %go through each type of events
       time_flag = contains(event_text, keys(time_events));
       info_flag = contains(event_text, keys(information_events));
       seg_flag = contains(event_text, keys(segment_events));
       dash_flag = contains(event_text, dash_events) & contains(event_text, '-');
       outcome_flag = contains(event_text, outcome_events);
       offset_range_flag = contains(event_text, 'Requested time offset range');
    
    
       if time_flag
         %Directly assign current time
         time_event_keys = keys(time_events);
         flag_array = contains(time_event_keys,event_text);
         curr_key = time_event_keys{flag_array};
         field = time_events(curr_key);
    
         if isnan(trials(trial_index).(field))
             %First check whether it's already assigned
            trials(trial_index).(field) = curr_eventtime;
         else
             %Otherwise, put it into the duplicates for further debug
              trials(trial_index).duplicates(end+1,1) = event_text;
              disp('Duplicate found for time event:');
              disp(event_text);
    
         end
         
         
    
    
       elseif info_flag
           %Extract values following the event
           coord_pattern = '^(.*?)\s*\(\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\)\s*deg$';
           reward_pattern = '^(.*?)\s*\(([\d\.]+)ms';
           time_pattern = '^(.*?)\s+([-+]?\d*\.?\d+|None|none)\s*ms$';
           size_pattern = '^(.*?)\s+([-+]?\d*\.?\d+)\s*(?:deg)?$';
            
           
           coor_tokens = regexp(event_text, coord_pattern, 'tokens');
           reward_tokens = regexp(event_text, reward_pattern, 'tokens');
           
           
           if ~isempty(coor_tokens)
               %Get the event and coordinate/reward amount
               event_coord = strtrim(coor_tokens{1}{1});
               coord = cellfun(@str2double, coor_tokens{1}(2:end));
    
               info_event_keys = keys(information_events);
               flag_array = contains(info_event_keys,event_coord);
               curr_key = info_event_keys{flag_array};
               field = information_events(curr_key);
               if all(isnan(trials(trial_index).(field)))
                   %If it is empty
                   trials(trial_index).(field) = coord;
               else
                   trials(trial_index).duplicates(end+1,1) = event_coord;
                    disp('Duplicate found for coor event:');
                    disp(event_coord);
    
               end
    
    
           elseif ~isempty(reward_tokens)
               event_reward = strtrim(reward_tokens{1}{1});
               reward_amount = cellfun(@str2double, reward_tokens{1}(2:end));
    
               info_event_keys = keys(information_events);
               flag_array = contains(info_event_keys,event_reward);
               curr_key = info_event_keys{flag_array};
               field = information_events(curr_key);
               if isnan(trials(trial_index).(field) )
                   trials(trial_index).(field) = curr_eventtime;
               else
                   trials(trial_index).duplicates(end+1,1) = field;
                   disp('Duplicate found for reward event:');
                    disp(event_reward);
               end
    
               if isnan(trials(trial_index).Reward_amount)
                    trials(trial_index).Reward_amount = reward_amount;
               else
                   trials(trial_index).duplicates(end+1,1) = 'Reward_amount';
                   disp('Duplicate found for reward amount');
                   
               end
               
             
    
    
           else
               combined_pattern = [ time_pattern, '|', size_pattern];
               tokens = regexp(event_text, combined_pattern, 'tokens');
               %Get the event and duration
               
               event_dur = strtrim(tokens{1}{1});
               dur = str2double(tokens{1}{2});
               
    
               info_event_keys = keys(information_events);
               flag_array = contains(info_event_keys,event_dur);
               curr_key = info_event_keys{flag_array};
               field = information_events(curr_key);


               if isnan(trials(trial_index).(field))
                    trials(trial_index).(field) = dur;
               else
                   trials(trial_index).duplicates(end+1,1) = field;
                    disp('Duplicate found for duration/size event:');
                    disp(event_dur);
    
               end
    
           end
    
    
    
       elseif seg_flag
           %segment the text by the last space
           
           last_space_idx = find(event_text == ' ', 1, 'last');
           event_name = strtrim(event_text(1:last_space_idx-1));  
           value = strtrim(event_text(last_space_idx+1:end)); 
    
           segment_event_keys = keys(segment_events);
           flag_array = contains(segment_event_keys,event_name);
           curr_key = segment_event_keys{flag_array};
           field = segment_events(curr_key);
    
           if isnan(trials(trial_index).(field))
              trials(trial_index).(field) = value;
           else
               trials(trial_index).duplicates(end+1,1) = field;
               disp('Duplicate found for segment event:');
               disp(field);
    
           end
    
       elseif dash_flag
           %segment the text by the dash
           dash_idx = find(event_text == '-', 1, 'first');
           event   = strtrim(event_text(1:dash_idx-1));
           outcome = strtrim(event_text(dash_idx+1:end));
           if contains(event,'End')

               
    
               if isnan(trials(trial_index).End)
                   trials(trial_index).End = curr_eventtime;
               else
                   trials(trial_index).duplicates(end+1,1) = event;
                    disp('Duplicate End  found for dash event:');
                    disp(event);
    
               end
    
               if isnan(trials(trial_index).Trialoutcome)
                    trials(trial_index).Trialoutcome = outcome;
               else
                   trials(trial_index).duplicates(end+1,1) ='Trialoutcome';
                    disp('Duplicate outcome found for dash event:');
                    disp(event);
    
               end
           elseif contains(event,'choice')
               if isnan(trials(trial_index).Choosen_choice)
                    trials(trial_index).Choosen_choice = outcome;
               else
                   trials(trial_index).duplicates(end+1,1) ='Choosen_choice';
                    disp('Duplicate found for dash event:');
                    disp(event);
    
               end
           else
               disp('Undefined dash event:');
               disp(event_text);
               disp('Check the undefined var');
               trials(trial_index).undefined(end+1,1) = string(event_text);
           end
    
       elseif outcome_flag
           %Save the choice outcome and time
           if isnan(trials(trial_index).Choiceoutcome)
                trials(trial_index).Choiceoutcome = event_text;
           else
               trials(trial_index).duplicates(end+1,1) ='Choiceoutcome';
                    disp('Duplicate found for outcome event:');
                    disp(event_text);
    
           end
           %{
           if isnan(trials(trial_index).Choicetime )
                trials(trial_index).Choicetime = curr_eventtime;
           else
                trials(trial_index).duplicates(end+1,1) ='Choicetime';
                    disp('Duplicate found for outcome event:');
                    disp('Choicetime');
    
           end
           %}

       elseif offset_range_flag
           % "Requested time offset range [min, max] ms (active: [v1, v2, ...])"
           % Range -> two numeric fields; active list -> a space-separated string
           % (CSV columns cannot hold multiple values).
           range_tok  = regexp(event_text, 'range\s*\[\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\]', 'tokens');
           active_tok = regexp(event_text, 'active:\s*\[([^\]]*)\]', 'tokens');
           if ~isempty(range_tok)
               trials(trial_index).Requested_time_offset_min = str2double(range_tok{1}{1});
               trials(trial_index).Requested_time_offset_max = str2double(range_tok{1}{2});
           end
           if ~isempty(active_tok)
               active_vals = strtrim(strsplit(active_tok{1}{1}, ','));
               trials(trial_index).Requested_time_offset_active = char(strjoin(active_vals, ' '));
           end

       else
           %Undefined fields
           disp('Undefined event detected:');
           disp(event_text);
           disp('Check the undefined var');
           trials(trial_index).undefined(end+1,1) = string(event_text);
    
           
    
    
           %keyboard
    
    
       end
    
    
    
       if trials(trial_index).Start > 0
           trials(trial_index).Save_complete = 1;
    
       end
       



    end %End of if the judgement of if it is experiment flag or trial flag
   


end
%{
diff = [trials.Target_1_presented] - [trials.Target_2_presented];

A = [[trials.Trial_number]', vertcat(trials.Target_1_position),vertcat(trials.Target_2_position),diff'*1000 ];
B = table(Events);
B.EventTime = EventTime';
%}
%% Add a few feature for further analysis
%1. Transform Cartesian into Polar for target postion
% -180(left) to 180(right)
    Target_1_xy = vertcat(trials.Target_1_position); 
    [theta, Target_1_ecc] = cart2pol(Target_1_xy(:,1),Target_1_xy(:,2));
    Target_1_angle = mod(90 - rad2deg(theta), 360);
    Target_1_angle(Target_1_angle >= 180) = Target_1_angle(Target_1_angle >= 180) - 360;

    Target_2_xy = vertcat(trials.Target_2_position);
    [theta, Target_2_ecc] = cart2pol(Target_2_xy(:,1),Target_2_xy(:,2));
    Target_2_angle = mod(90 - rad2deg(theta), 360);
    Target_2_angle(Target_2_angle >= 180) = Target_2_angle(Target_2_angle >= 180) - 360;   

    stimulus_dir = (Target_1_angle >= 0) * 2 - 1;
    stimulus_dir(isnan(Target_1_angle)) = NaN; 
 
 %2. Transform choice into target1/target2 and left/right
    ChooseTarget = cellfun(@(s) str2double(s(end)), {trials.Choosen_choice});
    ChooseLeftRight = ChooseTarget;
    ChooseLeftRight(ChooseTarget==1) = (Target_1_angle(ChooseTarget==1) >= 0) * 2 - 1;
    ChooseLeftRight(ChooseTarget==2) = (Target_2_angle(ChooseTarget==2) >= 0) * 2 - 1;

 %3. Add these features back

    Target1Angle_cell = num2cell(Target_1_angle);
    [trials.Target_1_angle] = deal(Target1Angle_cell{:});

    Target2Angle_cell = num2cell(Target_2_angle);
    [trials.Target_2_angle] = deal(Target2Angle_cell{:});

    stimulus_dir_cell = num2cell(stimulus_dir);
    [trials.Stimulus_direction] = deal(stimulus_dir_cell{:});

    ChooseTarget_cell = num2cell(ChooseTarget);
    [trials.Choose_target] = deal(ChooseTarget_cell{:});
    ChooseLeftRight_cell = num2cell(ChooseLeftRight);
    [trials.Choose_leftright] = deal(ChooseLeftRight_cell{:});

    Target_1_ecc_cell = num2cell(Target_1_ecc);
    [trials.Target_1_eccentricity] = deal(Target_1_ecc_cell{:});

    Target_2_ecc_cell = num2cell(Target_2_ecc);
    [trials.Target_2_eccentricity] = deal(Target_2_ecc_cell{:});
    


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

disp(sprintf('File:%s Experiment meta has been parsed into %s',Filename_nev,OutputFileName_exp));


% Save trials as .csv
% Flatten array/vector fields (e.g. positions) into separate columns
trials_flat = rmfield(trials, {'undefined', 'duplicates'});
trials_table = struct2table(trials_flat);

% Explicit 0-based sequential row index (pandas-friendly: read_csv(index_col='index')).
% Kept separate from Trial_number, which holds the real (resetting) trial number.
trials_table = addvars(trials_table, (0:height(trials_table)-1)', ...
    'Before', 1, 'NewVariableNames', 'index');


% Convert any cell columns to strings for CSV compatibility
for col = trials_table.Properties.VariableNames
    c = col{1};
    if isnumeric(trials_table.(c)) && size(trials_table.(c), 2) == 2
        trials_table.([c '_x']) = trials_table.(c)(:,1);
        trials_table.([c '_y']) = trials_table.(c)(:,2);
        trials_table.(c) = [];
    end
end

writetable(trials_table, fullfile(OutputPath, OutputFileName_trials));


disp(sprintf('File:%s Trials Data has been parsed into %s',Filename_nev,OutputFileName_trials));

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



function folders = resolveFolders(Folder, DataTypePath)
% Normalize Folder into a cellstr list of YYYY-MM-DD folder names.
% Empty Folder -> auto-discover every date folder under DataTypePath.
    datePat = '^\d{4}-\d{2}-\d{2}$';
    if isempty(Folder)
        d = dir(DataTypePath);
        names = {d([d.isdir]).name};
        keep = ~cellfun('isempty', regexp(names, datePat, 'once'));
        folders = sort(names(keep));
    else
        folders = cellstr(Folder);   % char, string array, or cellstr -> cellstr
    end
    if isempty(folders)
        error('No date folders to process under: %s', DataTypePath);
    end
end


function compare_fields(s1,s2);
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