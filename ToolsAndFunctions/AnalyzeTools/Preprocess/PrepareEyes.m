function [caled_eyes, eye_data] = PrepareEyes(eye_path, comments_data, cfgEye, savePath, forceLoad)
% Preprocessing block: eye calibration.
%
% Decides whether this session's eye export has to be read at all, then runs
% EyeCalibration on it.
%
% This is the one block whose cache does NOT remove the load. EyeCalibration
% caches only the fitted coefficients (AnalysisCache/EyeCalibration.txt) and
% still applies them to every trial of the whole array, so the export is
% unavoidable once calibration runs. The only way to skip it is not to
% calibrate -- which is safe exactly when nothing wants calibrated traces. Today
% CalculateRT is the only consumer (the analyzer hands protocols eyes = []), so
% the caller passes forceLoad = needFullFile(cfg.RT, ...) to say whether RT is
% going to recompute. Hence this block's rule, which needFullFile does not fit:
%
%   read the export when  Plot | ReCompute | KeepFullFile | forceLoad
%
%   eye_path      - resolved path of the eye export, or '' when the session has
%                   none. Both the current '*_eye_matlab.mat' (variable 'eye')
%                   and the pre-channel-split '*_analog_matlab.mat' (variable
%                   'analog') are accepted.
%   comments_data - the parsed trials table.
%   cfgEye        - config struct (cfg.Eye):
%                     .Plot         - draw the calibration QC figures
%                     .ReCompute    - refit; false reuses the cached coefficients
%                     .KeepFullFile - also return the uncalibrated uV traces
%                     .TaskCal .HoldWinMs .EyeChans .CalSessions .NCalTrials
%                                   - passed through to EyeCalibration; an
%                                     omitted field takes its default there
%   savePath      - session export folder ('' disables caching).
%   forceLoad     - (optional, default false) calibrate even when this block
%                   would otherwise skip it, because a later block needs traces.
%
% Returns:
%   caled_eyes - the calibrated eye product, or [] when nothing was calibrated
%                (no export, or no consumer this run). [] is deliberately NOT the
%                same as a cal.applied = false struct: that one means "tried and
%                failed", this one means "never ran". CalculateRT handles both.
%   eye_data   - the loaded export when .KeepFullFile is true, otherwise [].
%
% Xuefei Yu 2026

    if nargin < 3;  cfgEye    = [];     end
    if nargin < 4;  savePath  = '';     end
    if nargin < 5 || isempty(forceLoad);  forceLoad = false;  end

    cfgWarnUnknown(cfgEye, {'Plot', 'ReCompute', 'KeepFullFile', 'TaskCal', ...
        'HoldWinMs', 'EyeChans', 'CalSessions', 'NCalTrials'}, 'cfg.Eye');

    caled_eyes = [];
    eye_data   = [];

    if isempty(eye_path)
        disp('No parsed eye data found');
        return
    end

    keepFile = cfgField(cfgEye, 'KeepFullFile', false);
    if ~(cfgField(cfgEye, 'Plot', false) || cfgField(cfgEye, 'ReCompute', true) ...
            || keepFile || forceLoad)
        disp('Eye calibration skipped: no plot, no recompute, and nothing downstream needs the trace.');
        return
    end

    % TaskCal is the one parameter EyeCalibration has no default for (it is a
    % required positional), so it cannot fall through the way the others do.
    taskCal = cfgField(cfgEye, 'TaskCal', []);
    if isempty(taskCal)
        error('PrepareEyes:NoTaskCal', ...
            ['cfg.Eye.TaskCal is required: name the task(s) to calibrate from, ' ...
             'in priority order, e.g. {''fixation'',''visual_saccade'',''memory_saccade''}.']);
    end

    disp('Start eye calibration');
    eye_data = loadExportProduct(eye_path, {'eye', 'analog'});

    caled_eyes = EyeCalibration(comments_data, eye_data, taskCal, ...
        cfgField(cfgEye, 'HoldWinMs',   []), ...
        cfgField(cfgEye, 'EyeChans',    []), ...
        cfgField(cfgEye, 'Plot',        []), ...
        cfgField(cfgEye, 'CalSessions', []), ...
        cfgField(cfgEye, 'NCalTrials',  []), ...
        savePath, ...
        cfgField(cfgEye, 'ReCompute',   []));

    if caled_eyes.cal.applied
        disp('Eye calibration completed.');
    else
        disp('Eye calibration failed!');
    end

    % caled_eyes already holds a full copy of the array, converted to degrees, so
    % unless the uncalibrated traces were explicitly asked for, drop them here
    % rather than carrying a second copy of the export for the rest of the run.
    if ~keepFile;  eye_data = [];  end
end
