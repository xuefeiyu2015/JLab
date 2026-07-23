function T = SpikeTrialAlignmentCheck(spike, cd, markers)
% Pair each spike-raster trial with its trials-table row and pull per-trial task,
% outcome and the caller-requested timing markers.
%
% The match is by (Session, Trial_number) rather than by position, so a mismatch
% in ordering or a dropped trial can never silently mislabel a unit's spikes.
% Reusable prep for any per-trial spike analysis (raster or waveform product).
%
% Input:
%   spike   - online_spike-style product with .info.Session / .info.Trial_number
%             (one entry per raster trial).
%   cd      - trials table (Task, Trialoutcome, timing-marker columns).
%   markers - (optional) cellstr / string array of trials-table column names to
%             pull as timing markers. Each becomes a field of T named exactly as
%             the column (e.g. 'Fixation_acquired' -> T.Fixation_acquired). When
%             omitted or empty, no marker fields are added.
%
% Output struct T (all fields nTrials x 1, indexed by spike-raster trial):
%   .valid   - logical, trial matched a trials-table row
%   .task    - task string ('' when unmatched)
%   .success - logical, outcome is 'correct' or 'wrong'
%   .outcome - raw trial outcome string ('' when unmatched), so callers that need
%              the specific outcome (e.g. 'correct' only) are not limited to the
%              correct-or-wrong .success collapse
%   .<marker> - one field per requested marker, marker time (abs s), NaN if the
%               column or value is absent
%
% Xuefei Yu Jul 2026

    if nargin < 3;  markers = {};  end
    markers = cellstr(markers);

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
    T.outcome = oc;

    % Timing markers (abs seconds), one like-named field each; NaN where a column
    % or value is missing.
    for k = 1:numel(markers)
        T.(markers{k}) = mapTrialCol(cd, markers{k}, loc, valid, ns);
    end
end


function v = mapTrialCol(cd, name, loc, valid, ns)
% One trials-table numeric column, scattered onto the spike-trial index; NaN when
% the column is absent.
    v = nan(ns, 1);
    if ismember(name, cd.Properties.VariableNames)
        v(valid) = cd.(name)(loc(valid));
    end
end
