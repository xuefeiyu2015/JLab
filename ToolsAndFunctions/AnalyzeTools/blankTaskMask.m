function mask = blankTaskMask(taskCol)
% Rows whose task name is missing or blank, as a logical column.
%
% A trial can reach the export with no task label at all -- an incomplete trial
% (typically a timeout) that aborted before the task marker was parsed. It has
% no analyzable information, so every per-task product drops it: behaviorCheck
% excludes those trials from the summary, and writeBehaviorSummary refuses to
% give them a column in the shared per-monkey QC summary (an empty name would
% otherwise become a nameless 'x' column group via makeValidName, and once in
% the master CSV that column is permanent).
%
%   taskCol - a task-name column, cellstr or string. The trials table arrives
%             from readtable one way and a cached summary table the other, so
%             both are accepted.
%
% Xuefei Yu 2026

    t    = string(taskCol);
    mask = ismissing(t) | strlength(strtrim(t)) == 0;
    mask = mask(:);
end
