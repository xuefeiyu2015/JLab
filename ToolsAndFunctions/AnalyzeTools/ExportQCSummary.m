function [behaviorFile, spikeFile] = ExportQCSummary(quality, savePath)
% Append a quality-check recording to the per-monkey summary CSVs.
%
% Writes two CSVs into a shared Summary folder at the data root, one pair per
% monkey (monkey name in the filename, recording date as a column so many
% recordings accumulate in one file):
%   <Monkey>_behavior_summary.csv - one row per task tested in the recording:
%       Monkey, Date, Task, TotalValidTrials, MinRep, MinRepCondition
%   <Monkey>_spike_summary.csv    - one row per isolated unit:
%       Monkey, Date, Channel, Unit, MeanFiringRate_Hz, BaselineFiringRate_Hz,
%       SNR, P2V_uV, Width_ms, ISIviolation, Fano, PCAratio, Excluded, Reason, Note
%
% Re-exporting a recording replaces that date's rows (upsert). A session with no
% isolated units still updates the behavior CSV but adds nothing to the spike CSV.
%
% Input:
%   quality  - struct from QualityCheck: .spike (per-unit metrics, may be empty)
%              and .behavior (the per-task condition table from behaviorCheck).
%   savePath - the export folder (.../Monkey <name>/.../export_data/<date>); the
%              monkey, date and data root are parsed from it.
%
% Output:
%   behaviorFile, spikeFile - paths written ('' when nothing was written).
%
% Xuefei Yu Jul 2026

    behaviorFile = '';  spikeFile = '';
    if nargin < 2 || isempty(savePath)
        return
    end

    [monkey, dateStr, dataRoot] = parseSessionPath(savePath);
    if isempty(monkey);  monkey = 'unknown';  end
    summaryDir = fullfile(dataRoot, 'Summary');
    if ~exist(summaryDir, 'dir');  mkdir(summaryDir);  end

    % ---------------- behavior CSV (one row per tested task) --------------
    behT = behaviorTable(quality, monkey, dateStr);
    if ~isempty(behT)
        behaviorFile = fullfile(summaryDir, [monkey '_behavior_summary.csv']);
        upsertSummary(behaviorFile, behT, {'Monkey', 'Date', 'Task', 'MinRepCondition'});
    end

    % ---------------- spike CSV (one row per unit; skip when none) --------
    spkT = spikeTable(quality, monkey, dateStr);
    if ~isempty(spkT)
        spikeFile = fullfile(summaryDir, [monkey '_spike_summary.csv']);
        upsertSummary(spikeFile, spkT, {'Monkey', 'Date', 'Reason', 'Note'});
    end
end


function T = behaviorTable(quality, monkey, dateStr)
% Prepend Monkey/Date to the per-task condition table from behaviorCheck.
% behaviorCheck returns that condition table directly (quality.behavior IS the
% table); its exact columns are taken as-is, so a rename there needs no change
% here. The text columns for the upsert are named in ExportQCSummary's caller.
    T = table();
    if ~isfield(quality, 'behavior') || ~istable(quality.behavior) || isempty(quality.behavior)
        return
    end
    C = quality.behavior;
    n = height(C);
    meta = table(repmat(string(monkey), n, 1), repmat(string(dateStr), n, 1), ...
        'VariableNames', {'Monkey', 'Date'});
    T = [meta, C];
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
        round(col('violationRate'), 5), round(col('fano'), 3), round(col('pcaRatio'), 3), ...
        double([sp.Excluded]'), string({sp.Reason}'), string({sp.Comment}'), ...
        'VariableNames', {'Monkey', 'Date', 'Channel', 'Unit', 'MeanFiringRate_Hz', ...
            'BaselineFiringRate_Hz', 'SNR', 'P2V_uV', 'Width_ms', 'ISIviolation', ...
            'Fano', 'PCAratio', 'Excluded', 'Reason', 'Note'});
end


function upsertSummary(file, newT, textVars)
% Append newT to file, first dropping any existing rows for the same Monkey+Date.
    if exist(file, 'file') == 2
        old = readExisting(file, textVars);
        old = alignColumns(old, newT.Properties.VariableNames);
        keep = ~(old.Monkey == newT.Monkey(1) & old.Date == newT.Date(1));
        combined = [old(keep, :); newT];
    else
        combined = newT;
    end
    writetable(combined, file);
end


function T = readExisting(file, textVars)
% Read an existing summary CSV with stable types: the named text columns as
% string (so '2026-07-15' is not auto-parsed to datetime), everything else double.
    opts = detectImportOptions(file, 'Delimiter', ',');
    tv = intersect(textVars, opts.VariableNames);
    if ~isempty(tv);  opts = setvartype(opts, tv, 'string');  end
    nv = setdiff(opts.VariableNames, textVars);
    if ~isempty(nv);  opts = setvartype(opts, nv, 'double');  end
    T = readtable(file, opts);
end


function old = alignColumns(old, vn)
% Make old carry exactly the columns vn (same order); fill any new column blank.
    for i = 1:numel(vn)
        if ~ismember(vn{i}, old.Properties.VariableNames)
            old.(vn{i}) = repmat(string(missing), height(old), 1);
        end
    end
    old = old(:, vn);
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
