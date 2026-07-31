function P = spikeWaveformPCA(W, labels, nGroups, maxPts)
% PCA of spike waveforms with a per-group cluster-separation ratio.
%
% Projects the waveforms onto their first three principal components, finds each
% group's centroid, and reports within/between cluster distance ratio (small when
% groups share one cluster, large when they separate). Reusable for isolation /
% drift QC of any grouping (e.g. by task, by time block).
%
% The PC axes are returned alongside the scores, so a saved result can be
% re-projected later (score = (W - mu) * coeff) without the waveforms that
% produced it -- that is what lets the analysis cache keep the PCA of a session
% whose waveform export is no longer loaded.
%
% Input:
%   W       - [nSpikes x nSamp] waveforms.
%   labels  - nSpikes x 1 group index (1..nGroups) per waveform.
%   nGroups - number of groups (centroids are indexed 1..nGroups).
%   maxPts  - (optional, default 5000) cap on the points fed to pca(), applied as
%             an even stride so the group proportions are preserved. Pass Inf to
%             use every waveform given.
%
% Output struct P:
%   .status    - 'ok' | 'few' (fewer than 4 spikes or 3 samples) | 'rankdef'
%                (waveforms rank-deficient for 3 PCs)
%   .score     - [nPts x 3] PC1-3 scores (subsampled to at most maxPts points)
%   .labels    - nPts x 1 group index aligned to .score
%   .centroids - nGroups x 3 group centroids (NaN row for an absent group)
%   .ratio     - within / between cluster distance ratio (NaN with <2 groups)
%   .coeff     - [nSamp x 3] PC axes (loading vectors), [] when not 'ok'
%   .mu        - [1 x nSamp] sample mean removed before projection, [] when not 'ok'
%   .explained - [3 x 1] percent of total variance carried by PC1-3, NaN when not 'ok'
%
% Xuefei Yu Jul 2026

    if nargin < 4 || isempty(maxPts);  maxPts = 5000;  end

    nSamp = size(W, 2);
    P = struct('status', 'few', 'score', zeros(0,3), 'labels', zeros(0,1), ...
               'centroids', nan(nGroups, 3), 'ratio', NaN, ...
               'coeff', zeros(nSamp, 0), 'mu', zeros(1, 0), 'explained', nan(3,1));

    if size(W,1) < 4 || size(W,2) < 3
        return
    end
    labels = labels(:);
    if size(W,1) > maxPts
        keep   = round(linspace(1, size(W,1), maxPts));
        W      = W(keep,:);
        labels = labels(keep);
    end

    [coeff, score, ~, ~, explained, mu] = pca(W, 'NumComponents', 3);
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

    % explained is returned for every component pca() could form; keep the three
    % that go with .coeff / .score, padded when the data supported fewer.
    exp3 = nan(3,1);
    nExp = min(3, numel(explained));
    exp3(1:nExp) = explained(1:nExp);

    P.status    = 'ok';
    P.score     = score;
    P.labels    = labels;
    P.centroids = cent;
    P.ratio     = ratio;
    P.coeff     = coeff;
    P.mu        = mu(:).';
    P.explained = exp3;
end
