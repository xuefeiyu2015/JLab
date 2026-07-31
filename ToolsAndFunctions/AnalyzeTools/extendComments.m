function ex = extendComments(comments, varargin)
% Extend comments with one or more analyze-stage product tables that have the
% same number of rows, in the same trial order.
% Example:
%   ex = extendComments(comments, RT, PDTiming);
%
% Identifier columns are dropped from each added table before concatenation:
% comments already carries them, and MATLAB rejects a horzcat that would create
% duplicate variable names. The products are row-aligned with comments by
% construction (both CalculateRT and GetPhotodiodeTiming build one row per
% comments_data row, in order), so this is a positional concatenation -- the
% dropped keys are redundant, not the thing being joined on.

    % Every analyze-stage product is keyed (Session, Trial_number); 'Trial' is
    % the legacy 0-based row-index column older products emitted before they
    % were switched to the real key.
    keyCols = { 'Session', 'Trial_number'};

    % A product this session does not have comes in as [] (no photodiode file ->
    % PDTiming = []). Drop those rather than failing the row-count check below
    % with "Table 2 has 0 rows, expected N": the caller can then always write
    % extendComments(comments, RT, PDTiming) without guarding each product.
    varargin = varargin(~cellfun(@isempty, varargin));

    nRows = cellfun(@height, varargin);
    bad   = find(nRows ~= height(comments), 1);
    if ~isempty(bad)
        error('Table %d has %d rows, expected %d.', bad, nRows(bad), height(comments));
    end

    % Drop all key columns in ONE setdiff per table rather than a delete per
    % name. The previous version tested for 'Session' and 'Trial_number' but
    % deleted 'Trial' in both branches, so a table keyed (Session,
    % Trial_number) -- which is what both products now return -- threw
    % "Unrecognized variable name 'Trial'" instead of merging. 'stable' keeps
    % each product's own column order intact.
    trimmed = cellfun(@dropKeys, varargin, 'UniformOutput', false);
    ex = [comments, trimmed{:}];      % one horzcat, no table grown in a loop

    function t = dropKeys(t)
        t = t(:, setdiff(t.Properties.VariableNames, keyCols, 'stable'));
    end

end
