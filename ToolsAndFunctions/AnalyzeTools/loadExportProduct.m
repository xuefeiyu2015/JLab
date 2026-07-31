function v = loadExportProduct(filePath, varNames)
% Load one exported product (.mat) and return the product struct inside it.
%
% Each Stage-1 export stores its product under a fixed variable name (set by
% BlackrockLoader.export), so reading one is always "load the file, take that
% variable". varNames also absorbs the renames: pass the accepted names in
% priority order and whichever the file holds is returned, which is how
% pre-channel-split sessions ('analog' instead of 'eye') keep working without
% re-running the loader.
%
%   filePath - full path to the .mat. '' or a missing file returns [], so a
%              caller can pass an unresolved path straight through and let the
%              analyze function take its own no-data branch.
%   varNames - char or cellstr of accepted variable names, in priority order,
%              e.g. {'eye','analog'} or 'online_spike'.
%
% Xuefei Yu 2026

    v = [];
    if isempty(filePath) || exist(filePath, 'file') ~= 2
        return
    end

    varNames = cellstr(varNames);
    L        = load(filePath);

    % isfield takes the whole cellstr at once, so the accepted names are tested
    % in one shot; 'stable' order means the first listed name wins.
    hit = varNames(isfield(L, varNames));
    if isempty(hit)
        error('loadExportProduct:VariableNotFound', ...
            'None of (%s) found in %s. It holds: %s', ...
            strjoin(varNames, ', '), filePath, strjoin(fieldnames(L).', ', '));
    end

    v = L.(hit{1});
end
