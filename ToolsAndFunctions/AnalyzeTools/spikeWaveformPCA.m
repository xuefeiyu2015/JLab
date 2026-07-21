function P = spikeWaveformPCA(W, labels, nGroups)
% PCA of spike waveforms with a per-group cluster-separation ratio.
%
% Projects the waveforms onto their first three principal components, finds each
% group's centroid, and reports within/between cluster distance ratio (small when
% groups share one cluster, large when they separate). Reusable for isolation /
% drift QC of any grouping (e.g. by task, by time block).
%
% Input:
%   W       - [nSpikes x nSamp] waveforms.
%   labels  - nSpikes x 1 group index (1..nGroups) per waveform.
%   nGroups - number of groups (centroids are indexed 1..nGroups).
%
% Output struct P:
%   .status    - 'ok' | 'few' (fewer than 4 spikes or 3 samples) | 'rankdef'
%                (waveforms rank-deficient for 3 PCs)
%   .score     - [nPts x 3] PC1-3 scores (subsampled to at most 5000 points)
%   .labels    - nPts x 1 group index aligned to .score
%   .centroids - nGroups x 3 group centroids (NaN row for an absent group)
%   .ratio     - within / between cluster distance ratio (NaN with <2 groups)
%
% Xuefei Yu Jul 2026

    MAXPTS = 5000;
    P = struct('status', 'few', 'score', zeros(0,3), 'labels', zeros(0,1), ...
               'centroids', nan(nGroups, 3), 'ratio', NaN);

    if size(W,1) < 4 || size(W,2) < 3
        return
    end
    labels = labels(:);
    if size(W,1) > MAXPTS
        keep   = round(linspace(1, size(W,1), MAXPTS));
        W      = W(keep,:);
        labels = labels(keep);
    end

    [~, score] = pca(W, 'NumComponents', 3);
    if size(score,2) < 3
        P.status = 'rankdef';
        return
    end

    cent = nan(nGroups, 3);
    for t = 1:nGroups
        sel = labels == t;
        if any(sel);  cent(t,:) = mean(score(sel,:), 1);  end
    end

    % within = mean point-to-own-centroid distance; between = mean centroid pair
    % distance over the groups that have a centroid.
    within = mean(sqrt(sum((score - cent(labels,:)).^2, 2)), 'omitnan');
    haveC  = find(all(~isnan(cent), 2));
    ratio  = NaN;
    if numel(haveC) >= 2
        ratio = within / mean(pdist(cent(haveC,:)));
    end

    P.status    = 'ok';
    P.score     = score;
    P.labels    = labels;
    P.centroids = cent;
    P.ratio     = ratio;
end
