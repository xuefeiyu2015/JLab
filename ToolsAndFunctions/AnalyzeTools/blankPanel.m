function blankPanel(ax, varargin)
% An axes that says why it has nothing to show, rather than an empty box the
% reader has to guess at. Takes sprintf arguments.
%
% Draw-only utility, shared by behaviorCheck.m and QualityCheck.m's spike panels.
%
% Xuefei Yu Jul 2026
    text(ax, 0.5, 0.5, sprintf(varargin{:}), 'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle');
    axis(ax, 'off');
end
