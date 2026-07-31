function [PDTiming, photodiode_data] = PreparePhotodiode(photodiode_path, comments_data, cfgPhotodiode, savePath)
% Preprocessing block: photodiode timing.
%
% Reads the photodiode export only when this block actually has to recompute
% (or when the file was explicitly asked for) -- see needFullFile. Otherwise it
% hands [] to GetPhotodiodeTiming, which takes its own cache branch
% (AnalysisCache/PhotodiodeTiming.mat for the plot path, .csv for the
% return-only path) and never looks at the argument, so the export stays unread.
%
%   photodiode_path - resolved path of the photodiode export, or '' when the
%                     session has none.
%   comments_data   - the parsed trials table.
%   cfgPhotodiode   - config struct (cfg.Photodiode):
%                       .Plot         - draw the timing QC figures
%                       .PlotN        - trials to draw
%                       .ReCompute    - recompute and refresh the cache
%                       .KeepFullFile - also return the photodiode traces
%                     Every OTHER field is passed straight through as a
%                     name/value option of GetPhotodiodeTiming (BaselineWindow,
%                     SearchWindow, NSD, Polarity, SuccessOutcomes, ...), so the
%                     pass-through list is derived from the struct rather than
%                     maintained here. An omitted or empty field takes that
%                     function's own documented default.
%   savePath        - session export folder ('' disables caching/export).
%
% Returns:
%   PDTiming        - the per-trial timing table, or [] when there is no export.
%   photodiode_data - the loaded export when .KeepFullFile is true, else [].
%
% Xuefei Yu 2026

    if nargin < 3;  cfgPhotodiode = [];  end
    if nargin < 4;  savePath      = '';  end

    POSITIONAL = {'Plot', 'PlotN', 'ReCompute', 'KeepFullFile'};
    cfgWarnUnknown(cfgPhotodiode, [POSITIONAL, {'BaselineWindow', 'SearchWindow', ...
        'OffsetSearchSpan', 'PlotWindow', 'OffsetPlotWindow', 'NWorst', 'NSD', ...
        'NContig', 'ChannelMap', 'Polarity', 'SuccessOutcomes'}], 'cfg.Photodiode');

    PDTiming        = [];
    photodiode_data = [];

    if isempty(photodiode_path)
        disp('No parsed photodiode data found');
        return
    end

    if needFullFile(cfgPhotodiode, savePath, 'PhotodiodeTiming', {'.mat', '.csv'})
        photodiode_data = loadExportProduct(photodiode_path, {'photodiode'});
    end

    % Build the name/value tail from whatever else the config carries. Fields
    % left empty are dropped so GetPhotodiodeTiming's own inputParser default
    % applies instead of an empty value failing its validator.
    nvNames = setdiff(fieldnames(cfgPhotodiode), POSITIONAL, 'stable');
    nvVals  = cellfun(@(f) cfgPhotodiode.(f), nvNames, 'UniformOutput', false);
    keep    = ~cellfun(@isempty, nvVals);
    nv      = [nvNames(keep).'; nvVals(keep).'];

    disp('Start processing photodiode timing');
    PDTiming = GetPhotodiodeTiming(photodiode_data, comments_data, ...
        cfgField(cfgPhotodiode, 'Plot',      []), ...
        cfgField(cfgPhotodiode, 'PlotN',     []), savePath, ...
        cfgField(cfgPhotodiode, 'ReCompute', []), nv{:});
    disp('Photodiode timing processing completed.');

    % Hand the loaded array back only if it was asked for, so otherwise the
    % memory is freed the moment this block returns.
    if ~cfgField(cfgPhotodiode, 'KeepFullFile', false)
        photodiode_data = [];
    end
end
