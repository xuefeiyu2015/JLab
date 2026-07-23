function summaryFile = ExportTaskAnalysisSummary(unitParams, savePath)
% Merge one task's per-unit analysis parameters into the per-monkey master
% analysis summary CSV, shared across every spike-analysis task.
%
% Unlike the QC summary (ExportQCSummary), which carries fixed spike-quality
% columns, this master is task-agnostic: each analysis protocol (RF mapping,
% memory-saccade tuning, ...) contributes its own parameter columns for its units,
% and they coexist in ONE file keyed by Monkey/Date/Task/Channel/Unit. A task whose
% columns are new is unioned in; rows from earlier tasks/dates are back-filled (NaN
% for numeric, blank for string columns). Re-exporting a (Monkey, Date, Task) block
% replaces just that block (upsert), so re-running a protocol is idempotent.
%
%   <dataRoot>/Summary/<Monkey>_analysis_summary.csv
%
% Input:
%   unitParams - table, one row per unit, with the key columns Monkey, Date, Task,
%                Channel, Unit, then any number of numeric/string parameter columns,
%                and (by convention) a trailing Note column. The Monkey/Date should
%                match parseSessionPath(savePath); they are trusted as given.
%   savePath   - the export folder (.../Monkey <name>/.../<date>); the data root is
%                parsed from it to locate the shared Summary folder. '' disables.
%
% Output:
%   summaryFile - master path written ('' when nothing was written).
%
% Text columns (kept as string on read-back so labels/dates are not auto-parsed):
% Monkey, Date, Task, Note, and any column whose name ends in '_Align'.
%
% Xuefei Yu Jul 2026

    summaryFile = '';
    if nargin < 2 || isempty(savePath) || isempty(unitParams) || height(unitParams) == 0
        return
    end

    [~, ~, dataRoot] = parseSessionPath(savePath);

    summaryDir = fullfile(dataRoot, 'Summary');
    if ~exist(summaryDir, 'dir');  mkdir(summaryDir);  end
    monkey = char(unitParams.Monkey(1));
    if isempty(monkey);  monkey = 'unknown';  end
    summaryFile = fullfile(summaryDir, [monkey '_analysis_summary.csv']);

    upsertSummary(summaryFile, unitParams);
end


% -------------------------------------------------------------------------
% Upsert with a growing column set, keyed by Monkey/Date/Task/Channel/Unit
% -------------------------------------------------------------------------
function upsertSummary(file, newT)
% Append newT after dropping any rows already recorded for this task block
% (same Monkey+Date+Task). Columns a task uses for the first time are appended;
% earlier rows are back-filled (NaN numeric / blank string).
    if exist(file, 'file') == 2
        old = readStable(file);
        vn  = unionVarNames(old.Properties.VariableNames, newT.Properties.VariableNames);
        old = reindexColumns(old, vn);
        new = reindexColumns(newT, vn);
        keep = ~(old.Monkey == new.Monkey(1) & old.Date == new.Date(1) & ...
                 old.Task == new.Task(1));
        combined = [old(keep, :); new];
    else
        combined = newT;
    end
    combined = withSessionIndex(combined);
    writetable(combined, file);
end


function T = withSessionIndex(T)
% Number the recording sessions 1..n as the first column: all rows of a session
% (a Monkey+Date pair) share one index, ordered by Monkey then Date so the index
% runs monotonically down the file and a newly added session slots in by date.
    if ismember('SessionIndex', T.Properties.VariableNames)
        T.SessionIndex = [];
    end
    T   = sortrows(T, {'Monkey', 'Date', 'Task', 'Channel', 'Unit'});
    key = T.Monkey + "|" + T.Date;
    [~, ~, ic] = unique(key, 'stable');
    T.SessionIndex = ic;
    vn = T.Properties.VariableNames;
    T  = T(:, ['SessionIndex', vn(~strcmp(vn, 'SessionIndex'))]);
end


function vn = unionVarNames(oldNames, newNames)
% Existing columns keep their order; genuinely new columns are appended.
    extra = newNames(~ismember(newNames, oldNames));
    vn    = [oldNames, extra];
end


function T = reindexColumns(T, vn)
% Give T exactly the columns vn, in that order, adding any it lacks. A missing
% column is filled blank for string columns, NaN for numeric columns.
    for i = 1:numel(vn)
        name = vn{i};
        if ~ismember(name, T.Properties.VariableNames)
            if isTextVar(name)
                T.(name) = repmat(string(missing), height(T), 1);
            else
                T.(name) = nan(height(T), 1);
            end
        end
    end
    T = T(:, vn);
end


function tf = isTextVar(name)
% The string columns of the analysis summary: the fixed key/label/text columns
% plus every alignment-mode column any task might add.
    tf = ismember(name, {'Monkey', 'Date', 'Task', 'Note'}) || endsWith(name, '_Align');
end


function T = readStable(file)
% Read the master CSV with stable types: the string columns as string (so labels
% and dates are not auto-parsed to datetime), every other column as double. Header
% tokens are preserved verbatim so they round-trip through the upsert.
    opts   = detectImportOptions(file, 'Delimiter', ',', 'VariableNamingRule', 'preserve');
    isText = cellfun(@isTextVar, opts.VariableNames);
    tv     = opts.VariableNames(isText);
    nv     = opts.VariableNames(~isText);
    if ~isempty(tv);  opts = setvartype(opts, tv, 'string');  end
    if ~isempty(nv);  opts = setvartype(opts, nv, 'double');  end
    T = readtable(file, opts);
end
