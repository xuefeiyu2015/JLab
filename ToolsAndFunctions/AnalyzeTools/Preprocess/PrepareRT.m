function RT = PrepareRT(caled_eyes, comments_data, cfgRT, savePath)
% Preprocessing block: saccadic reaction time.
%
% Thin wrapper over CalculateRT that unpacks one config struct. This block reads
% no exported file of its own -- it consumes the calibrated product PrepareEyes
% returns -- so it has no KeepFullFile option. It is, however, what drives the
% eye cascade: the analyzer asks needFullFile(cfgRT, ...) up front and passes the
% answer to PrepareEyes as forceLoad, so the 179 MB eye export is only read when
% this block is going to recompute.
%
%   caled_eyes    - calibrated eye product from PrepareEyes, or [] when nothing
%                   was calibrated. CalculateRT returns an all-NaN table of the
%                   right height in that case, so the trial-count contract that
%                   extendComments and SetupDataForTask rely on still holds.
%   comments_data - the parsed trials table.
%   cfgRT         - config struct (cfg.RT):
%                     .Plot          - draw the saccade QC figures
%                     .PlotN         - detected trials to draw
%                     .ErrorCheck    - also draw the outlier-saccade figure
%                     .ReCompute     - recompute and refresh the cache
%                     .EndpointStyle - 'kde' | 'hist'      (saccade-map figure)
%                     .PeakVelStyle  - 'surface' | 'dots'  (saccade-map figure)
%   savePath      - session export folder ('' disables caching/export).
%
% Returns RT, the per-trial saccade table (one row per comments_data row).
%
% Xuefei Yu 2026

    if nargin < 3;  cfgRT    = [];  end
    if nargin < 4;  savePath = '';  end

    cfgWarnUnknown(cfgRT, {'Plot', 'PlotN', 'ErrorCheck', 'ReCompute', ...
        'EndpointStyle', 'PeakVelStyle'}, 'cfg.RT');

    % The two style options only affect the saccade-map QC figure, and passing an
    % empty one would fail CalculateRT's inputParser validator, so drop the ones
    % the config leaves out and let that function's defaults stand.
    styleNames = {'EndpointStyle', 'PeakVelStyle'};
    styleVals  = cellfun(@(f) cfgField(cfgRT, f, []), styleNames, 'UniformOutput', false);
    keep       = ~cellfun(@isempty, styleVals);
    nv         = [styleNames(keep); styleVals(keep)];

    RT = CalculateRT(caled_eyes, comments_data, ...
        cfgField(cfgRT, 'Plot',       []), ...
        cfgField(cfgRT, 'PlotN',      []), ...
        cfgField(cfgRT, 'ErrorCheck', []), savePath, ...
        cfgField(cfgRT, 'ReCompute',  []), nv{:});
end
