function payload = getCachedPayload(savePath, name, reCompute, computeFcn)
% Load-or-compute a cached analysis product, keyed by the session export folder.
%
% Loads <savePath>/AnalysisCache/<name>.mat and returns its stored payload when
% reCompute is false and the file exists; otherwise calls computeFcn() to build
% the payload fresh and writes it to that same file. This is the shared engine
% behind the AnalysisCache layer: each computing function hands over a no-arg
% handle that returns its full (plot-ready) payload, and this helper decides
% whether to run it or reuse the cached result.
%
% Input:
%   savePath   - the session export folder (.../Monkey <name>/.../export_data/<date>).
%                '' disables caching entirely: computeFcn always runs and nothing
%                is read or written.
%   name       - cache file base name (no extension), e.g. 'BehaviorSummary'.
%   reCompute  - when true, always recompute and overwrite the cache (the default
%                behaviour of the callers). When false, load the cache if present.
%   computeFcn - function handle taking no arguments and returning the payload
%                (any struct / table / array). Only called on a cache miss.
%
% Output:
%   payload    - the loaded or freshly computed payload.
%
% The load/save is intentionally format-agnostic (the payload is stored under the
% single variable name `payload`), so callers control exactly what is cached.
%
% Xuefei Yu Jul 2026

    cacheFile = '';
    if ~isempty(savePath)
        cacheFile = fullfile(char(savePath), 'AnalysisCache', [name '.mat']);
    end

    % Cache hit: only when the caller opted out of recompute and the file is there.
    if ~reCompute && ~isempty(cacheFile) && exist(cacheFile, 'file')
        L = load(cacheFile);
        payload = L.payload;
        return
    end

    % Cache miss (or forced recompute): build it, then persist when caching is on.
    payload = computeFcn();
    if ~isempty(cacheFile)
        cacheDir = fileparts(cacheFile);
        if ~exist(cacheDir, 'dir');  mkdir(cacheDir);  end
        save(cacheFile, 'payload');
    end
end
