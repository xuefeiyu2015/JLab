function f = fano(counts)
% Fano factor (variance / mean) of a set of spike counts.
%
% NaNs are ignored; returns NaN when it is undefined (fewer than two counts, or a
% zero mean). For a fair Fano the counts should come from a fixed counting window.
%
% Xuefei Yu Jul 2026

    counts = counts(~isnan(counts));
    if numel(counts) < 2 || mean(counts) == 0
        f = NaN;
    else
        f = var(counts) / mean(counts);
    end
end
