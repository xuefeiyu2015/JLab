function [pse, thr, psy, n] = computeSessionPsy(D, rows)
% Logistic psychometric fit over the given rows via VisPsychometricFunction.
% Shared by TimeDiscriminationBehavior and TimeDiscriminationEccentricity.
    n = numel(rows);
    pse = NaN;  thr = NaN;  psy = [];
    if n < 2;  return;  end
    sd = D.stimulus(rows) .* D.direction(rows);
    if numel(unique(sd)) < 2;  return;  end     % need >=2 signed levels to fit
    psymat = [D.stimulus(rows), D.direction(rows), double(D.choiceLR(rows) == 1)];

    % Small/short windows are often perfectly separable, which makes fitglm warn
    % about non-finite estimates and hit its iteration limit. That case is
    % expected (and flagged below via psy.separable), so mute those two warnings.
    ws = warning;                                       %#ok<WNTAG> full state
    cleanup = onCleanup(@() warning(ws));
    warning('off', 'stats:glmfit:PerfectSeparation');
    warning('off', 'stats:glmfit:IterationLimit');
    try
        [pse, thr, psy] = VisPsychometricFunction(psymat, 0);
        if ~isempty(psy) && psy.separable
            thr = NaN;                           % slope unconstrained -> unreliable
        end
    catch
        pse = NaN;  thr = NaN;  psy = [];
    end
    if abs(pse) >1000
       % Hard up level
       % the pse is meaningless if above this value
       pse = NaN;
    end
    if thr >1000 
       % Hard up level
       % the thr is meaningless if above this value
       thr = NaN;
    end
end
