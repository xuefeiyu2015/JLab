function [aligned_eye, relative_time_seq] = AlignEyeTrace(eye_x, eye_y, eye_time, ...
        align_marker_time, preMs, postMs)
% Re-align eye traces to a per-trial marker (e.g. fixation offset / go cue).
% Resamples every trial onto one shared time axis with 0 at the marker.
%
%   eye_x, eye_y      - nTrials x nSamp eye position (e.g. uV), one row per trial.
%   eye_time          - 1 x nSamp shared sample times (s), same clock as the marker.
%   align_marker_time - nTrials x 1 marker time per trial (s, same frame as eye_time).
%                       NaN -> that trial's aligned rows are all NaN.
%   preMs / postMs    - window kept before / after the marker (ms).
%
% Returns:
%   aligned_eye       - struct with .x, .y (nTrials x nOut, marker-aligned,
%                       NaN outside available data)
%   relative_time_seq - 1 x nOut time from the marker (s), 0 at the marker,
%                       sampled at the native step of eye_time.
%
% Xuefei Yu Mar 6, 2026

    eye_time = eye_time(:).';                       % force 1 x nSamp
    nT       = size(eye_x, 1);

    step_s = median(diff(eye_time));                % native sample interval (s)
    nPre   = round((preMs/1000)  / step_s);         % samples before / after marker
    nPost  = round((postMs/1000) / step_s);
    relative_time_seq = (-nPre:nPost) * step_s;     % 1 x nOut, 0 = marker

    ax = nan(nT, numel(relative_time_seq));
    ay = nan(nT, numel(relative_time_seq));
    for i = 1:nT
        if isnan(align_marker_time(i));  continue;  end
        sample_s = align_marker_time(i) + relative_time_seq;   % where to sample eye_time
        ax(i,:) = interp1(eye_time, eye_x(i,:), sample_s, 'linear', NaN);
        ay(i,:) = interp1(eye_time, eye_y(i,:), sample_s, 'linear', NaN);
    end

    aligned_eye = struct('x', ax, 'y', ay);
end
