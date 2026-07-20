function feat = extractWaveformFeatures(waveforms, fs)
% Extract sorting-quality features from a set of spike waveforms.
%
% A pure compute helper (no plotting), following the VisPsychometricFunction
% pattern: it returns everything a caller needs to report or tabulate, so the
% same numbers can back a table, a plot, or a headless quality struct.
%
% Input:
%   waveforms - spike waveforms in µV, one waveform per spike. Either
%               [nSamp x nSpikes] or [nSpikes x nSamp]; the sample dimension is
%               detected automatically (waveforms are tens of samples long, far
%               shorter than a unit's spike count). NaN-padded spikes (all-NaN
%               rows/cols, as produced by the segmented waveform product) are
%               dropped before anything is computed.
%   fs        - sampling rate of the waveform (Hz). Default 30000 (Blackrock NEV
%               online waveforms). Only affects .widthMs.
%
% Output struct feat:
%   .meanWave     - 1 x nSamp mean waveform (µV), NaNs ignored per sample
%   .nSpikes      - number of spikes that contributed
%   .peakToValley - peak-to-valley amplitude of the mean waveform (µV): max - min
%   .widthMs      - trough-to-peak duration of the mean waveform (ms): time from
%                   the global minimum to the following maximum. NaN if the peak
%                   does not follow the trough.
%   .snr          - signal-to-noise ratio: peak-to-valley of the mean waveform
%                   divided by (2 * mean per-sample std across spikes). The noise
%                   is the residual scatter of individual spikes about the mean.
%
% Xuefei Yu Jul 2026

    if nargin < 2 || isempty(fs)
        fs = 30000;   % Blackrock NEV online waveform sample rate
    end

    % --- orient to [nSpikes x nSamp] --------------------------------------
    % The sample axis is the short one (a waveform is ~48 samples; a unit fires
    % far more spikes than that). When both axes are short we cannot tell them
    % apart, so we assume the caller's native layout, [nSpikes x nSamp].
    W = double(waveforms);
    if isvector(W)
        W = W(:).';                       % a single waveform -> one row
    elseif size(W,1) <= size(W,2) && size(W,1) <= 128
        W = W.';                          % [nSamp x nSpikes] -> [nSpikes x nSamp]
    end

    % --- drop NaN-padded spikes -------------------------------------------
    keep = any(~isnan(W), 2);
    W    = W(keep, :);

    feat = struct('meanWave', [], 'nSpikes', 0, 'peakToValley', NaN, ...
                  'widthMs', NaN, 'snr', NaN);
    if isempty(W)
        return
    end

    feat.nSpikes = size(W, 1);

    % --- mean waveform and per-sample noise -------------------------------
    meanWave = mean(W, 1, 'omitnan');     % 1 x nSamp
    feat.meanWave = meanWave;

    [vMin, iMin] = min(meanWave);
    [vMax, iMax] = max(meanWave);
    feat.peakToValley = vMax - vMin;

    % Trough-to-peak: the peak that follows the trough (standard spike width).
    if iMax > iMin
        feat.widthMs = (iMax - iMin) / fs * 1000;
    else
        % Global max precedes the global min; use the first local max after the
        % trough if there is one, otherwise leave width undefined.
        postTrough = meanWave(iMin:end);
        if numel(postTrough) > 1
            [~, iRel] = max(postTrough);
            if iRel > 1
                feat.widthMs = (iRel - 1) / fs * 1000;
            end
        end
    end

    % Noise = mean over samples of the across-spike std. With one spike there is
    % no scatter to estimate, so SNR is left NaN.
    if feat.nSpikes >= 2
        noise = mean(std(W, 0, 1, 'omitnan'), 'omitnan');
        if noise > 0
            feat.snr = feat.peakToValley / (2 * noise);
        end
    end
end
