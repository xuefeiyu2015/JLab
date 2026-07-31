function BehaviorSummary = PrepareBehavior(comments_data, cfgBehavior, savePath)
% Preprocessing block: behavior QC.
%
% Thin wrapper over behaviorCheck that unpacks one config struct. This block
% reads no exported file of its own -- the trials table is the analyzer's single
% eager load and every block gets it -- so it has no KeepFullFile option and
% nothing to release.
%
%   comments_data - the parsed trials table.
%   cfgBehavior   - config struct (cfg.Behavior):
%                     .Plot      - draw the behavior summary figure
%                     .ReCompute - true recomputes and refreshes
%                                  <savePath>/AnalysisCache/BehaviorSummary.mat;
%                                  false loads it
%                   An omitted field falls through to behaviorCheck's own default.
%   savePath      - session export folder ('' disables caching/export).
%
% Returns BehaviorSummary, the per-task conditions table (Task,
% TotalValidTrials, MinRep, MinRepCondition, SuccessfulTrials).
%
% Xuefei Yu 2026

    if nargin < 2;  cfgBehavior = [];  end
    if nargin < 3;  savePath    = '';  end

    cfgWarnUnknown(cfgBehavior, {'Plot', 'ReCompute'}, 'cfg.Behavior');

    % behaviorCheck defaults plotFlag to true, so say so when the field is absent.
    fprintf('  %s\n', describeBlockPlan(cfgBehavior, savePath, 'BehaviorSummary', ...
        '.mat', struct('PlotDefault', true)));

    BehaviorSummary = behaviorCheck(comments_data, ...
        cfgField(cfgBehavior, 'Plot',      []), savePath, ...
        cfgField(cfgBehavior, 'ReCompute', []));
end
