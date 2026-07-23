function rfsummary = RFPlot(data, extra, plotFlag, savePath, reCompute)
% Receptive-field analysis for the visual saccade task: an interactive per-unit
% browser (RF heatmap + 16 spatial PSTHs), built from the OFFLINE spike raster.
%
% Ported from the online reference OnlinePlotBlackRock/jivesLink/
% plotJivesReceptiveField.m (RF grid, spatial PSTHs, 2-D Gaussian fit), but driven
% by the exported online_spike product (data.spike) and the trials table
% (data.events) instead of the online `trials` global. The GUI, per-unit navigator,
% note field, per-unit caching, and cross-task summary CSV mirror spikeCheck.m.
%
%   data     - struct from BlackRockFileAnalyzer: .spike (online_spike raster),
%              .events (trials table, cd). Other fields (.RT/.eyes) are unused here.
%   extra    - reserved for cross-task data (unused; kept for dispatch symmetry).
%   plotFlag - (optional, default true) draw the GUI. false runs headless: no
%              figure; with a savePath every unit's RF is computed, cached, and
%              merged into the master analysis summary, then rfsummary is returned.
%   savePath - (optional) export folder (.../Monkey <name>/.../<date>). '' turns
%              persistence/export off. Used by the Export button, the headless path,
%              and the on-close cache write.
%   reCompute- (optional, default true) when false and savePath holds a cached
%              RFSummary.mat, per-unit RF params are seeded from cache (skips the
%              per-unit recompute); notes always come from unit_rf_notes.csv.
%
% Returns rfsummary, a per-unit table (Channel, Unit, RF fit params, peak FR, trial
% count, alignment/windows, Note).
%
% Computation is separated from visualization: computeUnit (pure, no graphics)
% assembles the per-unit RF grid + spatial PSTHs from the reusable spike helpers
% (SpikeTrialAlignmentCheck, gatherUnitSpikeTimes); plotHeatmap / drawSectorPanel
% only render.
%
% Xuefei Yu Jul 2026

    if nargin < 3 || isempty(plotFlag);   plotFlag  = true;  end
    if nargin < 4;                        savePath  = '';    end
    if nargin < 5 || isempty(reCompute);  reCompute = true;  end

    rfsummary = table();

    % ── Constants (from the reference) ────────────────────────────────────
    ACTIVE_TASK  = 'visual_saccades_experiment';  % this folder = this protocol
    RF_WIN_MS    = [50, 250];
    VIS_WIN_MS   = [-200, 600];
    BIN_MS       = 10;
    PSTH_SIGMA   = 20;
    SMOOTH_SIGMA = 2.5;
    GRID_EDGES   = -20:1:20;
    GRID_CTRS    = (GRID_EDGES(1:end-1) + GRID_EDGES(2:end)) / 2;
    ECC_NEAR     = 10;            % deg; near < ECC_NEAR, far >= ECC_NEAR
    RF_EXTRAP_MIN = 10;
    N_SECTORS    = 16;
    PSTH_CLR     = [0.20 0.50 0.90];
    RASTER_CLR   = [0.75 0.80 0.92];   % light ticks behind the PSTH
    WAVE_FS      = 30000;              % Blackrock NEV waveform sample rate (Hz)
    alignOpts    = {'Visual onset', 'Go signal (saccade)'};

    % Sector centre angles / eccentricity bins in axPS index order (1–16).
    SECTOR_ANGLES = [135, 90, 45, 135, 90, 45, 180, 0, 180, 0, 225, 270, 315, 225, 270, 315];
    SECTOR_NEAR   = logical([0,0,0, 1,1,1, 0,0,1,1, 1,1,1, 0,0,0]);
    deg = char(176);
    SECTOR_LABELS = cell(N_SECTORS, 1);
    for k = 1:N_SECTORS
        if SECTOR_NEAR(k);  ineq = '<';  else;  ineq = '>';  end
        SECTOR_LABELS{k} = sprintf('%d%s, %s%d', SECTOR_ANGLES(k), deg, ineq, ECC_NEAR);
    end

    % ── Guard: need a spike raster ────────────────────────────────────────
    if ~isfield(data, 'spike') || isempty(data.spike) || ~isfield(data.spike, 'data') ...
            || isempty(data.spike.data)
        disp('RFPlot: no spike raster to analyze.');
        return
    end
    spike = data.spike;
    cd    = data.events;

    chan  = spike.info.Channel_Number(:);
    unit  = spike.info.Unit_No(:);
    nRow  = numel(chan);
    channels = unique(chan, 'stable');
    start = spike.timeseq.alignedrawtime(:);          % trials x 1, abs Start (s)

    % ── Trial pairing: markers (abs s) + target positions, matched by
    %    (Session, Trial_number). T.outcome distinguishes 'correct' from 'wrong'.
    markerCols = {'Target_1_presented', 'Target_2_presented', 'Fixation_point_off', ...
        'Target_1_position_x', 'Target_1_position_y', ...
        'Target_2_position_x', 'Target_2_position_y'};
    T = SpikeTrialAlignmentCheck(spike, cd, markerCols);

    taskTrial = T.valid & strcmp(T.task, ACTIVE_TASK);          % this task's trials
    useTrial  = taskTrial & strcmp(T.outcome, 'correct');       % RF/PSTH: correct only

    % ── Per-unit store + note / cache seeding ─────────────────────────────
    S = repmat(struct('Channel', NaN, 'Unit', NaN, 'Note', '', ...
        'rf_x0', NaN, 'rf_y0', NaN, 'rf_sx', NaN, 'rf_sy', NaN, ...
        'rf_A', NaN, 'rf_B', NaN, 'rf_peakFR', NaN, 'nTrials', NaN, ...
        'alignMode', '', 'rfWinMs', [NaN NaN], 'psthWinMs', [NaN NaN]), nRow, 1);

    if isempty(savePath)
        noteFile  = '';
        cacheFile = '';
    else
        noteFile  = fullfile(savePath, 'AnalysisCache', 'unit_rf_notes.csv');
        cacheFile = fullfile(savePath, 'AnalysisCache', 'RFSummary.mat');
    end
    notes = loadNotes(noteFile, chan, unit);
    for k = 1:nRow
        S(k).Channel = chan(k);
        S(k).Unit    = unit(k);
        S(k).Note    = notes{k};
    end

    metricsFilled = false(nRow, 1);
    if ~reCompute && ~isempty(cacheFile) && exist(cacheFile, 'file')
        metricsFilled = seedFromCache(cacheFile);
    end

    % ── Headless path ─────────────────────────────────────────────────────
    if ~plotFlag
        if ~isempty(savePath)
            fillAllMetrics(RF_WIN_MS, VIS_WIN_MS, alignOpts{1});
            saveRFCache();
            master = exportRF(RF_WIN_MS, VIS_WIN_MS, alignOpts{1});
            if ~isempty(master);  fprintf('Exported %s\n', master);  end
        end
        rfsummary = buildUnitTable(ACTIVE_TASK, savePath);
        return
    end

    % =====================================================================
    % GUI
    % =====================================================================
    curRow = 1;
    fitOn  = false;
    % Last params applied by redraw, cached so the on-close persistence does not
    % read the (by then deleted) uicontrols.
    lastRfWin   = RF_WIN_MS;
    lastPsthWin = VIS_WIN_MS;
    lastAlign   = alignOpts{1};

    fig = figure('Name', 'Receptive field: visual saccade', 'Color', 'w', ...
        'Position', [50 40 1400 940]);

    % --- left control column ---------------------------------------------
    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', 'Position', [0.01 0.945 0.14 0.028], ...
        'String', 'Channel', 'BackgroundColor', 'w', 'FontWeight', 'bold', 'HorizontalAlignment', 'left');
    chanList = uicontrol(fig, 'Style', 'popupmenu', 'Units', 'normalized', 'Position', [0.01 0.910 0.14 0.035], ...
        'String', cellstr(num2str(channels)), 'Callback', @onChannel);
    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', 'Position', [0.01 0.875 0.14 0.028], ...
        'String', 'Unit', 'BackgroundColor', 'w', 'FontWeight', 'bold', 'HorizontalAlignment', 'left');
    unitList = uicontrol(fig, 'Style', 'popupmenu', 'Units', 'normalized', 'Position', [0.01 0.840 0.14 0.035], ...
        'String', {' '}, 'Callback', @onUnit);
    uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', 'Position', [0.01 0.795 0.065 0.040], ...
        'String', '< Prev', 'Callback', @(~,~) step(-1));
    uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', 'Position', [0.085 0.795 0.065 0.040], ...
        'String', 'Next >', 'Callback', @(~,~) step(1));

    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', 'Position', [0.01 0.755 0.14 0.025], ...
        'String', 'Alignment', 'BackgroundColor', 'w', 'HorizontalAlignment', 'left');
    alignDD = uicontrol(fig, 'Style', 'popupmenu', 'Units', 'normalized', 'Position', [0.01 0.720 0.14 0.035], ...
        'String', alignOpts, 'Callback', @onParamChange);

    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', 'Position', [0.01 0.685 0.14 0.025], ...
        'String', 'RF window (ms)', 'BackgroundColor', 'w', 'HorizontalAlignment', 'left');
    rfT0 = uicontrol(fig, 'Style', 'edit', 'Units', 'normalized', 'Position', [0.01 0.650 0.065 0.035], ...
        'String', num2str(RF_WIN_MS(1)), 'Callback', @onParamChange);
    rfT1 = uicontrol(fig, 'Style', 'edit', 'Units', 'normalized', 'Position', [0.085 0.650 0.065 0.035], ...
        'String', num2str(RF_WIN_MS(2)), 'Callback', @onParamChange);

    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', 'Position', [0.01 0.615 0.14 0.025], ...
        'String', 'PSTH window (ms)', 'BackgroundColor', 'w', 'HorizontalAlignment', 'left');
    psT0 = uicontrol(fig, 'Style', 'edit', 'Units', 'normalized', 'Position', [0.01 0.580 0.065 0.035], ...
        'String', num2str(VIS_WIN_MS(1)), 'Callback', @onParamChange);
    psT1 = uicontrol(fig, 'Style', 'edit', 'Units', 'normalized', 'Position', [0.085 0.580 0.065 0.035], ...
        'String', num2str(VIS_WIN_MS(2)), 'Callback', @onParamChange);

    psthChk = uicontrol(fig, 'Style', 'checkbox', 'Units', 'normalized', 'Position', [0.01 0.540 0.14 0.030], ...
        'String', 'Show PSTH', 'Value', 1, 'BackgroundColor', 'w', 'Callback', @onToggle);
    rasChk = uicontrol(fig, 'Style', 'checkbox', 'Units', 'normalized', 'Position', [0.01 0.508 0.14 0.030], ...
        'String', 'Show raster', 'Value', 0, 'BackgroundColor', 'w', 'Callback', @onToggle);

    uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', 'Position', [0.01 0.460 0.14 0.040], ...
        'String', 'Fit RF (2D Gaussian)', 'BackgroundColor', [0.30 0.70 0.40], ...
        'ForegroundColor', 'w', 'Callback', @(~,~) onFitRF());
    uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', 'Position', [0.01 0.415 0.14 0.040], ...
        'String', 'Show waveform', 'Callback', @(~,~) onShowWaveform());
    uicontrol(fig, 'Style', 'pushbutton', 'Units', 'normalized', 'Position', [0.01 0.370 0.14 0.040], ...
        'String', 'Export RF summary', 'Callback', @(~,~) onExport());

    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', 'Position', [0.01 0.330 0.14 0.025], ...
        'String', 'Note', 'BackgroundColor', 'w', 'HorizontalAlignment', 'left');
    noteEdit = uicontrol(fig, 'Style', 'edit', 'Units', 'normalized', 'Position', [0.01 0.250 0.14 0.078], ...
        'String', '', 'Max', 2, 'Min', 0, 'HorizontalAlignment', 'left', 'Callback', @(~,~) onNote());

    statusTxt = uicontrol(fig, 'Style', 'text', 'Units', 'normalized', 'Position', [0.01 0.100 0.14 0.130], ...
        'String', '', 'BackgroundColor', 'w', 'HorizontalAlignment', 'left', 'FontSize', 9);

    % --- right plot panel: heatmap + 16 spatial PSTHs (reference layout) ---
    pnl = uipanel(fig, 'Units', 'normalized', 'Position', [0.17 0.02 0.82 0.96], ...
        'BackgroundColor', 'w', 'BorderType', 'none');

    pw = 0.125;  ph = 0.135;  gx = 0.010;  gy = 0.012;
    gySep = 0.030;  gyHM = 0.050;  lm = 0.065;  rm = 0.010;  bm = 0.030;
    y5 = bm;
    y4 = y5 + ph + gySep;
    y3 = y4 + ph + gyHM;
    hmh = 2*ph + gy;
    y2 = y3 + hmh + 3*gy;
    y1 = y2 + ph + gySep;
    yWE = y3 + (hmh - ph)/2;
    x1L = lm;
    x2L = x1L + pw + gx;
    x6R = 1 - rm - pw;
    x5R = x6R - pw - gx;
    hmx = x2L + pw + gx;
    hmw = x5R - gx - hmx;
    xNS = hmx + hmw/2 - pw/2;

    axHM = axes('Parent', pnl, 'Units', 'normalized', 'Position', [hmx, y3, hmw, hmh]);
    axPS = gobjects(N_SECTORS, 1);
    axPS(1)  = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x1L, y1,  pw, ph]);
    axPS(2)  = axes('Parent', pnl, 'Units', 'normalized', 'Position', [xNS, y1,  pw, ph]);
    axPS(3)  = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x6R, y1,  pw, ph]);
    axPS(4)  = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x2L, y2,  pw, ph]);
    axPS(5)  = axes('Parent', pnl, 'Units', 'normalized', 'Position', [xNS, y2,  pw, ph]);
    axPS(6)  = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x5R, y2,  pw, ph]);
    axPS(7)  = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x1L, yWE, pw, ph]);
    axPS(9)  = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x2L, yWE, pw, ph]);
    axPS(10) = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x5R, yWE, pw, ph]);
    axPS(8)  = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x6R, yWE, pw, ph]);
    axPS(11) = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x2L, y4,  pw, ph]);
    axPS(12) = axes('Parent', pnl, 'Units', 'normalized', 'Position', [xNS, y4,  pw, ph]);
    axPS(13) = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x5R, y4,  pw, ph]);
    axPS(14) = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x1L, y5,  pw, ph]);
    axPS(15) = axes('Parent', pnl, 'Units', 'normalized', 'Position', [xNS, y5,  pw, ph]);
    axPS(16) = axes('Parent', pnl, 'Units', 'normalized', 'Position', [x6R, y5,  pw, ph]);

    selectRow(1);

    disp('Waiting for RF screening, will continue after close the RF gui...')
    uiwait(fig);

    % On close: fill + persist so a later reCompute=false run loads it. The figure
    % is already deleted here, so use the params cached by the last redraw rather
    % than reading the (now invalid) uicontrols.
    if ~isempty(savePath)
        fillAllMetrics(lastRfWin, lastPsthWin, lastAlign);
        saveRFCache();
    end
    rfsummary = buildUnitTable(ACTIVE_TASK, savePath);

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
        fitOn  = false;                          % new unit invalidates the fit overlay
        chanList.Value  = find(channels == chan(r), 1);
        us              = unit(chan == chan(r));
        unitList.String = cellstr(num2str(us));
        unitList.Value  = find(us == unit(r), 1);
        noteEdit.String = S(r).Note;
        redraw();
    end

    function onParamChange(~, ~)
        fitOn = false;                           % alignment/window change invalidates fit
        redraw();
    end

    function onToggle(~, ~)
        % At least one of PSTH / raster must stay on (raster off => PSTH on).
        if ~psthChk.Value && ~rasChk.Value
            psthChk.Value = 1;
        end
        redraw();
    end

    function onFitRF()
        fitOn = true;
        redraw();
    end

    function onNote()
        r  = curRow;
        nt = noteEdit.String;
        if iscell(nt);            nt = strjoin(nt, ' ');
        elseif size(nt, 1) > 1;   nt = strjoin(cellstr(nt), ' ');  end
        S(r).Note = strtrim(regexprep(nt, '\s+', ' '));
        saveNotes(noteFile, chan, unit, S);
    end

    function onShowWaveform()
        r = curRow;
        if ~isfield(spike.info, 'MeanWaveform') || isempty(spike.info.MeanWaveform) ...
                || r > size(spike.info.MeanWaveform, 1)
            statusTxt.String = 'No MeanWaveform in spike.info.';
            return
        end
        w   = spike.info.MeanWaveform(r, :);
        tms = (0:numel(w)-1) / WAVE_FS * 1000;
        wfig = figure('Name', sprintf('Average waveform  Ch %d Unit %d', chan(r), unit(r)), ...
            'Color', 'w', 'Position', [200 200 480 360]);
        wax = axes('Parent', wfig);
        plot(wax, tms, w, 'k', 'LineWidth', 1.5);
        xlabel(wax, 'Time (ms)');  ylabel(wax, '\muV');
        title(wax, sprintf('Mean waveform  Ch %d Unit %d', chan(r), unit(r)));
        grid(wax, 'on');  box(wax, 'off');
    end

    function onExport()
        if isempty(savePath)
            statusTxt.String = 'No savePath: cannot export.';
            return
        end
        set(fig, 'Pointer', 'watch');  drawnow;
        [rw, pw2, al] = curParams();
        master = exportRF(rw, pw2, al);
        saveNotes(noteFile, chan, unit, S);
        set(fig, 'Pointer', 'arrow');
        if isempty(master)
            statusTxt.String = 'RF summary export produced nothing.';
        else
            statusTxt.String = {'RF summary exported:'; master};
            fprintf('Exported %s\n', master);
        end
    end

    function [rfWin, psthWin, alignStr] = curParams()
        rf0 = str2double(rfT0.String);  rf1 = str2double(rfT1.String);
        p0  = str2double(psT0.String);  p1  = str2double(psT1.String);
        if any(isnan([rf0 rf1]));  rfWin   = RF_WIN_MS;   else;  rfWin   = [rf0 rf1];  end
        if any(isnan([p0 p1]));    psthWin = VIS_WIN_MS;  else;  psthWin = [p0 p1];    end
        alignStr = alignOpts{alignDD.Value};
    end

    function redraw()
        [rfWin, psthWin, alignStr] = curParams();
        lastRfWin = rfWin;  lastPsthWin = psthWin;  lastAlign = alignStr;
        st = computeUnit(curRow, rfWin, psthWin, alignStr, fitOn);
        plotHeatmap(axHM, GRID_CTRS, st, chan(curRow), unit(curRow), deg);

        allMax = max(max(st.psth.mean + st.psth.sem, [], 2));
        if isempty(allMax) || isnan(allMax) || allMax <= 0;  allMax = 1;  end
        yl = [0, allMax * 1.1];
        showPSTH = logical(psthChk.Value);
        showRas  = logical(rasChk.Value);
        noX = [1, 2, 3, 11, 12, 13];
        for s = 1:N_SECTORS
            drawSectorPanel(axPS(s), st.psth.t, st.psth.mean(s, :), st.psth.sem(s, :), ...
                st.psth.n(s), SECTOR_LABELS{s}, yl, ~ismember(s, noX), ...
                showPSTH, showRas, st.psth.raster{s}, PSTH_CLR, RASTER_CLR);
        end
        storeMetrics(curRow, st);
        statusTxt.String = sprintf('Ch %d  Unit %d   (%d / %d units)\nn = %d correct trials\npeak %.1f Hz', ...
            chan(curRow), unit(curRow), curRow, nRow, st.nTrials, st.peakFR);
    end

    % ---------------- pure per-unit compute (no graphics) ----------------
    function st = computeUnit(r, rfWin, psthWin, alignStr, doFit)
        visual = strcmp(alignStr, 'Visual onset');
        winSec = rfWin / 1000;
        winDur = diff(winSec);
        tc = gatherUnitSpikeTimes(spike, [], r);          % 1 x nTr, s from Start

        nG = numel(GRID_EDGES) - 1;
        gridSum = zeros(nG);  gridCnt = zeros(nG);
        tgt_xy  = zeros(0, 2);
        nUsed   = 0;

        kern    = buildKernel(PSTH_SIGMA, BIN_MS);
        t_edges = psthWin(1) : BIN_MS : psthWin(2);
        t_c     = t_edges(1:end-1) + BIN_MS/2;
        nBins   = numel(t_c);
        psthN    = zeros(N_SECTORS, 1);
        psthMean = zeros(N_SECTORS, nBins);
        psthM2   = zeros(N_SECTORS, nBins);
        raster   = repmat({{}}, N_SECTORS, 1);

        for j = 1:numel(tc)
            if ~taskTrial(j);  continue;  end
            % Target overlay: any presented target of this task's trials.
            for kt = 1:2
                presK = T.(sprintf('Target_%d_presented', kt))(j);
                xk = T.(sprintf('Target_%d_position_x', kt))(j);
                yk = T.(sprintf('Target_%d_position_y', kt))(j);
                if ~isnan(presK) && ~isnan(xk) && ~isnan(yk)
                    tgt_xy(end+1, :) = [xk yk]; %#ok<AGROW>
                end
            end
            if ~useTrial(j);  continue;  end          % RF/PSTH: correct trials only
            nUsed = nUsed + 1;
            spk = tc{j};
            for kt = 1:2
                xk = T.(sprintf('Target_%d_position_x', kt))(j);
                yk = T.(sprintf('Target_%d_position_y', kt))(j);
                if isnan(xk) || isnan(yk);  continue;  end
                if visual
                    mk = T.(sprintf('Target_%d_presented', kt))(j);
                else
                    mk = T.Fixation_point_off(j);
                end
                if isnan(mk);  continue;  end
                mRel = mk - start(j);                 % marker in the Start frame (s)

                % RF firing rate in the window, binned onto the spatial grid.
                ix = discretize(xk, GRID_EDGES);
                iy = discretize(yk, GRID_EDGES);
                if ~isnan(ix) && ~isnan(iy)
                    cnt = sum(spk >= mRel + winSec(1) & spk <= mRel + winSec(2));
                    gridSum(iy, ix) = gridSum(iy, ix) + cnt / winDur;
                    gridCnt(iy, ix) = gridCnt(iy, ix) + 1;
                end

                % Spatial PSTH (Welford) + raster ticks for the target's sector.
                sIdx = getSectorIdx(atan2d(yk, xk), hypot(xk, yk), ECC_NEAR);
                if isnan(sIdx);  continue;  end
                sp_ms = (spk - mRel) * 1000;
                c  = histcounts(sp_ms, t_edges);
                fr = c / (BIN_MS / 1000);
                psthN(sIdx)      = psthN(sIdx) + 1;
                delta            = fr - psthMean(sIdx, :);
                psthMean(sIdx,:) = psthMean(sIdx, :) + delta / psthN(sIdx);
                psthM2(sIdx,:)   = psthM2(sIdx, :) + delta .* (fr - psthMean(sIdx, :));
                raster{sIdx}{end+1} = sp_ms(sp_ms >= psthWin(1) & sp_ms <= psthWin(2));
            end
        end

        % RF grid mean + smoothing.
        gridFR = nan(nG);  has = gridCnt > 0;
        gridFR(has) = gridSum(has) ./ gridCnt(has);
        gridSm = smoothGrid(gridFR, gridCnt, GRID_CTRS, SMOOTH_SIGMA, RF_EXTRAP_MIN);

        % Smoothed PSTH mean +- SEM.
        smMean = zeros(N_SECTORS, nBins);
        smSEM  = zeros(N_SECTORS, nBins);
        for s = 1:N_SECTORS
            smMean(s, :) = conv(psthMean(s, :), kern, 'same');
            if psthN(s) > 1
                smSEM(s, :) = conv(sqrt(psthM2(s, :) / (psthN(s) - 1)) / sqrt(psthN(s)), kern, 'same');
            end
        end

        fitRes = [];
        if doFit;  fitRes = fitGaussian2D(gridSm, GRID_CTRS);  end

        st = struct();
        st.gridSm = gridSm;
        st.tgt_xy = unique(tgt_xy, 'rows');
        st.nTrials = nUsed;
        st.peakFR  = max([gridSm(:); 0]);
        st.fit     = fitRes;
        st.alignStr = alignStr;
        st.rfWin    = rfWin;
        st.psthWin  = psthWin;
        st.psth = struct('t', t_c, 'mean', smMean, 'sem', smSEM, 'n', psthN, 'raster', {raster});
    end

    function storeMetrics(r, st)
        S(r).nTrials   = st.nTrials;
        S(r).rf_peakFR = st.peakFR;
        S(r).alignMode = st.alignStr;
        S(r).rfWinMs   = st.rfWin;
        S(r).psthWinMs = st.psthWin;
        if ~isempty(st.fit)
            S(r).rf_x0 = st.fit.x0;  S(r).rf_y0 = st.fit.y0;
            S(r).rf_sx = st.fit.sx;  S(r).rf_sy = st.fit.sy;
            S(r).rf_A  = st.fit.A;   S(r).rf_B  = st.fit.B;
        end
        metricsFilled(r) = true;
    end

    function fillAllMetrics(rfWin, psthWin, alignStr)
        % Every unit gets fitted RF params under one alignment/window so the
        % exported summary is coherent; cache-seeded units (already fitted) skip.
        for ii = 1:nRow
            if ~metricsFilled(ii) || isnan(S(ii).rf_x0)
                storeMetrics(ii, computeUnit(ii, rfWin, psthWin, alignStr, true));
            end
        end
    end

    function master = exportRF(rfWin, psthWin, alignStr)
        master = '';
        if isempty(savePath);  return;  end
        fillAllMetrics(rfWin, psthWin, alignStr);
        saveRFCache();
        master = ExportTaskAnalysisSummary(buildUnitTable(ACTIVE_TASK, savePath), savePath);
    end

    function Tb = buildUnitTable(task, sp)
        if isempty(sp)
            monkey = 'unknown';  dateStr = '';
        else
            [monkey, dateStr] = parseSessionPath(sp);
            if isempty(monkey);  monkey = 'unknown';  end
        end
        n  = nRow;
        rw = reshape([S.rfWinMs],   2, [])';      % n x 2
        pw3 = reshape([S.psthWinMs], 2, [])';     % n x 2
        Tb = table( ...
            repmat(string(monkey), n, 1), repmat(string(dateStr), n, 1), ...
            repmat(string(task), n, 1), chan(:), unit(:), ...
            round([S.rf_x0]', 3), round([S.rf_y0]', 3), ...
            round([S.rf_sx]', 3), round([S.rf_sy]', 3), ...
            round([S.rf_A]', 3),  round([S.rf_B]', 3), ...
            round([S.rf_peakFR]', 3), [S.nTrials]', ...
            rw(:, 1), rw(:, 2), pw3(:, 1), pw3(:, 2), ...
            string({S.alignMode}'), string({S.Note}'), ...
            'VariableNames', {'Monkey', 'Date', 'Task', 'Channel', 'Unit', ...
                'RF_x0_deg', 'RF_y0_deg', 'RF_sx_deg', 'RF_sy_deg', 'RF_A', 'RF_B', ...
                'RF_PeakFR_Hz', 'RF_nTrials', 'RF_WinStart_ms', 'RF_WinEnd_ms', ...
                'RF_PSTHStart_ms', 'RF_PSTHEnd_ms', 'RF_Align', 'Note'});
    end

    function saveRFCache()
        if isempty(cacheFile);  return;  end
        cacheDir = fileparts(cacheFile);
        if ~exist(cacheDir, 'dir');  mkdir(cacheDir);  end
        payload = struct('S', S);
        save(cacheFile, 'payload');
    end

    function filled = seedFromCache(cf)
        filled = false(nRow, 1);
        L = load(cf);
        if ~isfield(L, 'payload') || ~isfield(L.payload, 'S') || isempty(L.payload.S)
            return
        end
        Sc = L.payload.S;
        cChan = [Sc.Channel]';  cUnit = [Sc.Unit]';
        for r = 1:nRow
            j = find(cChan == chan(r) & cUnit == unit(r), 1);
            if isempty(j);  continue;  end
            for f = {'rf_x0','rf_y0','rf_sx','rf_sy','rf_A','rf_B','rf_peakFR', ...
                     'nTrials','alignMode','rfWinMs','psthWinMs'}
                if isfield(Sc, f{1});  S(r).(f{1}) = Sc(j).(f{1});  end
            end
            filled(r) = true;
        end
    end

end


% =========================================================================
% PLOT LAYER — render only; reads the computed struct, derives no numbers
% =========================================================================
function plotHeatmap(ax, gridCtrs, st, chVal, unVal, deg)
% RF firing-rate heatmap with the fixation point, presented targets, and (when a
% valid fit is present) the Gaussian ellipse + centre.
    cla(ax, 'reset');  hold(ax, 'on');
    imagesc(ax, gridCtrs, gridCtrs, st.gridSm);
    set(ax, 'YDir', 'normal');
    axis(ax, [-20 20 -20 20]);  axis(ax, 'square');
    scatter(ax, 0, 0, 30, [1 0 0], 'filled');
    if ~isempty(st.tgt_xy)
        scatter(ax, st.tgt_xy(:, 1), st.tgt_xy(:, 2), 40, 'w', 'o', 'LineWidth', 1);
    end
    colormap(ax, 'parula');
    cb = colorbar(ax, 'Location', 'eastoutside');
    cb.Label.String = 'FR (sp/s)';
    set(ax, 'XTick', [], 'YTick', []);
    box(ax, 'on');

    rf   = st.fit;
    rfOK = ~isempty(rf) && all(isfinite([rf.x0 rf.y0 rf.sx rf.sy])) && ...
           rf.sx > 0 && rf.sx < 20 && rf.sy > 0 && rf.sy < 20;
    if rfOK
        th = linspace(0, 2*pi, 200);
        plot(ax, rf.x0 + rf.sx*cos(th), rf.y0 + rf.sy*sin(th), 'w-', 'LineWidth', 2);
        plot(ax, rf.x0, rf.y0, 'r+', 'MarkerSize', 16, 'LineWidth', 2.5);
        title(ax, sprintf('Ch %d  Unit %d  (n=%d)   RF (%.1f%s, %.1f%s)', ...
            chVal, unVal, st.nTrials, rf.x0, deg, rf.y0, deg), 'FontSize', 10);
    else
        title(ax, sprintf('Ch %d  Unit %d  (n=%d trials)', chVal, unVal, st.nTrials), 'FontSize', 10);
    end
end


function drawSectorPanel(ax, t_c, mn, se, n, label, yl, showX, showPSTH, showRaster, rasterCell, clr, rasterClr)
% One spatial-PSTH panel: optional light raster behind, optional mean +- SEM band,
% zero line, sector label + trial count. At least one of PSTH / raster is on.
    cla(ax, 'reset');  hold(ax, 'on');

    if showRaster && ~isempty(rasterCell)
        nT = numel(rasterCell);
        h  = yl(2) / max(nT, 1);
        xs = [];  ys = [];
        for i = 1:nT
            s = rasterCell{i}(:).';
            if isempty(s);  continue;  end
            yc = yl(2) * (i - 0.5) / nT;
            xs = [xs, [s; s; nan(1, numel(s))]];                               %#ok<AGROW>
            ys = [ys, [(yc - h*0.45)*ones(1, numel(s)); (yc + h*0.45)*ones(1, numel(s)); nan(1, numel(s))]]; %#ok<AGROW>
        end
        if ~isempty(xs)
            plot(ax, xs(:), ys(:), '-', 'Color', rasterClr, 'LineWidth', 0.5);
        end
    end

    if showPSTH && n > 0
        fill(ax, [t_c, fliplr(t_c)], [mn + se, fliplr(mn - se)], clr, ...
            'FaceAlpha', 0.25, 'EdgeColor', 'none');
        plot(ax, t_c, mn, 'Color', clr, 'LineWidth', 1.2);
    end
    plot(ax, [0 0], yl, '--', 'Color', [0.6 0.6 0.6], 'LineWidth', 0.8);

    xlim(ax, [t_c(1), t_c(end)]);
    ylim(ax, yl);
    title(ax, sprintf('%s  n=%d', label, n), 'FontSize', 8, 'FontWeight', 'bold');
    set(ax, 'TickDir', 'out', 'FontSize', 6, 'Box', 'on');
    if ~showX;  set(ax, 'XTickLabel', []);  end
end


% =========================================================================
% PORTED MATH HELPERS (from plotJivesReceptiveField.m)
% =========================================================================
function kern = buildKernel(sigma_ms, bin_ms)
% Normalized Gaussian smoothing kernel on the PSTH bin grid.
    sb  = sigma_ms / bin_ms;
    kSz = 2*ceil(3*sb) + 1;
    x   = -floor(kSz/2) : floor(kSz/2);
    kern = exp(-0.5 * (x / sb).^2);
    kern = kern / sum(kern);
end


function gridSm = smoothGrid(gridFR, gridCnt, GRID_CTRS, SMOOTH_SIGMA, RF_EXTRAP_MIN)
% Smoothed RF map: natural-neighbour interpolation (nearest outside the hull) once
% there are enough observations, else NaN-aware normalized Gaussian smoothing with
% no extrapolation into empty regions.
    has  = ~isnan(gridFR);
    nPts = sum(has(:));
    nObs = sum(gridCnt(:));
    [gxm, gym] = meshgrid(GRID_CTRS, GRID_CTRS);
    if nPts >= 3 && nObs >= 2 * RF_EXTRAP_MIN
        F = scatteredInterpolant(gxm(has), gym(has), double(gridFR(has)), 'natural', 'nearest');
        gridSm = imgaussfilt(F(gxm, gym), SMOOTH_SIGMA);
    elseif nPts >= 1
        dataMap = gridFR;  dataMap(~has) = 0;
        num = imgaussfilt(dataMap, SMOOTH_SIGMA);
        den = imgaussfilt(double(has), SMOOTH_SIGMA);
        gridSm = num ./ max(den, 1e-6);
        gridSm(den < 0.02) = 0;
    else
        gridSm = zeros(size(gridFR));
    end
end


function sIdx = getSectorIdx(ang, ecc, ECC_NEAR)
% (angle deg, eccentricity deg) -> sector index 1-16. 8 equal 45 deg direction
% sectors x 2 eccentricity bins (near < ECC_NEAR, far >=).
    if isnan(ang) || isnan(ecc)
        sIdx = NaN;  return;
    end
    ang360 = mod(ang, 360);
    secNum = floor(mod(ang360 + 22.5, 360) / 45) + 1;   % 1-8: E,NE,N,NW,W,SW,S,SE
    far_map  = [8,  3,  2,  1,  7,  14, 15, 16];
    near_map = [10, 6,  5,  4,  9,  11, 12, 13];
    if ecc < ECC_NEAR
        sIdx = near_map(secNum);
    else
        sIdx = far_map(secNum);
    end
end


function fitResult = fitGaussian2D(gridFR_sm, GRID_CTRS)
% Fit an elliptical 2-D Gaussian to the smoothed RF map. Returns struct with fields
% x0, y0 (centre deg), sx, sy (sigma deg), A, B; [] when too few positive cells.
    [gxm, gym] = meshgrid(GRID_CTRS, GRID_CTRS);
    z  = gridFR_sm(:);  xv = gxm(:);  yv = gym(:);
    valid = ~isnan(z) & z > 0;
    if sum(valid) < 6
        fitResult = [];  return;
    end
    xv = xv(valid);  yv = yv(valid);  zv = z(valid);

    [A0, idx] = max(zv);
    B0 = min(zv);
    x0 = xv(idx);  y0 = yv(idx);

    gauss2d = @(p, x, y) p(1)*exp(-((x-p(2)).^2/(2*p(4)^2) + (y-p(3)).^2/(2*p(5)^2))) + p(6);
    cost    = @(p) sum((zv - gauss2d(p, xv, yv)).^2);

    p0   = [A0 - B0, x0, y0, 2, 2, B0];
    opts = optimset('Display', 'off', 'MaxIter', 3000, 'TolFun', 1e-8, 'TolX', 1e-6);
    try
        pFit = fminsearch(cost, p0, opts);
        fitResult = struct('x0', pFit(2), 'y0', pFit(3), ...
            'sx', abs(pFit(4)), 'sy', abs(pFit(5)), 'A', pFit(1), 'B', pFit(6));
    catch
        fitResult = [];
    end
end


% =========================================================================
% Per-unit note persistence (unit_rf_notes.csv)
% =========================================================================
function notes = loadNotes(noteFile, chan, unit)
% Seed per-unit notes from the saved CSV, matched by (Channel, Unit).
    n = numel(chan);
    notes = repmat({''}, n, 1);
    if isempty(noteFile) || exist(noteFile, 'file') ~= 2
        return
    end
    try
        Tb = readtable(noteFile, 'TextType', 'string');
    catch
        return
    end
    if isempty(Tb) || ~all(ismember({'Channel', 'Unit'}, Tb.Properties.VariableNames))
        return
    end
    [tf, loc] = ismember([chan, unit], [Tb.Channel, Tb.Unit], 'rows');
    hasNote   = ismember('Note', Tb.Properties.VariableNames);
    for k = find(tf(:).')
        if hasNote;  notes{k} = safeStr(Tb.Note(loc(k)));  end
    end
end


function saveNotes(noteFile, chan, unit, S)
% Persist units that carry a note, overwriting so a cleared note disappears.
    if isempty(noteFile);  return;  end
    hasNote = ~cellfun(@isempty, {S.Note});
    Tb = table(chan(hasNote), unit(hasNote), string({S(hasNote).Note})', ...
        'VariableNames', {'Channel', 'Unit', 'Note'});
    try
        noteDir = fileparts(noteFile);
        if ~isempty(noteDir) && ~exist(noteDir, 'dir');  mkdir(noteDir);  end
        writetable(Tb, noteFile);
    catch ME
        warning('RFPlot:saveNotes', 'Could not write %s: %s', noteFile, ME.message);
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
