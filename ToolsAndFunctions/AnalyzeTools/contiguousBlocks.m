function blocks = contiguousBlocks(labels)
% Runs of identical consecutive labels, as first/last row indices.
%
% Pure compute utility, shared by behaviorCheck.m (per-task success-rate blocks)
% and QualityCheck.m's spike firing panel (per-task baseline-rate blocks).
%
% Xuefei Yu Jul 2026
    blocks = struct('name', {}, 'first', {}, 'last', {});
    if isempty(labels);  return;  end
    start = 1;
    for i = 2:numel(labels)+1
        if i > numel(labels) || ~strcmp(labels{i}, labels{start})
            blocks(end+1) = struct('name', labels{start}, 'first', start, 'last', i-1);  %#ok<AGROW>
            start = i;
        end
    end
end
