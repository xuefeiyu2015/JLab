function [tf, file] = hasCachedProduct(savePath, name, ext)
% Is a cached analyze-stage product already on disk for this session?
%
%   file = <savePath>/AnalysisCache/<name><ext>
%
% This is the single definition of where a cached product lives. getCachedPayload
% uses it for its own cache-hit test, and the Prepare* wrappers use it (through
% needFullFile) to decide whether the exported file still has to be read -- so the
% two can never drift apart about what "already cached" means.
%
%   savePath - the session export folder. '' disables caching entirely, in which
%              case tf is false and file is '' (nothing to load, nothing to save).
%   name     - cache file base name, e.g. 'RT', 'PhotodiodeTiming'.
%   ext      - extension including the dot. Default '.mat'; the lightweight
%              per-trial tables are '.csv'.
%
% Xuefei Yu 2026

    if nargin < 3 || isempty(ext);  ext = '.mat';  end

    file = '';
    tf   = false;
    if isempty(savePath);  return;  end

    file = fullfile(char(savePath), 'AnalysisCache', [name ext]);
    tf   = exist(file, 'file') == 2;
end
