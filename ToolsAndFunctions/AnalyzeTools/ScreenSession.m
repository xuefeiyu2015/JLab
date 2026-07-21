function [excludeTask, excludeSpikes] = ScreenSession(BehaviorSummary,SpikeSummary);
% Function to excludeTrials and spikes 
% Now I only exclude trials from tasks with less than 3 trials and spikes
% with an average firing rate less than 1 Hz, and also those included in
% the exclude 
% Xuefei Yu, July 2026

excludeTask = []; 
excludeSpikes = zeros(size(SpikeSummary,1));

RemoveTaskLessThanTrials = 3; %Remove tasks with less than 3 successful trials
RemoveAvgFRLessThan = 1; %in Hz Remove neurons with average firing rate less than 1Hz

excludeTask = BehaviorSummary.Task(BehaviorSummary.SuccessfulTrials <RemoveTaskLessThanTrials);
excludeSpikes = SpikeSummary.AvgFR < RemoveAvgFRLessThan | SpikeSummary.Excluded == true;




end