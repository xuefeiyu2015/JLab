function reportPreprocessStage(idx, total, label)
% Print the banner that opens one preprocessing stage.
%
% Same '===== ... =====' shape BackRockFileLoader.m uses for its per-folder
% progress, so both drivers read alike.
%
% The banner is the DRIVER's job, not the wrapper's: only the driver knows a
% block's position in the cascade. Each Prepare* wrapper prints its own indented
% status line underneath (see describeBlockPlan), because only the wrapper knows
% whether its exported file ended up being read. That split is also what lets a
% wrapper stay useful when called standalone for debugging -- it still reports,
% just without the numbering.
%
%   idx   - 1-based position of this stage.
%   total - number of stages in the cascade.
%   label - stage name, e.g. 'Eye calibration'.
%
% Xuefei Yu 2026

    fprintf('\n===== [%d/%d] %s =====\n', idx, total, label);
end
