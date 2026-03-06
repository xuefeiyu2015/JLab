% Script to open and load blackrock data
% by Xuefei Yu 03-02-2026
% Currently only for behavior data, --03-02-2026
clear
close all

LoadAnalogData = false; % Whether to load analog channels


Basic_Path  = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
Monkey = 'Monkey Porthos';
Location = 'in_lab';
Task = 'timedelay';
DataType = 'raw_data';
Folder = '2026-03-05';
Filename_nev = 'Hub1-test_for_temporal_discrimination_task_03052026.nev';
%Filename_nev = 'Hub1-Porthos_20260206_t1020_dxxxx_vis_saccade.nev';
Filename_ns = 'NSP-test_for_temporal_discrimination_task_03052026.ns2';%Eye trace data

%Path for export parsed data
OutputFolder = 'export_data';
OutputPath = fullfile(Basic_Path,Monkey,Location,Task,OutputFolder,Folder);
OutputFileName = 'Blackrock_'+string(Folder)+'.mat';



%Load events and events timing
CompleteFilePath_nev = fullfile(Basic_Path,Monkey,Location,Task,DataType ,Folder,Filename_nev);

tmpdata = openNEV(CompleteFilePath_nev,'report','nosave');
nevdata = tmpdata.Data;

Events = nevdata.Comments.Text;
EventTime = nevdata.Comments.TimeStampStartedSec;


if LoadAnalogData
%Load analog channels--eye data only temporally
%Will update this part later

CompleteFilePath_nstmp_ana_data = fullfile(Basic_Path,Monkey,Location,Task,DataType ,Folder,Filename_ns);
tmp_ana_data = openNSx(CompleteFilePath_nstmp_ana_data,'read','report', 'uv');

nsxdata = tmp_ana_data.Data; % in uV
nsx_starttime  = tmp_ana_data.MetaTags.Timestamp;
nsx_samplingrate = tmp_ana_data.MetaTags.SamplingFreq;
N = length(nsxdata);
nsx_rel_time = (0:N-1)/nsx_samplingrate; %add-on time seqence from the starttime

end %end of load analogdata


%% Experimental meta data
experiment = struct();
experiment.git_commit        = NaN;
experiment.viewing_distance  = NaN;          % in cm
experiment.screen_size       = [NaN, NaN];    % W x H cm
experiment.screen_resolution = [NaN, NaN];   % pixels
experiment.FPS               = NaN;         % Hz
experiment.eyetracker_rate   = NaN;        % Hz
experiment.eye_tracked       = NaN;     % string
experiment.start        =NaN; %in s
experiment.end        = NaN; % in s


%% Config a structure to save each trial
trial = struct();
trial.Trial_number = NaN; %Current trial number
trial.Task = NaN; %TaskType
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

trial.Fixation_point_on = NaN; %in ms
trial.Fixation_acquired = NaN; %in ms
trial.Fixation_point_off = NaN; %in ms
trial.Broke_fixation = NaN; %in ms
trial.Target_1_presented =NaN; %in ms
trial.Target_2_presented =NaN; %in ms
trial.Targets_off = NaN; %in ms


trial.Choiceoutcome = NaN; 
trial.Choosen_choice = NaN; %1 or 2
trial.Choicetime = NaN; %in s
trial.End = NaN; %in ms
trial.Trialoutcome = NaN; %Correct or time out or others
trial.Reward_start = NaN; %in s 
trial.Reward_amount = NaN; %in s 
trial.Reward_end =NaN; %in s 
trial.Save_complete = 0; %true: completely saved(have start marker); otherwise, false

trial.undefined = strings(0,1);%Duplicates or undefind events
trial.duplicates = strings(0,1);%Duplicates or undefind events


% define field map
% For experimental meta file map
exp_events = containers.Map({'git commit','viewing distance','screen size','screen resolution','FPS','eyetracker sample rate','eyetracker tracking'},...
    {'git_commit','viewing_distance','screen_size','screen_resolution','FPS','eyetracker_rate','eye_tracked'});



%For trial map
time_events = containers.Map( {'Start', 'Fixation point on','Fixation point off','Reward end','Target 1 presented','Target 2 presented','Targets off',...
    'Fixation acquired','Broke fixation','Target 1 acquired','Target 2 acquired'}, ...
    {'Start','Fixation_point_on','Fixation_point_off','Reward_end','Target_1_presented','Target_2_presented','Targets_off',...
    'Fixation_acquired','Broke_fixation','Choicetime','Choicetime'} ...
);

segment_events = containers.Map( {'Experiment','Fixation color','Target 1 color','Target 2 color'},...
    {'Task','Fixation_color','Target_1_color','Target_2_color'});

information_events = containers.Map( ...
    {'Fixation position','Fixation size','Fixation acceptance window'...
       'Target 1 size','Target 1 acceptance window','Requested fixation hold time',...
       'Requested timeout','Requested time between trials',...
       'Target 1 position','Target 1 size','Target 1 acceptance window','Requested fixation duration',...
       'Requested target 1 hold time','Requested target 2 hold time'...
       'Target 2 position','Target 2 size','Target 2 acceptance window',...
       'Requested target 1 duration','Requested target 2 time offset',...
       'Requested target 1 timeout','Requested penalty box duration',...
       'Reward start','Requested target dim opacity'
       
       },...
    {'Fixation_position','Fixation_size','Fixation_acceptance_window' ...
    'Target_1_size','Target_1_acceptance_window','Requested_fixation_hold_time',...
    'Requested_timeout','Requested_time_between_trials',...
    'Target_1_position','Target_1_size','Target_1_acceptance_window','Requested_fixation_duration',...
    'Requested_target_1_hold_time','Requested_target_2_hold_time'...
    'Target_2_position','Target_2_size','Target_2_acceptance_window',...
    'Requested_target_1_duration','Requested_target_2_time_offset',...
    'Requested_target_1_timeout','Requested_penalty_box_duration',...
    'Reward_start','Requested_target_dim_opacity'
    });

    dash_events = {'End','Correct choice','Wrong choice'};
    outcome_events = {'Correct choice','No choice','Wrong choice'};

    

 EventsNumber = size(Events,1); 


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
        if isnan(experiment.(exp_marker))
            experiment.(exp_marker) = curr_eventtime;
            
        end

        %Saved meta data
        exp_token = strtrim(exp_flag{1}{2});
        if startsWith(exp_token,'git commit')
            experiment.git_commit = strtrim(strrep(exp_token,'git commit',''));
        elseif startsWith(exp_token,'eyetracker tracking')
            eye_tokens = strtrim(regexp(exp_token,'eyetracker tracking (\w+)','tokens'));
            experiment.eye_tracked = eye_tokens{1}{1};
        else
            %Numeric data
           num_tokens = regexp(exp_token, ...
            '^\s*(.*?)\s+(\d+\.?\d*)\D*(\d+\.?\d*)?', 'tokens');
           event_exp = strtrim(num_tokens{1}{1});
           nums =cellfun(@str2double,num_tokens{1}(2:end));
      

            %nums = str2double(nums_token);  
            exp_event_keys = keys(exp_events);
            flag_array = contains(exp_event_keys,event_exp);
            curr_key = exp_event_keys{flag_array};
            field = exp_events(curr_key);
    
        
            experiment.(field) = nums(~isnan(nums));

        end

       

    else

        %Get trial number and event text
         mainTokens = regexp(curr_event, '^Trial\s+(\d+):\s*(.*)$', 'tokens');    
         TrialNum_curr = str2double(mainTokens{1}{1}); % Get trial number  
         event_text = strtrim(mainTokens{1}{2}); %Get the remaining events
    
        % Define the current trial
        if exist('trials','var') ~= 1 || isempty(trials)
        % if no trials has been defined
        trials = trial;
        trials.Trial_number = TrialNum_curr;
        trial_index = 1;  
        else
        % if there is already a trial structure
        idx = find([trials.Trial_number] == TrialNum_curr, 1);
            if isempty(idx)
                % if not exist, set up a new trial
                trial_index = trial_index + 1;  
                currTrial = trial;
                currTrial.Trial_number = TrialNum_curr;  
               % try
                trials(trial_index) = currTrial;
                %{
                catch
                    disp('Find field mismatch, please debug')
                     s1 = trials(trial_index-1);
                     s2 = currTrial;
                     compare_fields(s1,s2);
       
                    keyboard
                end
                %}
      
            end
        end
    
       %go through each type of events
       time_flag = contains(event_text, keys(time_events));
       info_flag = contains(event_text, keys(information_events));
       seg_flag = contains(event_text, keys(segment_events));
       dash_flag = contains(event_text, dash_events) & contains(event_text, '-');
       outcome_flag = contains(event_text, outcome_events);
    
    
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
           time_pattern = '^(.*?)\s+([-+]?\d*\.?\d+)\s*ms$';
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
                    disp('Duplicate vv  found for dash event:');
                    disp(event);
    
               end
    
               if isnan(trials(trial_index).Trialoutcome)
                    trials(trial_index).Trialoutcome = outcome;
               else
                   trials(trial_index).duplicates(end+1,1) ='Trialoutcome';
                    disp('Duplicate found for dash event:');
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

%% Add a few feature for further analysis
%1. Transform Cartesian into Polar for target postion
    Target_1_xy = vertcat(trials.Target_1_position); 
    [theta, Target_1_ecc] = cart2pol(Target_1_xy(:,1),Target_1_xy(:,2));
    Target_1_angle = mod(90 - rad2deg(theta), 360);
    Target_1_angle(Target_1_angle >= 180) = Target_1_angle(Target_1_angle >= 180) - 360;

    Target_2_xy = vertcat(trials.Target_2_position);
    [theta, Target_2_ecc] = cart2pol(Target_2_xy(:,1),Target_2_xy(:,2));
    Target_2_angle = mod(90 - rad2deg(theta), 360);
    Target_2_angle(Target_2_angle >= 180) = Target_2_angle(Target_2_angle >= 180) - 360;   

    stimulus_dir = (Target_1_angle >= 0) * 2 - 1;
 
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
    


%% Export the parsed data into folders

% Set up export path
if ~exist(OutputPath, 'dir')
    mkdir(OutputPath);
end
save(fullfile(OutputPath, OutputFileName), 'experiment', 'trials');

disp(sprintf('File:%s has been parsed into %s',Filename_nev,OutputFileName));



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