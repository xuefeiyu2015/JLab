function tempFile = writeSpikeSummary(S, savePath)
% Write the current session's per-unit spike QC metrics to a per-session temp CSV.
%
% One row per isolated unit (Monkey/Date key + the spike metrics), written to
%   <dataRoot>/Summary/temp/<Monkey>_<Date>_spike.csv
% The file is always written, even with zero units (header only), so the combine
% step can tell "spike check ran, no units" apart from "spike check never ran".
% ExportQCSummary later reads this temp (together with the behavior temp), merges
% it into the master <Monkey>_qc_summary.csv, and deletes it.
%
% Input:
%   S        - per-unit struct array from spikeCheck (fields Channel, Unit,
%              overallRate, baselineMeanRate, violationRate, snr, widthMs,
%              peakToValley, pcaRatio, Excluded, Reason, Note), or empty.
%   savePath - the export folder (.../Monkey <name>/.../export_data/<date>); the
%              monkey, date and data root are parsed from it. '' disables.
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

    T = spikeTable(S, monkey, dateStr);

    tempDir = fullfile(dataRoot, 'Summary', 'temp');
    if ~exist(tempDir, 'dir');  mkdir(tempDir);  end
    tempFile = fullfile(tempDir, sprintf('%s_%s_spike.csv', monkey, dateStr));
    writetable(T, tempFile);
end


function names = spikeVarNames()
    names = {'Monkey', 'Date', 'Channel', 'Unit', 'MeanFiringRate_Hz', ...
        'BaselineFiringRate_Hz', 'SNR', 'P2V_uV', 'Width_ms', 'ISIviolation', ...
        'ClusterRatio', 'Excluded', 'Reason', 'Note'};
end


function T = spikeTable(sp, monkey, dateStr)
% One row per unit; a zero-row typed table when the session has no isolated units.
    names = spikeVarNames();
    if isempty(sp)
        types = repmat({'double'}, 1, numel(names));
        types(ismember(names, {'Monkey', 'Date', 'Reason', 'Note'})) = {'string'};
        T = table('Size', [0 numel(names)], 'VariableTypes', types, ...
            'VariableNames', names);
        return
    end
    n   = numel(sp);
    col = @(f) double([sp.(f)]');
    T = table( ...
        repmat(string(monkey), n, 1), repmat(string(dateStr), n, 1), ...
        col('Channel'), col('Unit'), ...
        round(col('overallRate'), 3), round(col('baselineMeanRate'), 3), ...
        round(col('snr'), 3), round(col('peakToValley'), 2), round(col('widthMs'), 4), ...
        round(col('violationRate'), 5), round(col('pcaRatio'), 3), ...
        double([sp.Excluded]'), string({sp.Reason}'), string({sp.Note}'), ...
        'VariableNames', names);
end
