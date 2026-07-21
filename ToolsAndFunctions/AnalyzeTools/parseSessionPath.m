function [monkey, dateStr, dataRoot] = parseSessionPath(savePath)
% Pull the monkey name, recording date and data root from an export path of the
% documented shape .../<dataRoot>/Monkey <name>/<loc>/<datatype>/<date>.
%
%   monkey   - text after 'Monkey ' in the last 'Monkey <name>' folder ('' if none).
%   dateStr  - the last path component (the recording date folder).
%   dataRoot - everything above the 'Monkey <name>' folder (one level up as a
%              fallback when no such folder is found).
%
% Shared by ExportQCSummary, writeBehaviorSummary and writeSpikeSummary so the
% per-session temp files and the master CSV all key on the same Monkey/Date.
%
% Xuefei Yu Jul 2026

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
