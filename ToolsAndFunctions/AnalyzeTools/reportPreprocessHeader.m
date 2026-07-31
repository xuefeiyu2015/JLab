function reportPreprocessHeader(savePath)
% Print the session folder and where its analysis cache lives, once, before the
% first preprocessing stage.
%
% The per-stage status lines name only a cache file's basename ('RT.mat', ...)
% to stay short, so this is what tells the reader which folder those files are
% in -- and that there is an AnalysisCache folder to look in at all, which is
% not obvious if you have only ever run the driver.
%
%   savePath - the session export folder ('' disables caching).
%
% Xuefei Yu 2026

    % hasCachedProduct owns the <savePath>/AnalysisCache/<name><ext> convention,
    % so ask it for a path and strip the file rather than rebuilding the folder.
    [~, probe] = hasCachedProduct(savePath, 'probe', '.mat');
    cacheDir   = fileparts(probe);

    fprintf('\n===== Preprocessing =====\n');
    fprintf('  session : %s\n', char(savePath));

    if isempty(cacheDir)
        fprintf('  cache   : disabled (no session path) -- every block computes\n');
    elseif isfolder(cacheDir)
        cached = dir(fullfile(cacheDir, '*'));
        fprintf('  cache   : %s (%d file(s))\n', cacheDir, sum(~[cached.isdir]));
    else
        fprintf('  cache   : %s (does not exist yet -- every block computes)\n', cacheDir);
    end
end
