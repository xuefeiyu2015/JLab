function tf = needFullFile(cfgBlock, savePath, name, ext)
% Must this preprocessing block read its full exported file, or can it run off
% the cache?
%
% This is the load rule of the whole cascade, in one place:
%   - KeepFullFile asked for the file explicitly           -> read it
%   - ReCompute asked for the product to be rebuilt        -> read it
%   - the cached product it would otherwise reuse is gone  -> read it
%   - otherwise                                            -> don't
% On the last branch the wrapper hands [] to the analyze function, which takes
% its own cache branch (getCachedPayload for the plot path, the .csv for the
% return-only path) and never looks at the argument -- so the export stays unread.
%
%   cfgBlock - that block's config struct (cfg.Photodiode, cfg.Spike, ...).
%   savePath - the session export folder. '' means no cache, so always true.
%   name     - the cached product's base name, e.g. 'RT', 'SpikeSummary'.
%   ext      - the cached product's extension. A 2-element cellstr
%              {'.mat','.csv'} says the plot path and the return-only path reuse
%              DIFFERENT files (RT, PhotodiodeTiming): '.mat' is checked when
%              cfg.Plot is true and '.csv' when it is false, matching the branch
%              those functions already take internally. A plain char is used as
%              given (spikeCheck caches only a .mat).
%
% Two blocks add to this rule rather than following it alone:
%   - EyeCalibration caches only the fit coefficients and still applies them to
%     every trial, so its export is unavoidable once it runs at all. PrepareEyes
%     states its own rule instead.
%   - PrepareSpikes ORs cfg.Spike.Plot on top: the spike cache keeps each unit's
%     per-task mean waveform and PCA result but not the individual waveforms, so
%     the navigator's waveform / PCA panels have no cache-only path and an open
%     GUI always needs the waveform export.
%
% Xuefei Yu 2026

    if nargin < 4 || isempty(ext);  ext = '.mat';  end

    % An explicit request wins over any cache.
    if cfgField(cfgBlock, 'ReCompute', true) || cfgField(cfgBlock, 'KeepFullFile', false)
        tf = true;
        return
    end

    if iscell(ext)
        % Plot true -> the heavy .mat payload; false -> the lightweight .csv.
        ext = ext{2 - logical(cfgField(cfgBlock, 'Plot', false))};
    end

    tf = ~hasCachedProduct(savePath, name, ext);
end
