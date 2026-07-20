% A quality check script for checking the quality of the exported data
% files
function quality = QualityCheck(data, FileValid, savePath, plotFlag)
%FileValid = [Comments, Eye, Spike, SpikeWaveform]
%Function to perform Overall quality checks
%
%   data       - struct with the loaded products:
%                  .comments      - trials table (one row per trial)
%                  .eyes          - calibrated analog product (optional)(not used now)
%                  .spike         - online spike product (optional)
%                  .spikewaveform - spike waveform product (optional)
%   FileValid  - logical per product; FileValid(1) gates the behavior checks.
%   savePath   - (optional) export folder where the spike GUI reads/writes the
%                per-unit exclusion labels (unit_qc_exclusions.csv). '' disables
%                persistence (labels then live only for the session).
%   plotFlag   - (optional, default true) draw the figures. false runs headless:
%                no windows, the metrics for every unit are still computed and
%                returned (useful for batch processing).
%
% Returns:
%   quality    - struct of what was checked:
%                  .behavior  - the per-task condition table returned by
%                               behaviorCheck.m (Task, TotalValidTrials, MinRep,
%                               MinRepCondition)
%                  .spike     - struct array, one per (channel,unit), with the
%                               numbers behind the spike GUI: baseline firing
%                               rate, ISI violation / Fano, waveform SNR / width,
%                               PCA cluster-separation ratio
%
% The behavior check itself lives in the standalone behaviorCheck.m (callable
% right after loading the trials table, no spike data needed); QualityCheck just
% delegates to it.
%
% Xuefei Yu Jul 16, 2026

    if nargin < 3;  savePath = '';  end
    if nargin < 4 || isempty(plotFlag);  plotFlag = true;  end
    quality = struct('behavior', []);

    if isempty(FileValid) || ~FileValid(1)
        disp('No valid comments file, skipping the behavior check.');
        return
    end
    quality.behavior = behaviorCheck(data.comments, plotFlag);

    % Quality check for the spikes (standalone spikeCheck.m). Waveform-dependent
    % panels show "No waveform file" when data.spikewaveform is empty.
    quality.spike = [];
    if FileValid(3) == 1
        quality.spike = spikeCheck(data.spike, data.spikewaveform, ...
                                   data.comments, savePath, plotFlag);
    end

    % Headless runs have every unit's metrics in hand, so write the combined
    % per-unit summary CSV (a single trial-info row when the session has no spikes).
    if ~plotFlag && ~isempty(savePath)
        ExportQCSummary(quality, savePath);
    end
end
