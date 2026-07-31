function [excludeTask, excludeSpikes] = ScreenSession(BehaviorSummary, SpikeSummary, cfgScreen)
% Screen a session's tasks and units from the behavior and spike QC summaries.
%
% Excludes tasks that collected too few successful trials, and units that either
% fire too slowly or were marked excluded by hand in the spike navigator.
%
%   BehaviorSummary - table from behaviorCheck: needs Task and SuccessfulTrials.
%   SpikeSummary    - table from spikeCheck: needs AvgFR and Excluded. [] when
%                     the session has no spike data.
%   cfgScreen       - (optional) config struct; omitted fields keep the defaults
%                     these thresholds have always had:
%                       .RemoveTaskLessThanTrials - drop tasks with fewer
%                                                   successful trials (default 3)
%                       .RemoveAvgFRLessThan      - drop units below this mean
%                                                   firing rate, Hz (default 1)
%
% Xuefei Yu, July 2026

    if nargin < 3;  cfgScreen = [];  end
    cfgWarnUnknown(cfgScreen, {'RemoveTaskLessThanTrials', 'RemoveAvgFRLessThan'}, ...
        'cfg.Screen');

    RemoveTaskLessThanTrials = cfgField(cfgScreen, 'RemoveTaskLessThanTrials', 3);
    RemoveAvgFRLessThan      = cfgField(cfgScreen, 'RemoveAvgFRLessThan',      1);

    excludeTask   = BehaviorSummary.Task(BehaviorSummary.SuccessfulTrials < RemoveTaskLessThanTrials);
    excludeSpikes = false(size(SpikeSummary, 1), 1);

    if ~isempty(SpikeSummary)
        excludeSpikes = SpikeSummary.AvgFR < RemoveAvgFRLessThan | SpikeSummary.Excluded == true;
    end

end
