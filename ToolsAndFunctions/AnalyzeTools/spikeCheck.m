function spikesummary = spikeCheck(spike, waveform, cd, savePath, plotFlag)
% Spike quality check: an interactive per-unit browser, standalone and callable
% right after loading the spike raster (and optionally the waveform product).
%
%   spike    - online_spike product: .data (units x trials x bins, 1 ms binary
%              raster), .timeseq.relative_time, .info.
%   waveform - online_spike_waveform product (same row order), or [] / omitted.
%              When empty the waveform-dependent panels show "No waveform file".
%   cd       - trials table (task, outcome, timing markers per trial).
%   savePath - (optional) export folder for the exclusion CSV and the QC summary
%              (used by the GUI's Export Summary button and, when set, by a
%              headless call -- see plotFlag); '' turns persistence/export off.
%              Export writes this session's spike temp CSV and merges it with the
%              behavior temp into the per-monkey master via ExportQCSummary.
%   plotFlag - (optional, default true) draw the GUI. false runs headless: no
%              figure is created and the function returns spikesummary. When
%              savePath is set, a headless call also computes every unit's full
%              metrics (waveform-dependent SNR / width / PCA) and merges the
%              session into the master QC summary, exactly like the Export Summary
%              button.
%
% Returns spikesummary, a table of per-unit column vectors: Channel, Unit, AvgFR
% (overall firing rate, Hz), ViolationRate (overall ISI-violation rate).
%
% Computation is separated from visualization: the per-unit numbers are assembled
% by computeUnit (pure, no graphics) from the reusable spike-computation functions
% (SpikeTrialAlignmentCheck, spikeAvgWindow, AlignSpikeSequence,
% AverageFiringRateBetween, gatherUnitSpikeTimes, computeISI,
% gatherUnitWaveforms, extractWaveformFeatures, spikeWaveformPCA). The panels
% (plotFiringPanel / plotISIPanel / plotWaveformPanel / plotPCAPanel) only render.
% The firing + ISI panels rely on the spike binary raster; the waveform + PCA
% panels rely on the waveform file.
%
% Xuefei Yu Jul 2026

    if nargin < 4;  savePath = '';  end
    if nargin < 5 || isempty(plotFlag);  plotFlag = true;  end
    RATE_THRESH = 5;      % Hz; baseline / overall firing below this is flagged
    WAVE_FS     = 30000;  % Hz; Blackrock NEV online waveform sample rate
    REASONS     = {'ISI violation', 'Unit Loss', 'Bad Isolation', 'Noise', 'Other'};
    haveWave    = ~isempty(waveform) && isfield(waveform, 'waveform');

    S = struct([]);
    if isempty(spike) || ~isfield(spike, 'data') || isempty(spike.data)
        disp('No spike raster to check.');
        return
    end

    chan     = spike.info.Channel_Number(:);
    unit     = spike.info.Unit_No(:);
    nRow     = numel(chan);
    channels = unique(chan, 'stable');
    relTime  = spike.timeseq.relative_time(:).';   % 1 x maxBins, s from Start
    AveMarker = {'Start', 'End'};
    T        = SpikeTrialAlignmentCheck(spike, cd, AveMarker); %Check the alignment between spikes and trials.

    % Shared per-unit task palette so a task means one colour across panels.
    present = T.valid & ~cellfun(@isempty, T.task);
    utasks  = unique(T.task(present), 'stable');
    cmap    = lines(max(numel(utasks), 1));

    % --- RASTER GROUP: baseline firing (units x trials), computed once ------
    % Average trials between start and end.
    bMarker = T.(AveMarker{1});
    bWin = [zeros(size(bMarker,1),1), T.(AveMarker{2}) - T.(AveMarker{1})];

    alignedBase = AlignSpikeSequence(spike, bMarker, [0 max([bWin(:,2); 0])]);
    baseRate    = AverageFiringRateBetween(alignedBase, bWin);
    [~, allCount, allDur] = AverageFiringRateBetween(spike, ...
        [relTime(1), relTime(end) + 1/spike.info.samplingrate]);
    overallRate = sum(allCount, 2, 'omitnan') ./ sum(allDur, 2, 'omitnan');   % units x 1

    % Overall ISI-violation rate: prefer the value precomputed by the loader
    % (spike.info.ViolationRate, a full-train timing metric that needs no
    % waveform). haveViol=false falls back to the waveform-based path below.
    haveViol = isfield(spike.info, 'ViolationRate') && numel(spike.info.ViolationRate) == nRow;
    if haveViol;  overallViol = spike.info.ViolationRate(:);  else;  overallViol = nan(nRow, 1);  end

    % --- exclusion labels + per-unit metric store --------------------------
    if isempty(savePath)
        exclFile = '';
    else
        exclFile = fullfile(savePath, 'unit_qc_exclusions.csv');
    end
    S = repmat(struct('Channel', NaN, 'Unit', NaN, 'overallRate', NaN, ...
        'baselineMeanRate', NaN, 'violationRate', NaN, ...
        'snr', NaN, 'widthMs', NaN, 'peakToValley', NaN, 'pcaRatio', NaN, ...
        'Excluded', false, 'Reason', '', 'Note', ''), nRow, 1);
    excl = loadExclusions(exclFile, chan, unit);
    for k = 1:nRow
        S(k).Channel  = chan(k);
        S(k).Unit     = unit(k);
        S(k).Excluded = excl(k).excluded;
        S(k).Reason   = excl(k).reason;
        S(k).Note     = excl(k).note;
    end

    % --- returned summary: cheap, no waveform / feature / PCA work ----------
    % overallRate is already vectorised over all units (computed above), so
    % AvgFR needs no loop. The overall violation rate comes from the loader's
    % precomputed value (no waveform touched); the legacy fallback below only
    % runs for older spike products, and then only when waveforms are present
    % (raster-quantised times give a meaningless violation).
    if haveViol
        violationRate = overallViol;
    else
        violationRate = nan(nRow, 1);
        if haveWave
            for rr = 1:nRow
                tc = gatherUnitSpikeTimes(spike, waveform, rr);
                [~, violationRate(rr)] = computeISI(tc, 0.001);
            end
        end
    end
   

     column_names = {'Channel','Unit','AvgFR','ViolationRate','Excluded'};
     spikesummary = table(chan, unit, overallRate, violationRate,[S.Excluded]','VariableNames',column_names);
     


    if ~plotFlag
        % headless: no figure. With a savePath, also compute every unit's full
        % metrics and merge the session into the master QC summary (same as the
        % Export Summary button).
        if ~isempty(savePath)
            masterFile = exportQC();
            if ~isempty(masterFile);  fprintf('Exported %s\n', masterFile);  end
        end
        return
    end

    % =====================================================================
    % GUI
    % =====================================================================
    fig = figure('Name', 'Quality check: spikes', 'Color', 'w', ...
                 'Position', [60 60 1300 900]);

    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.01 0.93 0.14 0.03], 'String', 'Channel', ...
        'BackgroundColor', 'w', 'FontWeight', 'bold', 'HorizontalAlignment', 'left');
    chanList = uicontrol(fig, 'Style', 'popupmenu', 'Units', 'normalized', ...
        'Position', [0.01 0.89 0.14 0.04], 'String', cellstr(num2str(channels)), ...
        'Callback', @onChannel);
    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.01 0.84 0.14 0.03], 'String', 'Unit', ...
        'BackgroundColor', 'w', 'FontWeight', 'bold', 'HorizontalAlignment', 'left');
    unitList = uicontrol(fig, 'Style', 'popupmenu', 'Units', 'normalized', ...
        'Position', [0.01 0.80 0.14 0.04], 'String', {' '}, 'Callback', @onUnit);
    uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', ...
        'Position', [0.01 0.73 0.065 0.05], 'String', '< Prev', 'Callback', @(~,~) step(-1));
    uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', ...
        'Position', [0.085 0.73 0.065 0.05], 'String', 'Next >', 'Callback', @(~,~) step(1));

    exclChk = uicontrol(fig, 'Style', 'checkbox', 'Units', 'normalized', ...
        'Position', [0.01 0.675 0.14 0.03], 'String', 'Exclude unit', ...
        'BackgroundColor', 'w', 'FontWeight', 'bold', 'Callback', @(~,~) onExclusion());
    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.01 0.645 0.14 0.025], 'String', 'Reason', ...
        'BackgroundColor', 'w', 'HorizontalAlignment', 'left');
    reasonPop = uicontrol(fig, 'Style', 'popupmenu', 'Units', 'normalized', ...
        'Position', [0.01 0.605 0.14 0.04], 'String', REASONS, 'Callback', @(~,~) onExclusion());
    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.01 0.565 0.14 0.025], 'String', 'Note', ...
        'BackgroundColor', 'w', 'HorizontalAlignment', 'left');
    noteEdit = uicontrol(fig, 'Style', 'edit', 'Units', 'normalized', ...
        'Position', [0.01 0.49 0.14 0.075], 'String', '', 'Max', 2, 'Min', 0, ...
        'HorizontalAlignment', 'left', 'Callback', @(~,~) onExclusion());

    statusTxt = uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.01 0.36 0.14 0.12], 'String', '', 'BackgroundColor', 'w', ...
        'HorizontalAlignment', 'left', 'FontSize', 9);

    uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', ...
        'Position', [0.01 0.30 0.14 0.05], 'String', 'Export Summary', ...
        'Callback', @(~,~) onExportSummary());

    pnl = uipanel(fig, 'Units', 'normalized', 'Position', [0.17 0.02 0.82 0.96], ...
        'BackgroundColor', 'w', 'BorderType', 'none');
    axFR  = axes('Parent', pnl, 'Position', [0.08 0.58 0.40 0.34]);
    axISI = axes('Parent', pnl, 'Position', [0.58 0.58 0.40 0.34]);
    axWF  = axes('Parent', pnl, 'Position', [0.08 0.30 0.40 0.19]);
    axPCA = axes('Parent', pnl, 'Position', [0.58 0.08 0.38 0.42]);
    featTable = uitable('Parent', pnl, 'Units', 'normalized', ...
        'Position', [0.08 0.05 0.40 0.19], 'Data', {}, ...
        'ColumnName', {'nSpk', 'Rate(Hz)', 'Viol', 'SNR', 'Width(ms)', 'P2V(uV)'});

    exclBanner = uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.17 0.955 0.82 0.035], 'String', '', ...
        'ForegroundColor', [0.8 0 0], 'BackgroundColor', 'w', 'FontWeight', 'bold', ...
        'FontSize', 11, 'HorizontalAlignment', 'center', 'Visible', 'off');

    curRow = 1;
    selectRow(1);

    % Block here until the user closes the QC window; ScreenSession downstream
    % consumes the exclusions decided in the GUI. uiwait returns when fig is
    % deleted (the window's close button already deletes it), so no custom close
    % handler is needed, and callbacks keep working while paused.
    disp('Waiting for spike screening, will continue after close the spike gui...')
    uiwait(fig);

    % Return the exclusions the user set in the GUI. S is updated live by
    % onExclusion; spikesummary was built pre-GUI, so refresh its column now.
    if ~isempty(S)
        spikesummary.Excluded = [S.Excluded]';
    end

    % ---------------- GUI callbacks --------------------------------------
    function onChannel(~, ~)
        ch = channels(chanList.Value);
        us = unit(chan == ch);
        unitList.String = cellstr(num2str(us));
        unitList.Value  = 1;
        selectRow(find(chan == ch & unit == us(1), 1));
    end

    function onUnit(~, ~)
        ch = channels(chanList.Value);
        us = unit(chan == ch);
        selectRow(find(chan == ch & unit == us(unitList.Value), 1));
    end

    function step(d)
        selectRow(mod(curRow - 1 + d, nRow) + 1);
    end

    function selectRow(r)
        curRow = r;
        chanList.Value  = find(channels == chan(r), 1);
        us              = unit(chan == chan(r));
        unitList.String = cellstr(num2str(us));
        unitList.Value  = find(us == unit(r), 1);
        syncExclusionControls(r);
        redraw();
    end

    function redraw()
        st = computeUnit(curRow);
        plotFiringPanel(axFR,  st.firing, T, cmap, RATE_THRESH);
        plotISIPanel(axISI,    st.isi, cmap);
        plotWaveformPanel(axWF, st.waveform, cmap);
        plotPCAPanel(axPCA,    st.pca, cmap);
        fillSummaryTable(featTable, utasks, st);
        storeMetrics(curRow, st);
        statusTxt.String = sprintf('Ch %d/%d  Unit %d\n(%d / %d units)\nOverall %.2f Hz', ...
            chan(curRow), numel(channels), unit(curRow), curRow, nRow, st.firing.overall);
    end

    function syncExclusionControls(r)
        exclChk.Value = S(r).Excluded;
        ri = find(strcmp(REASONS, S(r).Reason), 1);
        if isempty(ri);  ri = 1;  end
        reasonPop.Value    = ri;
        noteEdit.String    = S(r).Note;
        setExclusionEnable(S(r).Excluded);
        refreshBanner(r);
    end

    function onExclusion()
        r = curRow;
        S(r).Excluded = logical(exclChk.Value);
        S(r).Reason   = REASONS{reasonPop.Value};
        nt = noteEdit.String;
        if iscell(nt);            nt = strjoin(nt, ' ');
        elseif size(nt, 1) > 1;   nt = strjoin(cellstr(nt), ' ');  end
        S(r).Note     = strtrim(regexprep(nt, '\s+', ' '));
        setExclusionEnable(S(r).Excluded);
        refreshBanner(r);
        saveExclusions(exclFile, chan, unit, S);
    end

    function setExclusionEnable(on)
        % Reason is an exclusion reason, gated by the checkbox; the note box is
        % always editable so a unit can be annotated without being excluded.
        if on;  st = 'on';  else;  st = 'off';  end
        reasonPop.Enable   = st;
        noteEdit.Enable    = 'on';
    end

    function refreshBanner(r)
        if S(r).Excluded
            if isempty(S(r).Note)
                msg = sprintf('EXCLUDED  -  %s', S(r).Reason);
            else
                msg = sprintf('EXCLUDED  -  %s: %s', S(r).Reason, S(r).Note);
            end
            exclBanner.String  = msg;
            exclBanner.Visible = 'on';
        else
            exclBanner.Visible = 'off';
        end
    end

    function onExportSummary()
        if isempty(savePath)
            statusTxt.String = 'No savePath: cannot export summary.';
            return
        end
        set(fig, 'Pointer', 'watch');  drawnow;
        summaryFile = exportQC();
        set(fig, 'Pointer', 'arrow');

        if isempty(S)
            msg = 'QC summary exported (no spikes).';
        else
            msg = 'QC summary exported (behavior + spikes).';
        end
        if ~isempty(summaryFile)
            statusTxt.String = {msg; summaryFile};
            fprintf('Exported %s\n', summaryFile);
        else
            statusTxt.String = msg;
        end
    end

    % Compute every unit's full metrics, write this session's spike temp CSV, and
    % merge the two per-session temps into the master QC summary. Shared by the
    % Export Summary button and the headless (savePath) path; caller checks
    % savePath is non-empty. Fills S via computeUnit (waveform-dependent).
    function masterFile = exportQC()
        for ii = 1:nRow
            storeMetrics(ii, computeUnit(ii));
        end
        writeSpikeSummary(S, savePath);
        % Normal flow: behaviorCheck already wrote the behavior temp for this
        % session. Standalone use (spikeCheck without a prior behavior check)
        % falls back to writing it here from cd so behavior still merges in.
        [monkey, dateStr, dataRoot] = parseSessionPath(savePath);
        if isempty(monkey);  monkey = 'unknown';  end
        behaviorTemp = fullfile(dataRoot, 'Summary', 'temp', ...
            sprintf('%s_%s_behavior.csv', monkey, dateStr));
        if exist(behaviorTemp, 'file') ~= 2
            writeBehaviorSummary(behaviorCheck(cd, false), savePath);
        end
        masterFile = ExportQCSummary(savePath);
    end

    % ---------------- pure per-unit compute (no graphics) ----------------
    function st = computeUnit(r)
        st.firing   = firingStats(r);
        st.isi      = isiStats(r);
        [st.waveform, st.pca] = waveformStats(r);
    end

    function fr = firingStats(r)
        rate = baseRate(r, :).';
        nTr  = numel(rate);
        fr.rate        = rate;
        fr.overall     = overallRate(r);
        fr.meanRateAll = mean(rate, 'omitnan');

        % Per-trial task colour index (NaN when the trial's task is not shown).
        fr.trialCi = nan(nTr, 1);
        for j = 1:nTr
            ci = find(strcmp(utasks, T.task{j}), 1);
            if ~isempty(ci);  fr.trialCi(j) = ci;  end
        end

        % Per-task mean +- std (merged blocks), for the summary table.
        fr.tasks = struct('Task', {}, 'meanRate', {}, 'stdRate', {}, 'nTrials', {});
        for t = 1:numel(utasks)
            sel = strcmp(T.task, utasks{t}) & ~isnan(rate);
            if ~any(sel);  continue;  end
            fr.tasks(end+1) = struct('Task', utasks{t}, 'meanRate', mean(rate(sel)), ...
                'stdRate', std(rate(sel)), 'nTrials', nnz(sel));
        end

        % Per contiguous block: shading index + its own mean/std for the label.
        blocks   = contiguousBlocks(T.task);
        fr.blocks = struct('name', {}, 'first', {}, 'last', {}, 'ci', {}, ...
                           'mean', {}, 'std', {});
        for b = 1:numel(blocks)
            ci = find(strcmp(utasks, blocks(b).name), 1);
            if isempty(ci);  continue;  end
            rv = rate(blocks(b).first:blocks(b).last);  rv = rv(~isnan(rv));
            if isempty(rv);  mu = NaN;  sd = NaN;  else;  mu = mean(rv);  sd = std(rv);  end
            fr.blocks(end+1) = struct('name', blocks(b).name, 'first', blocks(b).first, ...
                'last', blocks(b).last, 'ci', ci, 'mean', mu, 'std', sd);
        end
    end

    function is = isiStats(r)
        tc = gatherUnitSpikeTimes(spike, waveform, r);   % precise if waveform present

        isiByTask    = cell(numel(utasks), 1);
        countsByTask = zeros(numel(utasks), 1);
        violByTask   = nan(numel(utasks), 1);
        for t = 1:numel(utasks)
            tmask = strcmp(T.task, utasks{t});
            [isiByTask{t}, v] = computeISI(tc(tmask), 0.001);
            countsByTask(t)   = sum(cellfun(@numel, tc(tmask)));
            if haveWave;  violByTask(t) = v;  end   % raster violation is meaningless
        end
        [allIsi, violAll] = computeISI(tc, 0.001);

        is.isiByTask     = isiByTask;
        is.countsByTask  = countsByTask;
        is.totalSpikes   = sum(cellfun(@numel, tc));
        is.violationByTask = violByTask;
        % Overall violation: the loader's precomputed value when present, else the
        % waveform-based fallback. Per-task violation stays waveform-based (above).
        if haveViol
            is.violationRate = overallViol(r);
        elseif haveWave
            is.violationRate = violAll;
        else
            is.violationRate = NaN;
        end

        % Stacked histogram data (raster or waveform_time, whichever tc used).
        is.hasData = ~isempty(allIsi);
        if is.hasData
            edges  = linspace(0, min(0.05, max(allIsi)), 40);
            counts = zeros(numel(edges)-1, numel(utasks));
            for t = 1:numel(utasks)
                if ~isempty(isiByTask{t})
                    counts(:, t) = histcounts(isiByTask{t}, edges).';
                end
            end
            is.centers = edges(1:end-1) + diff(edges)/2;
            is.counts  = counts;
        end
    end

    function [wf, pca] = waveformStats(r)
        wf = struct('hasFile', haveWave, 'tms', [], ...
            'byTask', struct('task', {}, 'ci', {}, 'W', {}, 'meanW', {}, ...
                             'snr', {}, 'widthMs', {}, 'peakToValley', {}, 'nSpikes', {}), ...
            'overall', struct('snr', NaN, 'widthMs', NaN, 'peakToValley', NaN));

        if ~haveWave
            pca = struct('status', 'nowave', 'score', zeros(0,3), ...
                'labels', zeros(0,1), 'centroids', [], 'ratio', NaN);
            return
        end

        nSamp  = size(waveform.waveform, 4);
        wf.tms = (0:nSamp-1) / WAVE_FS * 1000;
        Wall   = zeros(0, nSamp);
        labAll = [];
        allW   = zeros(0, nSamp);
        for t = 1:numel(utasks)
            Wt = gatherUnitWaveforms(waveform, T, r, strcmp(T.task, utasks{t}));
            Wall   = [Wall; Wt];  labAll = [labAll; t*ones(size(Wt,1),1)]; %#ok<AGROW>
            if isempty(Wt);  continue;  end
            f = extractWaveformFeatures(Wt, WAVE_FS);
            wf.byTask(end+1) = struct('task', utasks{t}, 'ci', t, 'W', Wt, ...
                'meanW', mean(Wt, 1, 'omitnan'), 'snr', f.snr, 'widthMs', f.widthMs, ...
                'peakToValley', f.peakToValley, 'nSpikes', f.nSpikes);
            allW = [allW; Wt]; %#ok<AGROW>
        end
        if ~isempty(allW)
            fAll = extractWaveformFeatures(allW, WAVE_FS);
            wf.overall = struct('snr', fAll.snr, 'widthMs', fAll.widthMs, ...
                                'peakToValley', fAll.peakToValley);
        end
        pca = spikeWaveformPCA(Wall, labAll, numel(utasks));
    end

    function storeMetrics(r, st)
        S(r).overallRate      = st.firing.overall;
        S(r).baselineMeanRate = st.firing.meanRateAll;
        S(r).violationRate    = st.isi.violationRate;
        S(r).snr              = st.waveform.overall.snr;
        S(r).widthMs          = st.waveform.overall.widthMs;
        S(r).peakToValley     = st.waveform.overall.peakToValley;
        S(r).pcaRatio         = st.pca.ratio;
    end

end


% =========================================================================
% PLOT LAYER — render only; reads the computed struct, derives no numbers
% =========================================================================

function plotFiringPanel(ax, fr, T, cmap, thresh)
% Baseline firing rate per trial: a connected grey curve with per-trial markers
% (filled = successful, open = unsuccessful, coloured by task) over task-shaded
% blocks, each labelled with its own mean +- std (bold when < thresh). Overall
% rate in the title (red when < thresh).
    cla(ax, 'reset');  hold(ax, 'on');
    rate = fr.rate;  nTr = numel(rate);  x = (1:nTr).';
    yTop = max([rate; 1], [], 'omitnan');

    for b = 1:numel(fr.blocks)
        fb = fr.blocks(b);
        patch(ax, [fb.first-0.5 fb.last+0.5 fb.last+0.5 fb.first-0.5], ...
            [0 0 yTop yTop], cmap(fb.ci,:), 'FaceAlpha', 0.10, 'EdgeColor', 'none');
    end
    plot(ax, x, rate, '-', 'Color', [0.6 0.6 0.6], 'LineWidth', 0.75);
    for j = 1:nTr
        if isnan(rate(j));  continue;  end
        if isnan(fr.trialCi(j));  col = [0.4 0.4 0.4];  else;  col = cmap(fr.trialCi(j),:);  end
        if T.success(j)
            plot(ax, x(j), rate(j), 'o', 'MarkerFaceColor', col, ...
                'MarkerEdgeColor', col, 'MarkerSize', 5);
        else
            plot(ax, x(j), rate(j), 'o', 'MarkerEdgeColor', col, ...
                'MarkerFaceColor', 'none', 'MarkerSize', 5);
        end
    end
    for b = 1:numel(fr.blocks)
        fb = fr.blocks(b);
        if isnan(fb.mean);  continue;  end
        if fb.mean < thresh;  tw = 'bold';  else;  tw = 'normal';  end
        text(ax, mean([fb.first fb.last]), yTop*1.02, ...
            sprintf('%s\n%.1f \\pm %.1f Hz', strrep(fb.name, '_', ' '), fb.mean, fb.std), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'Color', cmap(fb.ci,:)*0.6, 'FontWeight', tw, 'FontSize', 8);
    end

    xlim(ax, [0.5 nTr+0.5]);
    ylim(ax, [0 yTop*1.30 + eps]);
    xlabel(ax, 'Trial number');
    ylabel(ax, {'Average firing rate (Hz)', '(Start to End)'});
    if fr.overall < thresh;  tcol = [0.85 0 0];  else;  tcol = [0 0 0];  end
    title(ax, sprintf('Overall %.2f Hz   (threshold %g Hz)', fr.overall, thresh), 'Color', tcol);
    set(ax, 'LineWidth', 1, 'FontSize', 10);
    box(ax, 'off');
end


function plotISIPanel(ax, is, cmap)
% Stacked ISI histogram by task with the < 1 ms violation region shaded; the
% overall violation rate is the only text (per-task rates go in the table).
    cla(ax, 'reset');  hold(ax, 'on');
    if ~is.hasData
        blankPanel(ax, 'Too few spikes for ISI');
        return
    end
    hb = bar(ax, is.centers*1000, is.counts, 'stacked', 'EdgeColor', 'none');
    for t = 1:numel(hb);  hb(t).FaceColor = cmap(t,:);  end

    yl = ylim(ax);
    hvp = patch(ax, [0 1 1 0], [0 0 yl(2) yl(2)], [0.85 0.1 0.1], ...
        'FaceAlpha', 0.12, 'EdgeColor', 'none');
    uistack(hvp, 'bottom');
    ylim(ax, yl);

    if isnan(is.violationRate);  vs = 'N/A';  else;  vs = sprintf('%.3f%%', 100*is.violationRate);  end
    text(ax, 0.98, 0.97, sprintf('<1ms violation: %s', vs), 'Units', 'normalized', ...
        'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'FontSize', 8);

    xlabel(ax, 'ISI (ms)');
    ylabel(ax, 'Count');
    title(ax, 'Inter-spike interval');
    set(ax, 'LineWidth', 1, 'FontSize', 10);
    box(ax, 'off');
end


function plotWaveformPanel(ax, wf, cmap)
% Waveforms by task: pale translucent individuals behind, task means thick on top.
% "No waveform file" when the waveform product was not supplied.
    cla(ax, 'reset');  hold(ax, 'on');
    if ~wf.hasFile
        blankPanel(ax, 'No waveform file');
        return
    end
    if isempty(wf.byTask)
        blankPanel(ax, 'No waveforms for this unit');
        return
    end
    MAXDRAW = 200;
    for t = 1:numel(wf.byTask)
        W   = wf.byTask(t).W;
        idx = 1:size(W,1);
        if numel(idx) > MAXDRAW;  idx = idx(round(linspace(1, numel(idx), MAXDRAW)));  end
        pale = cmap(wf.byTask(t).ci,:)*0.45 + 0.55;
        plot(ax, wf.tms, W(idx,:).', 'Color', [pale 0.06]);
    end
    for t = 1:numel(wf.byTask)
        plot(ax, wf.tms, wf.byTask(t).meanW, 'Color', cmap(wf.byTask(t).ci,:), 'LineWidth', 2);
    end
    xlabel(ax, 'Time (ms)');
    ylabel(ax, '\muV');
    title(ax, 'Waveforms by task');
    set(ax, 'LineWidth', 1, 'FontSize', 10);
    box(ax, 'off');
end


function plotPCAPanel(ax, P, cmap)
% Waveforms on PC1-3 coloured by task with a centroid per task; title carries the
% within/between cluster ratio. "No waveform file" when none was supplied.
    cla(ax, 'reset');  hold(ax, 'on');
    switch P.status
        case 'nowave';  blankPanel(ax, 'No waveform file');                  return
        case 'few';     blankPanel(ax, 'Too few waveforms for PCA');         return
        case 'rankdef'; blankPanel(ax, 'Waveforms rank-deficient for 3 PCs'); return
    end

    set(ax, 'SortMethod', 'childorder');
    for t = 1:size(P.centroids, 1)
        sel = P.labels == t;
        if ~any(sel);  continue;  end
        scatter3(ax, P.score(sel,1), P.score(sel,2), P.score(sel,3), 6, cmap(t,:), ...
            'filled', 'MarkerFaceAlpha', 0.3);
    end
    for t = 1:size(P.centroids, 1)
        if any(isnan(P.centroids(t,:)));  continue;  end
        plot3(ax, P.centroids(t,1), P.centroids(t,2), P.centroids(t,3), 'p', ...
            'MarkerSize', 16, 'MarkerFaceColor', cmap(t,:), 'MarkerEdgeColor', 'k', ...
            'LineWidth', 1.25);
    end
    xlabel(ax, 'PC1');  ylabel(ax, 'PC2');  zlabel(ax, 'PC3');
    view(ax, 3);  grid(ax, 'on');
    title(ax, sprintf('Waveform PCA (within/between = %s)', num2sig(P.ratio)));
    set(ax, 'LineWidth', 1, 'FontSize', 10);
end


function fillSummaryTable(featTable, utasks, st)
% Per-task summary table (one row per task + 'All'): counts / rate /
% violation from the raster group, SNR / width / P2V from the waveform group.
    tbl   = cell(0, 6);
    rowNm = {};
    for t = 1:numel(utasks)
        w = findByTask(st.waveform.byTask, utasks{t});
        tbl(end+1,:) = {st.isi.countsByTask(t), sigOrNa(rateByTask(st.firing, utasks{t})), ...
            violCell(st.isi.violationByTask(t)), ...
            wfCell(w, 'snr', 2), wfCell(w, 'widthMs', 3), wfCell(w, 'peakToValley', 1)}; %#ok<AGROW>
        rowNm{end+1} = strrep(utasks{t}, '_', ' '); %#ok<AGROW>
    end
    tbl(end+1,:) = {st.isi.totalSpikes, sigOrNa(st.firing.meanRateAll), ...
        violCell(st.isi.violationRate), ...
        wfCell(st.waveform.overall, 'snr', 2), wfCell(st.waveform.overall, 'widthMs', 3), ...
        wfCell(st.waveform.overall, 'peakToValley', 1)};
    rowNm{end+1} = 'All';

    featTable.Data      = tbl;
    featTable.RowName    = rowNm;
    featTable.ColumnName = {'nSpk', 'Rate(Hz)', 'Viol', 'SNR', 'Width(ms)', 'P2V(uV)'};
end


function x = rateByTask(fr, name)
    x = NaN;
    for i = 1:numel(fr.tasks)
        if strcmp(fr.tasks(i).Task, name);  x = fr.tasks(i).meanRate;  return;  end
    end
end


function wf = findByTask(byTask, name)
    wf = [];
    for i = 1:numel(byTask)
        if strcmp(byTask(i).task, name);  wf = byTask(i);  return;  end
    end
end


function c = wfCell(wf, field, digits)
    if isempty(wf) || ~isfield(wf, field) || isnan(wf.(field))
        c = 'n/a';
    else
        c = round(wf.(field), digits);
    end
end


function c = violCell(x)
    if isnan(x);  c = 'n/a';  else;  c = sprintf('%.3f%%', 100*x);  end
end


function s = sigOrNa(x)
    if isnan(x);  s = 'n/a';  else;  s = round(x, 2);  end
end


function s = num2sig(x)
    if isnan(x);  s = 'n/a';  else;  s = sprintf('%.2f', x);  end
end


% =========================================================================
% Per-unit QC label persistence (unit_qc_exclusions.csv)
% =========================================================================
function excl = loadExclusions(exclFile, chan, unit)
% Seed per-unit exclusion + note state from the saved CSV, matched by
% (Channel, Unit). The Excluded column lets a note-only row load un-excluded; a
% legacy file with no Excluded column is read as all rows excluded (the old
% "listed == excluded" convention). Both the new 'Note' column and the legacy
% 'Comment' column are accepted for the note text.
    n    = numel(chan);
    excl = repmat(struct('excluded', false, 'reason', '', 'note', ''), n, 1);
    if isempty(exclFile) || exist(exclFile, 'file') ~= 2
        return
    end
    try
        Tb = readtable(exclFile, 'TextType', 'string');
    catch
        return
    end
    if isempty(Tb) || ~all(ismember({'Channel', 'Unit'}, Tb.Properties.VariableNames))
        return
    end
    [tf, loc] = ismember([chan, unit], [Tb.Channel, Tb.Unit], 'rows');
    hasReason   = ismember('Reason',   Tb.Properties.VariableNames);
    hasExcluded = ismember('Excluded', Tb.Properties.VariableNames);
    if     ismember('Note',    Tb.Properties.VariableNames);  noteVar = 'Note';
    elseif ismember('Comment', Tb.Properties.VariableNames);  noteVar = 'Comment';
    else;                                                     noteVar = '';
    end
    for k = find(tf(:).')
        if hasExcluded
            excl(k).excluded = logical(Tb.Excluded(loc(k)));
        else
            excl(k).excluded = true;   % legacy file: every listed row was excluded
        end
        if hasReason;         excl(k).reason = safeStr(Tb.Reason(loc(k)));       end
        if ~isempty(noteVar); excl(k).note   = safeStr(Tb.(noteVar)(loc(k)));    end
    end
end


function saveExclusions(exclFile, chan, unit, S)
% Persist units that are excluded OR carry a note, overwriting so a unit that is
% neither excluded nor annotated disappears. The Excluded column distinguishes a
% note-only row from an exclusion. No-op when persistence is off.
    if isempty(exclFile);  return;  end
    hasNote = ~cellfun(@isempty, {S.Note});
    sel     = logical([S.Excluded]) | hasNote;
    Tb  = table(chan(sel), unit(sel), double([S(sel).Excluded])', ...
        string({S(sel).Reason})', string({S(sel).Note})', ...
        'VariableNames', {'Channel', 'Unit', 'Excluded', 'Reason', 'Note'});
    try
        writetable(Tb, exclFile);
    catch ME
        warning('spikeCheck:saveExclusions', 'Could not write %s: %s', exclFile, ME.message);
    end
end


function s = safeStr(x)
% Coerce a table cell (string / char / cellstr / NaN) to a plain char row.
    if isstring(x)
        if ismissing(x);  s = '';  else;  s = char(x);  end
    elseif iscell(x)
        s = char(x);
    elseif ischar(x)
        s = x;
    elseif isnumeric(x) && all(isnan(x))
        s = '';
    else
        s = char(string(x));
    end
end
