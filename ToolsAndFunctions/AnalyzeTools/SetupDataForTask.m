function data_task = SetupDataForTask(data, task)
% Screen a whole-recording router struct down to a single task's trials, so each
% per-task analysis protocol receives data already scoped to its task (no per-task
% filtering inside the protocol). Every field is scoped -- comments, RT, eyes and
% spike -- so no product is left carrying the whole recording.
%
% Screens by TASK ONLY. Analysis-specific validity screening (correct outcome,
% valid choice, ...) stays inside each protocol, since it differs per analysis.
%
%   data - router struct with:
%          .comments - trials table (one row per trial; keyed by .Task).
%          .eyes     - eye raster: .data (chan x trials x samp), dim 2 is 1:1
%                      with .comments; .timeseq.alignedrawtime per trial;
%                      .timeseq.relative_time (per-sample axis) and .cal untouched.
%          .spike    - online_spike raster: .data (units x trials x bins),
%                      .info.Session/.Trial_number per trial,
%                      .timeseq.alignedrawtime per trial.
%          Empty fields ([] / missing product) pass through untouched.
%   task - task-name string (an exact value from comments.Task).
%
% Returns data_task with the same fields, restricted to `task`. comments, RT and
% eyes are masked positionally (they are 1:1 with comments, in order). When a
% spike raster is present it is paired to the task comments rows by
% (Session, Trial_number) via SpikeTrialAlignmentCheck, its trial dimension is
% subset to the matched trials, and comments / RT / eyes are re-ordered to the
% raster trial order -- so a consumer can index comments row j (and RT row j, eye
% trial j) with spike trial j directly. The comments `index` column (a 0-based
% index over the whole recording) is re-based to a contiguous 1..N for this task;
% Trial_number (the real, session-resetting number) is left intact.
%
% Xuefei Yu Jul 2026

    nTrials = height(data.comments);

    % ── Per-trial products masked positionally (all 1:1 with comments) ────────
    mask   = strcmp(string(data.comments.Task), task);
    cdTask = data.comments(mask, :);
    %[rtTask,  rtAligned]  = maskTrialTable(data.RT, mask, nTrials);
    [eyeTask, eyeAligned] = maskEyeTrials(data.eyes, mask, nTrials);

    % ── Spike raster: pair to the task comments, subset + co-order the rest ───
    % SpikeTrialAlignmentCheck matches each raster trial to a cdTask row by
    % (Session, Trial_number) and returns .valid (matched) and .loc (the cdTask
    % row index). Only the trial dimension is touched here: raster dim 2 and the
    % per-trial info vectors (.info.Session/.Trial_number, .timeseq.alignedrawtime).
    % Per-unit .info fields (Channel_Number, Unit_No, waveforms) and scalars
    % (samplingrate) are not per-trial and are left untouched.
    spikeTask = data.spike;
    if ~isempty(spikeTask) && isfield(spikeTask, 'data') && ~isempty(spikeTask.data)
        T     = SpikeTrialAlignmentCheck(spikeTask, cdTask);
        keep  = T.valid;
        order = T.loc(keep);

        spikeTask.data              = spikeTask.data(:, keep, :);
        spikeTask.info.Session      = spikeTask.info.Session(keep);
        spikeTask.info.Trial_number = spikeTask.info.Trial_number(keep);
        if isfield(spikeTask, 'timeseq') && isfield(spikeTask.timeseq, 'alignedrawtime')
            spikeTask.timeseq.alignedrawtime = spikeTask.timeseq.alignedrawtime(keep);
        end

        % Re-order the per-trial products so row/trial j lines up with spike trial j.
        cdTask = cdTask(order, :);
        %if rtAligned;   rtTask  = rtTask(order, :);                 end
        if eyeAligned;  eyeTask = reorderEyeTrials(eyeTask, order); end
    end

    % Re-base the whole-recording row index to a contiguous 1..N for this task, so
    % downstream code sees this task's trials numbered from 1 (e.g. prepTDData's
    % trial-count bounds). `index` is otherwise a 0-based index over the whole
    % recording; Trial_number (the real, session-resetting number) is left intact.
    if ismember('index', cdTask.Properties.VariableNames)
        cdTask.index = (1:height(cdTask))';
    end

    data_task = struct('comments', cdTask, 'eyes', eyeTask, 'spike', spikeTask);
end



function [out, aligned] = maskEyeTrials(eyes, mask, nTrials)
% Positional trial-mask (dim 2) for the eye raster. Only per-trial parts are
% touched: .data dim 2 and .timeseq.alignedrawtime. The per-sample axis
% (.timeseq.relative_time) and calibration (.cal) are not per-trial and stay put.
    out = eyes;
    hasData = ~isempty(eyes) && isfield(eyes, 'data') && ~isempty(eyes.data);
    aligned = hasData && size(eyes.data, 2) == nTrials;
    if ~aligned
        if hasData
            warning('SetupDataForTask:EyesUnaligned', ...
                ['eyes.data (%d trials) is not 1:1 with comments (%d rows); ' ...
                 'passing eyes through unfiltered.'], size(eyes.data, 2), nTrials);
        end
        return
    end
    out.data = eyes.data(:, mask, :);
    if isfield(out, 'timeseq') && isfield(out.timeseq, 'alignedrawtime')
        out.timeseq.alignedrawtime = eyes.timeseq.alignedrawtime(mask);
    end
end

function eyes = reorderEyeTrials(eyes, order)
% Re-order the eye raster's trial dimension (and per-trial timeseq) by `order`.
    eyes.data = eyes.data(:, order, :);
    if isfield(eyes, 'timeseq') && isfield(eyes.timeseq, 'alignedrawtime')
        eyes.timeseq.alignedrawtime = eyes.timeseq.alignedrawtime(order);
    end
end
