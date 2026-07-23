function writeCalibration(cal, file)
% Write an eye-calibration fit to a human-readable text file.
%
% Dumps the gain / offset / coupling coefficients (and fit quality) as labelled
% "key: value" lines so the fit can be read at a glance and reloaded by
% readCalibration, letting EyeCalibration skip the per-trial re-fit on later runs.
% Only the coefficients are stored, not the raw fitted points, so this is a small
% text file, not a data dump.
%
% Input:
%   cal  - the calibration struct from EyeCalibration:
%            .applied (logical), .units (char), .task_cal (cellstr),
%            .coef_x = [offset_x; gain_x; couple_xy],
%            .coef_y = [offset_y; gain_y; couple_yx],
%            .R2_x, .R2_y.
%   file - full path of the .txt file to write (its folder is created if needed).
%
% Xuefei Yu Jul 2026

    d = fileparts(file);
    if ~isempty(d) && ~exist(d, 'dir');  mkdir(d);  end

    tasks = cal.task_cal;
    if isempty(tasks)
        taskStr = '';
    else
        taskStr = strjoin(cellstr(tasks), ', ');
    end

    fid = fopen(file, 'w');
    if fid == -1
        error('writeCalibration:OpenFailed', 'Could not open %s for writing.', file);
    end
    cleanup = onCleanup(@() fclose(fid));

    fprintf(fid, '# Eye calibration fit\n');
    fprintf(fid, '# model: t = offset + gain*v_main + couple*v_main*v_other\n');
    fprintf(fid, 'applied: %d\n',   logical(cal.applied));
    fprintf(fid, 'units: %s\n',     char(cal.units));
    fprintf(fid, 'task_cal: %s\n',  taskStr);
    % %.17g preserves a double exactly across the text round-trip, so applying the
    % cached fit reproduces the same calibrated degrees to full precision.
    fprintf(fid, 'offset_x: %.17g\n', cal.coef_x(1));
    fprintf(fid, 'gain_x: %.17g\n',   cal.coef_x(2));
    fprintf(fid, 'couple_xy: %.17g\n', cal.coef_x(3));
    fprintf(fid, 'offset_y: %.17g\n', cal.coef_y(1));
    fprintf(fid, 'gain_y: %.17g\n',   cal.coef_y(2));
    fprintf(fid, 'couple_yx: %.17g\n', cal.coef_y(3));
    fprintf(fid, 'R2_x: %.17g\n',   cal.R2_x);
    fprintf(fid, 'R2_y: %.17g\n',   cal.R2_y);
end
