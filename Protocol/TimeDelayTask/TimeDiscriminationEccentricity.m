function result = TimeDiscriminationEccentricity(data, cfg, plotFlag)
% Psychometric function split by the left/right target eccentricity ratio.
%
% When the two choice targets sit at different eccentricities, the farther one
% may be harder to reach / less salient, which could bias choices. Each valid
% trial gets ratio = rho_left / rho_right (polar eccentricity of the target in
% the left vs right hemifield), trials are split at cfg.RatioEdges, and one
% psychometric function is fit per group (all sessions pooled).
%
% Input
%   data     - struct from the task router; only data.comments (trials table)
%              is used. Needs Target_1/2_rho and Target_1/2_theta columns.
%   cfg      - optional struct. cfg.RatioEdges = ascending cut points on the
%              ratio (default [1/1.3 1.3] -> right farther / equal / left farther).
%   plotFlag - 1 (default): draw the figure; 0: compute only.
%
% Output
%   result   - .edges .ratio .bin (per valid trial, NaN = unusable geometry)
%              .groups(k): .label .n .pse .threshold .psy
%
% Xuefei Yu, 2026

    if nargin < 2;  cfg = [];  end
    if nargin < 3 || isempty(plotFlag);  plotFlag = 1;  end
    edges = cfgField(cfg, 'RatioEdges', [1/1.3 1.3]);

    D = prepTDData(data);
    [ratio, bin, labels] = deal([]);
    if ~isempty(D.S)
        ratio          = computeEccentricityRatio(D);
        [bin, labels]  = computeRatioBins(ratio, edges);
    end
    result = struct('edges', edges, 'ratio', ratio, 'bin', bin, 'groups', []);

    if ~any(isfinite(ratio))
        warning('TimeDiscriminationEccentricity:noRatio', ...
            'No valid time-delay trials with left/right target eccentricity.');
        if plotFlag
            figure('Name', 'Time discrimination: eccentricity ratio', 'Color', 'w');
            axis off;
            text(0.5, 0.5, 'No trials with a usable eccentricity ratio', ...
                'HorizontalAlignment', 'center', 'FontSize', 14);
        end
        return
    end

    result.groups = computeRatioPsy(D, bin, labels);
    if ~plotFlag;  return;  end

    H    = computeRatioHistogram(ratio, bin, edges, numel(labels));
    cmap = lines(numel(labels));
    figure('Name', 'Time discrimination: eccentricity ratio', 'Color', 'w', ...
           'Position', [80 120 1500 450]);
    tl = tiledlayout(1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
    plotRatioDistribution(nexttile(tl), H, edges, labels, cmap);
    plotRatioPsy(nexttile(tl), result.groups, cmap);
    plotRatioSummary(nexttile(tl), result.groups, cmap);
end

% =========================================================================
% Computation helpers (pure: no plotting, no side effects)
% =========================================================================
function ratio = computeEccentricityRatio(D)
% rho_left / rho_right per trial. NaN when both targets fall in the same
% hemifield or any position is missing / at fixation.
    side1 = BlackrockLoader.hemifield(D.theta1);
    side2 = BlackrockLoader.hemifield(D.theta2);
    left1 = side1 == -1;
    rhoL  = D.rho2;  rhoL(left1)  = D.rho1(left1);
    rhoR  = D.rho1;  rhoR(left1)  = D.rho2(left1);
    ratio = rhoL ./ rhoR;
    bad   = side1 == side2 | isnan(D.theta1) | isnan(D.theta2) | ...
            ~(rhoL > 0) | ~(rhoR > 0);
    ratio(bad) = NaN;
end

function [bin, labels] = computeRatioBins(ratio, edges)
% Group index per trial (NaN where ratio is NaN) and one label per group.
    bin   = discretize(ratio, [0, edges(:)', Inf]);
    nG    = numel(edges) + 1;
    labels = cell(1, nG);
    labels{1}  = sprintf('Right farther (<%.2f)', edges(1));
    labels{nG} = sprintf('Left farther (>%.2f)', edges(end));
    for k = 2:nG-1
        labels{k} = sprintf('%.2f-%.2f', edges(k-1), edges(k));
    end
    if nG == 3;  labels{2} = sprintf('Equal (%.2f-%.2f)', edges(1), edges(2));  end
end

function G = computeRatioPsy(D, bin, labels)
% One psychometric fit (computeSessionPsy) per ratio group, sessions pooled.
    G = struct('label', labels, 'n', 0, 'pse', NaN, 'threshold', NaN, 'psy', []);
    for k = 1:numel(labels)
        [G(k).pse, G(k).threshold, G(k).psy, G(k).n] = computeSessionPsy(D, find(bin == k));
    end
end

function H = computeRatioHistogram(ratio, bin, edges, nG)
% Per-group counts on log-spaced ratio bins. The cut points are themselves bin
% edges, so every histogram bin belongs to exactly one group.
    lr   = log(ratio(isfinite(ratio)));
    lims = [min([lr; log(edges(:))]), max([lr; log(edges(:))])];
    pad  = max(0.05 * diff(lims), 0.05);
    e    = unique([linspace(lims(1) - pad, lims(2) + pad, 41), log(edges(:))']);
    H.binEdges = exp(e);
    H.counts   = zeros(numel(e) - 1, nG);
    for k = 1:nG
        H.counts(:, k) = histcounts(ratio(bin == k), H.binEdges)';
    end
    H.nExcluded = sum(isnan(ratio));
end

% =========================================================================
% Plotting helpers (render only)
% =========================================================================
function plotRatioDistribution(ax, H, edges, labels, cmap)
    hold(ax, 'on');
    h = gobjects(0);  lbl = {};
    for k = 1:size(H.counts, 2)
        n = sum(H.counts(:, k));
        if n == 0;  continue;  end
        h(end+1) = histogram(ax, 'BinEdges', H.binEdges, 'BinCounts', H.counts(:, k), ...
            'FaceColor', cmap(k, :), 'EdgeColor', 'none', 'FaceAlpha', 0.8); %#ok<AGROW>
        lbl{end+1} = sprintf('%s  n=%d', labels{k}, n); %#ok<AGROW>
    end
    arrayfun(@(x) xline(ax, x, '--k'), edges);
    xline(ax, 1, ':k');
    set(ax, 'XScale', 'log', 'LineWidth', 1, 'FontSize', 11);  box(ax, 'off');
    xlabel(ax, 'Eccentricity ratio  \rho_{left} / \rho_{right}');
    ylabel(ax, 'Trials');
    title(ax, sprintf('Ratio distribution (%d trials excluded)', H.nExcluded));
    legend(ax, h, lbl, 'Location', 'northeast', 'FontSize', 8);
    hold(ax, 'off');
end

function plotRatioPsy(ax, G, cmap)
    hold(ax, 'on');
    h = gobjects(0);  lbl = {};
    for k = 1:numel(G)
        psy = G(k).psy;
        if isempty(psy);  continue;  end
        col = cmap(k, :);
        plot(ax, psy.stim_levels, psy.pRight, '.', 'Color', col, 'MarkerSize', 18);
        h(end+1) = plot(ax, psy.fit_x, psy.fit_y, '-', 'Color', col, 'LineWidth', 2); %#ok<AGROW>
        if psy.separable
            thrTxt = 'thr unreliable';
        else
            thrTxt = sprintf('thr %.1f', G(k).threshold);
        end
        lbl{end+1} = sprintf('%s n=%d | PSE %.1f, %s', G(k).label, G(k).n, ...
            G(k).pse, thrTxt); %#ok<AGROW>
    end
    plot(ax, xlim(ax), [0.5 0.5], '--k');
    plot(ax, [0 0], [0 1], '--k');
    xlim([-250,250]);%Add limit
    ylim(ax, [0 1]);  yticks(ax, [0 0.5 1]);
    xlabel(ax, 'Signed onset asynchrony (ms)');
    ylabel(ax, 'P(rightward)');
    title(ax, 'Psychometric function by eccentricity ratio');
    if ~isempty(h);  legend(ax, h, lbl, 'Location', 'northwest', 'FontSize', 8);  end
    set(ax, 'LineWidth', 1, 'FontSize', 11);  box(ax, 'off');
    hold(ax, 'off');
end

function plotRatioSummary(ax, G, cmap)
    x = 1:numel(G);
    hold(ax, 'on');
    yyaxis(ax, 'left');
    plot(ax, x, [G.pse], '-k', 'LineWidth', 1);
    scatter(ax, x, [G.pse], 70, cmap, 'filled');
    ylabel(ax, 'PSE (ms)');
    yyaxis(ax, 'right');
    plot(ax, x, [G.threshold], '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1);
    scatter(ax, x, [G.threshold], 70, cmap, 's');
    ylabel(ax, 'Threshold (ms)');
    set(ax, 'XTick', x, 'XTickLabel', {G.label}, 'XLim', [0.5 numel(G) + 0.5], ...
        'LineWidth', 1, 'FontSize', 10);
    title(ax, 'PSE (circles, left) / threshold (squares, right)');
    box(ax, 'off');
    hold(ax, 'off');
end
