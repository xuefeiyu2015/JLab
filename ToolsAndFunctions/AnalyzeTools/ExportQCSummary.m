function summaryFile = ExportQCSummary(savePath)
% Combine a session's per-session QC temp files into the per-monkey master summary.
%
% Reads the two per-session temp CSVs written earlier by the behavior and spike
% checks, from <dataRoot>/Summary/temp/:
%   <Monkey>_<Date>_behavior.csv - one wide row (four columns per task) keyed by
%                                  Monkey/Date, from writeBehaviorSummary.
%   <Monkey>_<Date>_spike.csv    - one row per isolated unit (spike metrics) keyed
%                                  by Monkey/Date, from writeSpikeSummary.
%
% Merges them into ONE master CSV in a shared Summary folder at the data root, one
% per monkey (recording date as a column so many recordings accumulate in one file):
%   <Monkey>_qc_summary.csv - one row per isolated unit, carrying both the per-unit
%       spike metrics and the session's behavior summary repeated onto every unit
%       row:
%         spike    : Monkey, Date, Channel, Unit, MeanFiringRate_Hz,
%                    BaselineFiringRate_Hz, SNR, P2V_uV, Width_ms, ISIviolation,
%                    ClusterRatio, Excluded, Reason, Note
%         behavior : four columns per task <T> - <T> (successful trials),
%                    <T>_MinRep, <T>_MinRepCond, <T>_SuccessRate
%
% A session with no isolated units still writes one behavior-only row (spike columns
% NaN/blank). Re-exporting a recording replaces that date's rows (upsert). A task
% appearing for the first time adds new columns; earlier recordings are back-filled
% (NaN for numeric columns, blank for string columns). The two temp files are
% deleted once the master has been written.
%
% Input:
%   savePath - the export folder (.../Monkey <name>/.../export_data/<date>); the
%              monkey, date and data root are parsed from it.
%
% Output:
%   summaryFile - master path written ('' when nothing was written).
%
% Xuefei Yu Jul 2026

    summaryFile = '';
    if nargin < 1 || isempty(savePath)
        return
    end

    [monkey, dateStr, dataRoot] = parseSessionPath(savePath);
    if isempty(monkey);  monkey = 'unknown';  end

    tempDir      = fullfile(dataRoot, 'Summary', 'temp');
    behaviorTemp = fullfile(tempDir, sprintf('%s_%s_behavior.csv', monkey, dateStr));
    spikeTemp    = fullfile(tempDir, sprintf('%s_%s_spike.csv', monkey, dateStr));

    newT = combinedTable(behaviorTemp, spikeTemp, monkey, dateStr);
    if isempty(newT)
        return
    end

    summaryDir = fullfile(dataRoot, 'Summary');
    if ~exist(summaryDir, 'dir');  mkdir(summaryDir);  end
    summaryFile = fullfile(summaryDir, [monkey '_qc_summary.csv']);
    upsertSummary(summaryFile, newT);

    % Temp files are consumed: drop them once merged into the master.
    if exist(behaviorTemp, 'file') == 2;  delete(behaviorTemp);  end
    if exist(spikeTemp, 'file') == 2;      delete(spikeTemp);     end
end


function T = combinedTable(behaviorTemp, spikeTemp, monkey, dateStr)
% One row per isolated unit (from the spike temp) with the session's behavior
% summary (from the behavior temp) repeated onto each row. A session with no units
% still yields a single behavior-only row (spike columns blank). Empty when neither
% temp file holds usable data.
    spk = readSpikeTemp(spikeTemp);        % 0..n unit rows, with Monkey/Date
    beh = readBehaviorTemp(behaviorTemp);  % 1-row task columns (no Monkey/Date), or empty

    if isempty(spk) && isempty(beh)
        T = table();
        return
    end
    if isempty(spk)
        spk = blankSpikeRow(monkey, dateStr);   % single NaN/blank unit row
    end
    if isempty(beh)
        T = spk;
    else
        T = [spk, repmat(beh, height(spk), 1)];
    end
end


% -------------------------------------------------------------------------
% Read the per-session temp files
% -------------------------------------------------------------------------
function T = readSpikeTemp(file)
% The unit rows written by writeSpikeSummary. Empty when the file is absent or
% holds zero units (spike check ran but isolated nothing).
    T = table();
    if exist(file, 'file') ~= 2
        return
    end
    T = readStable(file);
    if height(T) == 0
        T = table();
    end
end


function beh = readBehaviorTemp(file)
% The wide behavior row written by writeBehaviorSummary, with the Monkey/Date key
% columns stripped (the spike side already carries them). Empty when the file is
% absent or holds only the Monkey/Date key (behavior check produced no tasks).
    beh = table();
    if exist(file, 'file') ~= 2
        return
    end
    T = readStable(file);
    keep = ~ismember(T.Properties.VariableNames, {'Monkey', 'Date'});
    if ~any(keep) || height(T) == 0
        return
    end
    beh = T(1, keep);
end


% -------------------------------------------------------------------------
% Spike columns (schema for the blank row and the read-back type map)
% -------------------------------------------------------------------------
function names = spikeVarNames()
    names = {'Monkey', 'Date', 'Channel', 'Unit', 'MeanFiringRate_Hz', ...
        'BaselineFiringRate_Hz', 'SNR', 'P2V_uV', 'Width_ms', 'ISIviolation', ...
        'ClusterRatio', 'Excluded', 'Reason', 'Note'};
end


function T = blankSpikeRow(monkey, dateStr)
% A single unit row for a session with no isolated units: spike metrics NaN, text
% columns blank, only Monkey/Date filled in.
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
% Upsert with a growing column set
% -------------------------------------------------------------------------
function upsertSummary(file, newT)
% Append newT to file after dropping any rows already recorded for this
% Monkey+Date. Columns for a task not seen before are appended; the rows of
% earlier recordings are back-filled (NaN for numeric, blank for string columns).
    if exist(file, 'file') == 2
        old = readStable(file);
        vn  = unionVarNames(old.Properties.VariableNames, newT.Properties.VariableNames);
        old = reindexColumns(old, vn);
        new = reindexColumns(newT, vn);
        keep = ~(old.Monkey == new.Monkey(1) & old.Date == new.Date(1));
        combined = [old(keep, :); new];
    else
        combined = newT;
    end
    combined = withSessionIndex(combined);
    writetable(combined, file);
end


function T = withSessionIndex(T)
% Number the recording sessions 1..n as the first column: all unit rows of a
% session (a Monkey+Date pair) share one index. Rows are ordered by Monkey then
% Date so the index runs monotonically down the file (stable within a session),
% and it is recomputed on every write so a newly added session slots in by date.
    if ismember('SessionIndex', T.Properties.VariableNames)
        T.SessionIndex = [];
    end
    T   = sortrows(T, {'Monkey', 'Date'});
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
% The string columns of the combined and temp tables: the fixed spike text columns
% plus every per-task min-rep condition label.
    tf = ismember(name, {'Monkey', 'Date', 'Reason', 'Note'}) || ...
         endsWith(name, '_MinRepCond');
end


function T = readStable(file)
% Read a summary/temp CSV with stable types: the string columns
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
