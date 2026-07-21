function tempFile = writeBehaviorSummary(behaviorTable, savePath)
% Write the current session's behavior QC summary to a per-session temp CSV.
%
% The per-task condition table from behaviorCheck is pivoted into a single wide
% row (four columns per task) keyed by Monkey + Date, and written to
%   <dataRoot>/Summary/temp/<Monkey>_<Date>_behavior.csv
% ExportQCSummary later reads this temp (together with the spike temp), merges it
% into the master <Monkey>_qc_summary.csv, and deletes it.
%
% Input:
%   behaviorTable - behaviorCheck's condition table (one row per task, columns
%                   Task/SuccessfulTrials/MinRep/MinRepCondition/SuccessfulRate),
%                   or empty. When empty a Monkey/Date-only row is still written so
%                   the combine knows the behavior check ran.
%   savePath      - the export folder (.../Monkey <name>/.../export_data/<date>);
%                   the monkey, date and data root are parsed from it. '' disables.
%
% Output:
%   tempFile - path written ('' when nothing was written).
%
% Xuefei Yu Jul 2026

    tempFile = '';
    if nargin < 2 || isempty(savePath)
        return
    end

    [monkey, dateStr, dataRoot] = parseSessionPath(savePath);
    if isempty(monkey);  monkey = 'unknown';  end

    key = table(string(monkey), string(dateStr), 'VariableNames', {'Monkey', 'Date'});
    beh = behaviorWide(behaviorTable);
    if isempty(beh)
        T = key;
    else
        T = [key, beh];
    end

    tempDir = fullfile(dataRoot, 'Summary', 'temp');
    if ~exist(tempDir, 'dir');  mkdir(tempDir);  end
    tempFile = fullfile(tempDir, sprintf('%s_%s_behavior.csv', monkey, dateStr));
    writetable(T, tempFile);
end


function T = behaviorWide(C)
% Pivot behaviorCheck's per-task condition table into a single row: four columns
% per task -- <task> (successful trials), <task>_MinRep, <task>_MinRepCond,
% <task>_SuccessRate. Empty table when there is no behavior data.
    T = table();
    if ~istable(C) || isempty(C)
        return
    end
    vals  = {};
    names = {};
    for i = 1:height(C)
        tok = matlab.lang.makeValidName(regexprep(char(C.Task(i)), '\W', '_'));
        vals(end+1)  = { double(C.SuccessfulTrials(i)) };         %#ok<AGROW>
        names(end+1) = { tok };                                   %#ok<AGROW>
        vals(end+1)  = { double(C.MinRep(i)) };                   %#ok<AGROW>
        names(end+1) = { [tok '_MinRep'] };                       %#ok<AGROW>
        vals(end+1)  = { string(C.MinRepCondition(i)) };          %#ok<AGROW>
        names(end+1) = { [tok '_MinRepCond'] };                   %#ok<AGROW>
        vals(end+1)  = { round(double(C.SuccessfulRate(i)), 3) }; %#ok<AGROW>
        names(end+1) = { [tok '_SuccessRate'] };                  %#ok<AGROW>
    end
    T = table(vals{:}, 'VariableNames', names);
end
