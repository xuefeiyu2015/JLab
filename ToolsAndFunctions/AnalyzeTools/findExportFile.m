function p = findExportFile(all_files, main_path, pattern, exclude)
% Resolve one exported product in main_path by a rough name match.
%
%   all_files - cellstr of file names in main_path.
%   main_path - the session export folder (used to build the full path and to
%               name the folder in the ambiguity error).
%   pattern   - substring the name must contain (e.g. 'analog').
%   exclude   - (optional) substring that disqualifies a match. Needed for
%               'spikes', which would otherwise also catch 'spikes_waveform'.
%
% Returns '' when nothing matches, so callers can guard with isempty().
%
% Lifted out of BlackRockFileAnalyzer.m (where it was a script-local function) so
% the analyzer, the Prepare* blocks and any future batch driver all resolve
% export paths the same way. Behaviour is unchanged.
%
% Xuefei Yu 2026

    hit = all_files(contains(all_files, pattern));
    if nargin > 3 && ~isempty(exclude)
        hit = hit(~contains(hit, exclude));
    end

    if isempty(hit)
        p = '';
        return
    end
    if numel(hit) > 1
        error('findExportFile:Ambiguous', ...
            'Multiple files match "%s" in %s:\n  %s', ...
            pattern, main_path, strjoin(hit, '\n  '));
    end
    p = fullfile(main_path, hit{1});
end
