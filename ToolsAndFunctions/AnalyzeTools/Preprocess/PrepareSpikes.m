function [SpikeSummary, spike_data, waveform_data] = PrepareSpikes(spike_path, waveform_path, comments_data, cfgSpike, savePath)
% Preprocessing block: spike QC.
%
% The spike raster (~23 MB) is always read -- spikeCheck computes whole-session
% firing rates from it and the task router screens it afterwards. The waveform
% export (~614 MB, by far the largest product of a session) is read when this
% block has to recompute, when the file was explicitly asked for, or when the
% navigator is going to be drawn: the cache holds each unit's per-task mean
% waveform and PCA result but not the individual waveforms, so an open GUI has
% no cache-only path to its waveform and PCA panels. Headless with a warm cache
% is the case that still skips the read -- spikeCheck is handed [], sees
% haveWave = false, and seeds its per-unit metrics from
% AnalysisCache/SpikeSummary.mat instead.
%
%   spike_path    - resolved path of the spike raster export, or '' when absent.
%   waveform_path - resolved path of the spike waveform export, or '' when absent.
%   comments_data - the parsed trials table.
%   cfgSpike      - config struct (cfg.Spike):
%                     .Plot         - open the spike navigator GUI (a GUI run
%                                     draws per-unit waveform/PCA panels, so it
%                                     needs the waveform export)
%                     .ReCompute    - recompute the per-unit metrics
%                     .NSample      - waveforms per task per unit drawn in the
%                                     waveform panel; NaN = all. Drawing only --
%                                     every reported number uses all spikes
%                     .KeepFullFile - also return the waveform export
%   savePath      - session export folder ('' disables caching/export).
%
% Returns:
%   SpikeSummary  - per-unit table (Channel, Unit, AvgFR, ViolationRate,
%                   Excluded), with AverageWaveform appended from the loader's
%                   precomputed per-unit mean when available. [] with no raster.
%   spike_data    - the spike raster product (always returned when present: the
%                   router screens and scopes it).
%   waveform_data - the waveform export when .KeepFullFile is true, else [].
%
% Xuefei Yu 2026

    if nargin < 4;  cfgSpike = [];  end
    if nargin < 5;  savePath = '';  end

    cfgWarnUnknown(cfgSpike, {'Plot', 'ReCompute', 'NSample', 'KeepFullFile'}, 'cfg.Spike');

    SpikeSummary  = [];
    spike_data    = [];
    waveform_data = [];

    if isempty(spike_path)
        disp('No spike data found');
        return
    end

    spike_data = loadExportProduct(spike_path, {'online_spike'});

    % Plot is a block-specific extra clause on top of the shared rule (the same
    % shape as PrepareEyes' forceLoad, not a re-derivation of needFullFile): the
    % navigator's waveform and PCA panels draw individual waveforms, which the
    % cache deliberately does not keep, so an open GUI always needs the export.
    % The load decision is taken once here, and the branch it took is what the
    % report below states -- not a second guess at it.
    if isempty(waveform_path)
        disp('No spike waveform found');
        waveNote = 'no waveform export';
    elseif cfgField(cfgSpike, 'Plot', true) || ...
            needFullFile(cfgSpike, savePath, 'SpikeSummary', '.mat')
        waveform_data = loadExportProduct(waveform_path, {'online_spike_waveform'});
        waveNote = 'waveform export read';
    else
        waveNote = 'waveform export not read';
    end

    % spikeCheck defaults plotFlag to true, and what .Plot opens here is the
    % navigator GUI rather than a figure, so the wording follows that.
    fprintf('  %s\n', describeBlockPlan(cfgSpike, savePath, 'SpikeSummary', '.mat', ...
        struct('PlotDefault', true, 'PlotLabel', 'navigator', 'Notes', {{waveNote}})));

    SpikeSummary = spikeCheck(spike_data, waveform_data, comments_data, savePath, ...
        cfgField(cfgSpike, 'Plot',      []), ...
        cfgField(cfgSpike, 'ReCompute', []), ...
        cfgField(cfgSpike, 'NSample',   []));

    % Surface the loader's precomputed per-unit average waveform (uV). Rows of
    % SpikeSummary align 1:1 with spike_data.info (one row per unit, same order).
    if ~isempty(SpikeSummary) && isfield(spike_data.info, 'MeanWaveform') ...
            && ~isempty(spike_data.info.MeanWaveform)
        SpikeSummary.AverageWaveform = spike_data.info.MeanWaveform;  % nRow x nSamp (uV)
    end

    if cfgField(cfgSpike, 'Plot', true)
        disp('Completed spikecheck!');
    end

    % The single largest product of a session: hand it back only if it was asked
    % for, so otherwise it is freed the moment this block returns.
    if ~cfgField(cfgSpike, 'KeepFullFile', false)
        waveform_data = [];
    end
end
