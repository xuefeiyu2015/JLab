function T = alignSpikeTrials(spike, cd)
% Pair each spike-raster trial with its trials-table row and pull per-trial task,
% outcome and timing markers.
%
% The match is by (Session, Trial_number) rather than by position, so a mismatch
% in ordering or a dropped trial can never silently mislabel a unit's spikes.
% Reusable prep for any per-trial spike analysis (raster or waveform product).
%
% Input:
%   spike - online_spike-style product with .info.Session / .info.Trial_number
%           (one entry per raster trial).
%   cd    - trials table (Task, Trialoutcome, timing-marker columns).
%
% Output struct T (all fields nTrials x 1, indexed by spike-raster trial):
%   .valid   - logical, trial matched a trials-table row
%   .task    - task string ('' when unmatched)
%   .success - logical, outcome is 'correct' or 'wrong'
%   .Start .fixAcq .fixOn .fixOff .tgt1 .tgt2 - marker times (abs s), NaN if absent
%
% Xuefei Yu Jul 2026

    ns    = numel(spike.info.Session);
    key_s = [spike.info.Session(:), spike.info.Trial_number(:)];
    key_c = [cd.Session, cd.Trial_number];
    [~, loc] = ismember(key_s, key_c, 'rows');
    valid = loc > 0;

    T.valid   = valid;
    T.task    = repmat({''}, ns, 1);
    T.task(valid) = cellstr(string(cd.Task(loc(valid))));
    oc        = repmat({''}, ns, 1);
    oc(valid) = cellstr(string(cd.Trialoutcome(loc(valid))));
    T.success = strcmp(oc, 'correct') | strcmp(oc, 'wrong');

    % Timing markers (abs seconds), NaN where a column or value is missing.
    T.Start  = mapTrialCol(cd, 'Start',              loc, valid, ns);
    T.fixAcq = mapTrialCol(cd, 'Fixation_acquired',  loc, valid, ns);
    T.fixOn  = mapTrialCol(cd, 'Fixation_point_on',  loc, valid, ns);
    T.fixOff = mapTrialCol(cd, 'Fixation_point_off', loc, valid, ns);
    T.tgt1   = mapTrialCol(cd, 'Target_1_presented', loc, valid, ns);
    T.tgt2   = mapTrialCol(cd, 'Target_2_presented', loc, valid, ns);
end


function v = mapTrialCol(cd, name, loc, valid, ns)
% One trials-table numeric column, scattered onto the spike-trial index; NaN when
% the column is absent.
    v = nan(ns, 1);
    if ismember(name, cd.Properties.VariableNames)
        v(valid) = cd.(name)(loc(valid));
    end
end
