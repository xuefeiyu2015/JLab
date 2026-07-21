function summaryFile = ExportQCSummary(quality, savePath)
% Append a quality-check recording to the per-monkey combined summary CSV.
%
% Writes ONE CSV into a shared Summary folder at the data root, one per monkey
% (monkey name in the filename, recording date as a column so many recordings
% accumulate in one file):
%   <Monkey>_qc_summary.csv - one row per isolated unit, carrying both the
%       per-unit spike metrics and the session's behavior summary. The behavior
%       summary is pivoted wide by task and repeated onto every unit row, so a
%       recording's rows all share the same behavior columns:
%         spike    : Monkey, Date, Channel, Unit, MeanFiringRate_Hz,
%                    BaselineFiringRate_Hz, SNR, P2V_uV, Width_ms, ISIviolation,
%                    PCAratio, Excluded, Reason, Note
%         behavior : four columns per task <T> (from behaviorCheck's condition
%                    table) - <T> (successful trials), <T>_MinRep,
%                    <T>_MinRepCond, <T>_SuccessRate
%
% A session with no isolated units still writes one behavior-only row (the spike
% columns left NaN/blank). Re-exporting a recording replaces that date's rows
% (upsert). A task appearing for the first time adds new columns; the rows of
% earlier recordings are back-filled (NaN for the numeric columns, blank for the
% min-rep condition string).
%
% Input:
%   quality  - struct from QualityCheck: .spike (per-unit metrics, may be empty)
%              and .behavior (the per-task condition table from behaviorCheck).
%   savePath - the export folder (.../Monkey <name>/.../export_data/<date>); the
%              monkey, date and data root are parsed from it.
%
% Output:
%   summaryFile - path written ('' when nothing was written).
%
% Xuefei Yu Jul 2026

    summaryFile = '';
    if nargin < 2 || isempty(savePath)
        return
    end

    [monkey, dateStr, dataRoot] = parseSessionPath(savePath);
    if isempty(monkey);  monkey = 'unknown';  end

    newT = combinedTable(quality, monkey, dateStr);
    if isempty(newT)
        return
    end

    summaryDir = fullfile(dataRoot, 'Summary');
    if ~exist(summaryDir, 'dir');  mkdir(summaryDir);  end
    summaryFile = fullfile(summaryDir, [monkey '_qc_summary.csv']);
    upsertSummary(summaryFile, newT);
end


function T = combinedTable(quality, monkey, dateStr)
% One row per isolated unit (spike metrics) with the session's behavior summary
% repeated onto each row. A session with no units still yields a single
% behavior-only row (spike columns blank). Empty when there is neither spike nor
% behavior data.
    spk = spikeTable(quality, monkey, dateStr);   % 0..n unit rows
    beh = behaviorWide(quality);                  % 1-row task columns, or empty

    if isempty(spk) && isempty(beh)
        T = table();
        return
    end
    if isempty(spk)
        spk = blankSpikeRow(monkey, dateStr);     % single NaN/blank unit row
    end
    if isempty(beh)
        T = spk;
    else
        T = [spk, repmat(beh, height(spk), 1)];
    end
end


% -------------------------------------------------------------------------
% Spike columns (one schema, used by both the unit rows and the blank row)
% -------------------------------------------------------------------------
function names = spikeVarNames()
    names = {'Monkey', 'Date', 'Channel', 'Unit', 'MeanFiringRate_Hz', ...
        'BaselineFiringRate_Hz', 'SNR', 'P2V_uV', 'Width_ms', 'ISIviolation', ...
        'PCAratio', 'Excluded', 'Reason', 'Note'};
end


function T = spikeTable(quality, monkey, dateStr)
% One row per unit; empty table when the session has no isolated units.
    T = table();
    if ~isfield(quality, 'spike') || isempty(quality.spike)
        return
    end
    sp = quality.spike;
    n  = numel(sp);
    col = @(f) double([sp.(f)]');
    T = table( ...
        repmat(string(monkey), n, 1), repmat(string(dateStr), n, 1), ...
        col('Channel'), col('Unit'), ...
        round(col('overallRate'), 3), round(col('baselineMeanRate'), 3), ...
        round(col('snr'), 3), round(col('peakToValley'), 2), round(col('widthMs'), 4), ...
        round(col('violationRate'), 5), round(col('pcaRatio'), 3), ...
        double([sp.Excluded]'), string({sp.Reason}'), string({sp.Comment}'), ...
        'VariableNames', spikeVarNames());
end


function T = blankSpikeRow(monkey, dateStr)
% A single unit row for a session with no isolated units: spike metrics NaN,
% text columns blank, only Monkey/Date filled in.
    names = spikeVarNames();
    vals  = cell(1, numel(names));
    for i = 1:numel(names)
        if isTextVar(names{i})
            vals{i} = string(missing);
        else
            vals{i} = NaN;
        end
    end
    T = table(vals{:}, 'VariableNames', names);
    T.Monkey = string(monkey);
    T.Date   = string(dateStr);
end


% -------------------------------------------------------------------------
% Behavior columns: the per-task condition table pivoted into one wide row
% -------------------------------------------------------------------------
function T = behaviorWide(quality)
% Pivot behaviorCheck's per-task condition table into a single row: four columns
% per task -- <task> (successful trials), <task>_MinRep, <task>_MinRepCond,
% <task>_SuccessRate. Empty table when there is no behavior data.
    T = table();
    if ~isfield(quality, 'behavior') || ~istable(quality.behavior) || isempty(quality.behavior)
        return
    end
    C     = quality.behavior;
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


% -------------------------------------------------------------------------
% Upsert with a growing column set
% -------------------------------------------------------------------------
function upsertSummary(file, newT)
% Append newT to file after dropping any rows already recorded for this
% Monkey+Date. Columns for a task not seen before are appended; the rows of
% earlier recordings are back-filled (NaN for numeric, blank for string columns).
    if exist(file, 'file') == 2
        old = readExisting(file);
        vn  = unionVarNames(old.Properties.VariableNames, newT.Properties.VariableNames);
        old = reindexColumns(old, vn);
        new = reindexColumns(newT, vn);
        keep = ~(old.Monkey == new.Monkey(1) & old.Date == new.Date(1));
        combined = [old(keep, :); new];
    else
        combined = newT;
    end
    writetable(combined, file);
end


function vn = unionVarNames(oldNames, newNames)
% Existing columns keep their order; genuinely new columns are appended.
    extra = newNames(~ismember(newNames, oldNames));
    vn    = [oldNames, extra];
end


function T = reindexColumns(T, vn)
% Give T exactly the columns vn, in that order, adding any it lacks. A missing
% column is filled blank for the string columns (Monkey/Date/Reason/Note and the
% per-task *_MinRepCond), NaN for every numeric column.
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
% The string columns of the combined table: the fixed spike text columns plus
% every per-task min-rep condition label.
    tf = ismember(name, {'Monkey', 'Date', 'Reason', 'Note'}) || ...
         endsWith(name, '_MinRepCond');
end


function T = readExisting(file)
% Read an existing summary CSV with stable types: the string columns
% (Monkey/Date/Reason/Note and the per-task *_MinRepCond) as string so labels and
% dates are not auto-parsed to datetime, every other column as double. Header
% tokens are preserved verbatim so they round-trip through the upsert.
    opts   = detectImportOptions(file, 'Delimiter', ',', 'VariableNamingRule', 'preserve');
    isText = cellfun(@isTextVar, opts.VariableNames);
    tv     = opts.VariableNames(isText);
    nv     = opts.VariableNames(~isText);
    if ~isempty(tv);  opts = setvartype(opts, tv, 'string');  end
    if ~isempty(nv);  opts = setvartype(opts, nv, 'double');  end
    T = readtable(file, opts);
end


function [monkey, dateStr, dataRoot] = parseSessionPath(savePath)
% Pull the monkey name, recording date and data root from an export path of the
% documented shape .../<dataRoot>/Monkey <name>/<loc>/<datatype>/<date>.
    sp = char(savePath);
    if endsWith(sp, filesep);  sp = sp(1:end-1);  end
    parts   = strsplit(sp, filesep);
    dateStr = parts{end};
    idx     = find(startsWith(parts, 'Monkey '), 1, 'last');
    if isempty(idx)
        monkey   = '';
        dataRoot = fileparts(sp);          % fallback: one level up
    else
        monkey   = strtrim(extractAfter(parts{idx}, 'Monkey'));
        dataRoot = strjoin(parts(1:idx-1), filesep);
    end
end
