function RT = CalculateRT(caled_eyes,comments_data);
%Function to caluclate the real reaction time
%

tasks_for_RT = {'visual_saccades_experiment','memory_saccades_experiment','time_delay_experiment'};
isValid = contains([comments_data.Task],tasks_for_RT) & strcmp([comments_data.Trialoutcome],'correct')| strcmp([comments_data.Trialoutcome],'wrong');

RT_data = NaN * ones(size(comments_data,1),1);
realRT = false;

if isempty(caled_eyes)
    disp('no eye data found, use approximate RT by FixationExit marker');
    saccade_on = [comments_data.Fixation_exited];
    fixation_off = [comments_data.Fixation_point_off];
    RT_data = fixation_off - saccade_on; % Calculate reaction times based on fixation markers
    
    RT_data(~isValid) = NaN;

   fprintf('%d approximate RT computed based on FixExit marker\n', ...
    sum(~isnan(RT_data)));

else
    %Calculate realRT based on the caled_eyes

    eye_x =squeeze(caled_eyes.data(1,:,:));
    eye_y = squeeze(caled_eyes.data(2,:,:));
     eye_time = caled_eyes.timeseq.relative_time;    
    

    %First align eye trace relative to the fixation offset

    % Go cue (fixation offset) time in the same frame as eye_time.
    marker_time = [comments_data.Fixation_point_off] - [comments_data.Start];   % nTrials x 1, s
    eye_preMs = 500; % in ms
    eye_postMs = 500; %in ms

    % Align every trace to the go cue over [-preMs, +postMs].
    [aligned_eye, rts] = AlignEyeTrace(eye_x, eye_y, eye_time, ...
             marker_time, eye_preMs, eye_postMs);

    eye_x_for_RT = aligned_eye.x(isValid,:);
    eye_y_for_RT = aligned_eye.y(isValid,:);


    keyboard




    %{
  %  eye_x = caled_eyes.data
        [aligned_eye, rts] = AlignEyeTrace(eye_x, eye_y, eye_time, ...
             marker_time, eye_preMs, eye_postMs);

    %}
    keyboard



end

RT.data = RT_data;
RT.realRT = realRT;


end