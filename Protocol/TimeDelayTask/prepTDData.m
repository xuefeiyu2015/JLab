function D = prepTDData(d)
% Filter the events table to valid trials and index them by session. The events
% table arrives pre-scoped to the time-delay task (SetupDataForTask), so only the
% analysis-specific validity screening is applied here.
% Shared by TimeDiscriminationBehavior and TimeDiscriminationEccentricity.
    ev = d.comments;
    saved       = ev.Save_complete == 1;
    validChoice = ~isnan(ev.Choose_target);
    validMask   = saved & validChoice;

    %D.totalTrials = max(ev.Trial_number);         % clamp upper bound (whole recording)
    %D.minTrial    = min(ev.Trial_number);         % clamp lower bound (may be 0-indexed)
    D.totalTrials = sum(validMask);         % clamp upper bound (whole recording)
    D.minTrial    = 1;         % clamp lower bound 

    %Screen out valid trials
    ev = ev(validMask,:);

    D.trialNum    = [1:sum(validMask)]';
    D.stimulus    = ev.Requested_target_2_time_offset;
    D.direction   = ev.Stimulus_direction;
    D.choiceLR    = ev.Choose_leftright;          % -1 = left, 1 = right

    % Per-trial correctness (repo-wide convention: the Trialoutcome string). After
    % the Save_complete/valid-choice screen above, trials are correct or wrong only.
    if ismember('Trialoutcome', ev.Properties.VariableNames)
        D.correct = strcmp(string(ev.Trialoutcome), 'correct');   % normalizes cell/char/categorical
    else
        D.correct = D.choiceLR == D.direction;                    % geometric fallback
    end


    if ismember('RTtime', ev.Properties.VariableNames)
        disp('Use real RT estimated by eyemovement.');
        D.saccade = ev.RTtime;
    else
        disp('Use approximate RT by the comments marker.');
        hasRT = ismember('Choicetime', ev.Properties.VariableNames) && ...
            ismember('Fixation_point_off', ev.Properties.VariableNames);
        if hasRT
            D.saccade = ev.Choicetime - ev.Fixation_point_off;   % seconds
        else
            D.saccade = nan(height(ev), 1);
        end
        

    end

    % Target polar positions (deg; theta 0 = +x, counter-clockwise), as written
    % by BlackrockLoader.targetPolar. NaN when an older export lacks the column.
    polarCols = {'Target_1_rho', 'Target_2_rho', 'Target_1_theta', 'Target_2_theta'};
    polarFlds = {'rho1', 'rho2', 'theta1', 'theta2'};
    hasCol    = ismember(polarCols, ev.Properties.VariableNames);
    for c = 1:numel(polarCols)
        if hasCol(c)
            D.(polarFlds{c}) = ev.(polarCols{c});
        else
            D.(polarFlds{c}) = nan(height(ev), 1);
        end
    end

    sessIds_raw = unique(ev.Session);
    sessIds = [1:length(sessIds_raw)]';
    S = struct('id', {}, 'rows', {}, 'first', {}, 'last', {}, 'endTrial', {});
    for k = 1:numel(sessIds)
        sid  = sessIds_raw(k);
        rows = find(ev.Session == sid);
        tn   = D.trialNum(rows);
        S(k) = struct('id', k, 'rows', rows, 'first', min(tn), ...
                      'last', max(tn), 'endTrial', max(tn));
    end
    D.S = S;
end
