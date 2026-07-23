function cal = readCalibration(file)
% Read an eye-calibration fit written by writeCalibration back into a cal struct.
%
% Parses the "key: value" text file and rebuilds the same struct shape
% EyeCalibration produces, so a cached fit can be applied to the eye trace without
% re-fitting.
%
% Input:
%   file - full path of the .txt file written by writeCalibration.
%
% Returns:
%   cal  - struct with fields applied (logical), units (char), task_cal (cellstr),
%          coef_x = [offset_x; gain_x; couple_xy], coef_y = [offset_y; gain_y;
%          couple_yx], R2_x, R2_y.
%
% Xuefei Yu Jul 2026

    fid = fopen(file, 'r');
    if fid == -1
        error('readCalibration:OpenFailed', 'Could not open %s for reading.', file);
    end
    cleanup = onCleanup(@() fclose(fid));

    kv = struct();
    line = fgetl(fid);
    while ischar(line)
        s = strtrim(line);
        if ~isempty(s) && s(1) ~= '#'
            ci = find(s == ':', 1);
            if ~isempty(ci)
                key = strtrim(s(1:ci-1));
                val = strtrim(s(ci+1:end));
                if isvarname(key)
                    kv.(key) = val;
                end
            end
        end
        line = fgetl(fid);
    end

    cal = struct('applied', false, 'units', 'uV', 'task_cal', {{}}, ...
                 'coef_x', [], 'coef_y', [], 'R2_x', NaN, 'R2_y', NaN);

    if isfield(kv, 'applied');  cal.applied = logical(str2double(kv.applied));  end
    if isfield(kv, 'units');    cal.units   = kv.units;                         end
    if isfield(kv, 'task_cal')
        if isempty(kv.task_cal)
            cal.task_cal = {};
        else
            cal.task_cal = strtrim(strsplit(kv.task_cal, ','));
        end
    end

    cal.coef_x = [num(kv, 'offset_x'); num(kv, 'gain_x'); num(kv, 'couple_xy')];
    cal.coef_y = [num(kv, 'offset_y'); num(kv, 'gain_y'); num(kv, 'couple_yx')];
    cal.R2_x   = num(kv, 'R2_x');
    cal.R2_y   = num(kv, 'R2_y');
end


function v = num(kv, key)
% Numeric value for a key, NaN if the key was absent.
    if isfield(kv, key)
        v = str2double(kv.(key));
    else
        v = NaN;
    end
end
