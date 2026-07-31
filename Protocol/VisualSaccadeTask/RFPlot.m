function rfsummary = RFPlot(data, cfg, plotFlag, savePath, reCompute)
% Receptive-field analysis for the saccade tasks: an interactive per-unit
% browser (RF heatmap + 16 spatial PSTHs), built from the OFFLINE spike raster.
%
% Task-agnostic. The same RF analysis applies to the visual and the memory
% saccade task, and the router dispatches this function for both; which one a
% given call is analyzing is DERIVED from data.comments.Task (resolveActiveTask
% at the bottom of this file), never hardwired. That label is what tags the
% per-unit rows in the master analysis summary, and it also scopes the per-task
% cache file, so the two tasks' results coexist for one session instead of
% overwriting each other.
%
% Ported from the online reference OnlinePlotBlackRock/jivesLink/
% plotJivesReceptiveField.m (RF grid, spatial PSTHs, 2-D Gaussian fit), but driven
% by the exported online_spike product (data.spike) and the trials table
% (data.comments) instead of the online `trials` global. The GUI, per-unit navigator,
% note field, per-unit caching, and cross-task summary CSV mirror spikeCheck.m.
%
%   data     - struct from BlackRockFileAnalyzer, already scoped to ONE task by
%              SetupDataForTask: .spike (online_spike raster) and .comments
%              (trials table, cd) hold only that task's trials, with the raster
%              trial dimension 1:1 co-ordered with the comments rows (spike trial j
%              <-> cd row j). Other fields (.RT/.eyes) are unused here. Data
%              spanning more than one task is rejected (see resolveActiveTask).
%   cfg   - not implemented yet.
%   plotFlag - (optional, default true) draw the GUI. false runs headless: no
%              figure; with a savePath every unit's RF is computed, cached, and
%              merged into the master analysis summary, then rfsummary is returned.
%   savePath - (optional) export folder (.../Monkey <name>/.../<date>). '' turns
%              persistence/export off. Used by the Export button, the headless path,
%              and the on-close cache write.
%   reCompute- (optional, default true) when true, recompute every unit's RF and
%              refresh the cache. When false, the per-unit results are loaded from
%              <savePath>/AnalysisCache/RFSummary_<task>.mat instead. The cache is
%              scoped per task, so the visual and memory saccade runs of one
%              session do not overwrite each other.

%
% Returns rfsummary, a per-unit table (Channel, Unit, RF fit params, peak FR, trial
% count, alignment/windows, Note).
%
% Computation is separated from visualization: computeUnit (pure, no graphics)
% assembles the per-unit RF grid + spatial PSTHs (reading per-trial markers straight
% from the pre-scoped cd via gatherUnitSpikeTimes); plotHeatmap / drawSectorPanel
% only render.
%
% Xuefei Yu Jul 2026

    if nargin < 3 || isempty(plotFlag);   plotFlag  = true;  end
    if nargin < 4;                        savePath  = '';    end
    if nargin < 5 || isempty(reCompute);  reCompute = true;  end

    rfsummary = table();

    % ── Constants (from the reference) ────────────────────────────────────
    % (the analyzed task is NOT a constant -- it is read from the trials table
    %  further down, see resolveActiveTask)
    RF_WIN_MS    = [50, 200];
    VIS_WIN_MS   = [-200, 600];
    BIN_MS       = 10;
    PSTH_SIGMA   = 20;
    SMOOTH_SIGMA = 2.5;
    GRID_EDGES   = -20:1:20;
    GRID_CTRS    = (GRID_EDGES(1:end-1) + GRID_EDGES(2:end)) / 2;
    ECC_EDGES    = [0, 8, 14, 25];      % deg; band upper edge is inclusive per band
    nRings       = numel(ECC_EDGES) - 1;
    RF_EXTRAP_MIN = 10;
    N_SECTORS    = 8 * nRings;          % 8 compass octants x nRings eccentricity bands
    PSTH_CLR     = [0.20 0.50 0.90];
    RASTER_CLR   = [0.75 0.80 0.92];   % light ticks behind the PSTH
    WAVE_FS      = 30000;              % Blackrock NEV waveform sample rate (Hz)
    alignOpts    = {'Visual onset', 'Saccade onset'};

    % Nominal compass-octant centre angles (secNum order: E,NE,N,NW,W,SW,S,SE) and
    % eccentricity-band strings, used only as a fallback title for empty sectors --
    % real panels are titled from the actual (angle, ecc) of their contributing
    % trials (built per-unit in computeUnit, see st.psth.label).
    OCT_ANGLES   = [0, 45, 90, 135, 180, 225, 270, 315];
    ECC_BAND_STR = arrayfun(@(i) sprintf('%g-%g', ECC_EDGES(i), ECC_EDGES(i+1)), ...
        1:nRings, 'UniformOutput', false);
    deg = char(176);

    % ── Guard: need a spike raster ────────────────────────────────────────
    if ~isfield(data, 'spike') || isempty(data.spike) || ~isfield(data.spike, 'data') ...
            || isempty(data.spike.data)
        disp('RFPlot: no spike raster to analyze.');
        return
    end

    
    cd_ori    = data.comments;

    % Which task this call is analyzing, taken from the trials table rather than
    % hardwired -- the same RF analysis serves both saccade tasks. Read from
    % cd_ori, not the correct-only cd below, so a session with no correct trials
    % still reports the task it ran.
    ACTIVE_TASK = resolveActiveTask(cd_ori);

    useTrial = strcmp(string(cd_ori.Trialoutcome), 'correct');
    cd = cd_ori(useTrial,:);

    spike_ori = data.spike;
    spike = spike_ori;
    spike.data = spike_ori.data(:,useTrial,:);

    chan  = spike.info.Channel_Number(:);
    unit  = spike.info.Unit_No(:);
    nRow  = numel(chan);
    channels = unique(chan, 'stable');
    start = spike.timeseq.alignedrawtime(useTrial);          % trials x 1, abs Start (s)

    % Trials arrive pre-scoped to this task and 1:1 co-ordered with the raster
    % (cd row j <-> spike trial j), so per-trial markers/outcome are read straight
    % from cd; no (Session, Trial_number) re-pairing here. RF/PSTH use correct
    % trials only.
   

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
        % Cache is per TASK: now that one session can run RFPlot for both the
        % visual and the memory saccade task, a single RFSummary.mat would have
        % the second run seed its units from the first task's fits. The note
        % file stays shared on purpose -- a note is an observation about the
        % unit, not about one task's fit.
        cacheFile = fullfile(savePath, 'AnalysisCache', ...
            sprintf('RFSummary_%s.mat', ACTIVE_TASK));
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
        'Position', [50 40 1700 1150]);

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

    % --- right plot panel: heatmap + N_SECTORS spatial PSTHs -----------------
    pnl = uipanel(fig, 'Units', 'normalized', 'Position', [0.17 0.02 0.82 0.96], ...
        'BackgroundColor', 'w', 'BorderType', 'none');

    pw = 0.085;  ph = 0.095;  gx = 0.008;  gy = 0.008;
    gySep = 0.015;  gHM = 0.030;  lm = 0.05;  rm = 0.05;  bm = 0.03;

    ringBlockH = nRings*ph + (nRings-1)*gySep;   % stacked-ring block height (top = bottom)
    ringBlockW = nRings*pw + (nRings-1)*gx;      % stacked-ring block width (left = right)

    y3  = bm + ringBlockH + gHM;                 % heatmap bottom edge
    hmh = 2*ph + gy;                             % heatmap height
    hmx = lm + ringBlockW + gHM;                 % heatmap left edge
    hmw = 1 - rm - ringBlockW - gHM - hmx;       % heatmap width (leftover)
    xNS = hmx + hmw/2 - pw/2;                    % N/S column, centered on heatmap
    yWE = y3 + (hmh - ph)/2;                     % E/W row, centered on heatmap

    axHM = axes('Parent', pnl, 'Units', 'normalized', 'Position', [hmx, y3, hmw, hmh]);

    % Sector panels: 8 compass octants (secNum order) x nRings eccentricity bands,
    % ring 1 = innermost/nearest the heatmap. Each panel steps outward along its
    % octant's (DIRX,DIRY) direction by one panel+gap per additional ring -- this
    % generalizes the old hand-placed near/far layout to any nRings.
    DIRX = [1  1  0 -1 -1 -1  0  1];   % E,NE,N,NW,W,SW,S,SE
    DIRY = [0  1  1  1  0 -1 -1 -1];
    stepX = pw + gx;
    stepY = ph + gySep;

    axPS = gobjects(N_SECTORS, 1);
    for oct = 1:8
        if     DIRX(oct) > 0;  ax0 = hmx + hmw + gHM;
        elseif DIRX(oct) < 0;  ax0 = hmx - gHM - pw;
        else;                  ax0 = xNS;
        end
        if     DIRY(oct) > 0;  ay0 = y3 + hmh + gHM;
        elseif DIRY(oct) < 0;  ay0 = y3 - gHM - ph;
        else;                  ay0 = yWE;
        end
        for ring = 1:nRings
            sIdx = (oct - 1) * nRings + ring;
            px = ax0 + (ring - 1) * DIRX(oct) * stepX;
            py = ay0 + (ring - 1) * DIRY(oct) * stepY;
            axPS(sIdx) = axes('Parent', pnl, 'Units', 'normalized', 'Position', [px, py, pw, ph]);
        end
    end

    selectRow(1);

    disp('Waiting for RF screening, will continue after close the RF gui...')
   % uiwait(fig);

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
        % x-ticks: only the ring closest to the heatmap on that side of a vertical
        % stack shows them (top block: innermost ring 1; bottom block: outermost
        % ring nRings, since that block grows downward away from the heatmap).
        % Horizontal (E/W) octants aren't stacked, so they always show ticks.
        for s = 1:N_SECTORS
            sOct  = ceil(s / nRings);
            sRing = s - (sOct - 1) * nRings;
            if DIRY(sOct) == 0
                showX = true;
            elseif DIRY(sOct) > 0
                showX = (sRing == 1);
            else
                showX = (sRing == nRings);
            end
            drawSectorPanel(axPS(s), st.psth.t, st.psth.mean(s, :), st.psth.sem(s, :), ...
                st.psth.n(s), st.psth.label{s}, yl, showX, ...
                showPSTH, showRas, st.psth.raster{s}, PSTH_CLR, RASTER_CLR);
        end
        storeMetrics(curRow, st);
        statusTxt.String = sprintf('Ch %d  Unit %d   (%d / %d units)\nn = %d correct trials\npeak %.1f Hz', ...
            chan(curRow), unit(curRow), curRow, nRow, st.nTrials, st.peakFR);
    end

    % ---------------- pure per-unit compute (no graphics) -----------------
    % Groups trials by their (Target_1_angle, Target_1_eccentricity) condition
    % once, then does the RF-grid and spatial-PSTH math per condition/sector
    % instead of recomputing the shared grid cell / sector for every trial.
    function st = computeUnit(r, rfWin, psthWin, alignStr, doFit)
        visual = strcmp(alignStr, 'Visual onset');
        winSec = rfWin / 1000;
        tc = gatherUnitSpikeTimes(spike, [], r);          % 1 x nTr, s from Start; feeds PSTH + raster
        nTr = numel(tc);

        xk = cd.Target_1_position_x;
        yk = cd.Target_1_position_y;
        if visual
           % mk = cd.Target_1_presented;
           if ismember('Target1OnsetPD', cd.Properties.VariableNames)
               mk = cd.Target1OnsetPD;
               disp('Use photodiode timestamp.');
           else
               disp('Cannot find the photodiode timing, use timestamp instead.')
               mk = cd.Target_1_presented;
           end
        else
            if ismember('RTtime', cd.Properties.VariableNames)
                mk = cd.RTtime + cd.Fixation_point_off;
            else
                disp('Use approximate RT(fixation off)');
               % mk = cd.Choicetime - cd.Fixation_point_off;   % seconds
                mk = cd.Choicetime;
            end
        end
        mRelKt = mk - start;

        % RF-window firing rate per trial, normalized by the *observed* duration
        % (handles a window truncated by a short trial's recorded range) rather
        % than the nominal window length.
        unitSeq = struct('data', spike.data(r, :, :), 'timeseq', spike.timeseq, ...
            'info', struct('samplingrate', spike.info.samplingrate));
        win = [mRelKt + winSec(1), mRelKt + winSec(2)];
        rr  = AverageFiringRateBetween(unitSeq, win);
        rateKt = rr(1, :).';

        nG = numel(GRID_EDGES) - 1;
        kern    = buildKernel(PSTH_SIGMA, BIN_MS);
        t_edges = psthWin(1) : BIN_MS : psthWin(2);
        t_c     = t_edges(1:end-1) + BIN_MS/2;
        nBins   = numel(t_c);
        psthN    = zeros(N_SECTORS, 1);
        psthMean = zeros(N_SECTORS, nBins);
        psthSEM  = zeros(N_SECTORS, nBins);
        raster   = repmat({{}}, N_SECTORS, 1);

        % Target overlay: any presented target of this task's trials.
        presOK = ~isnan(cd.Target_1_presented) & ~isnan(xk) & ~isnan(yk);
        tgt_xy = unique([xk(presOK), yk(presOK)], 'rows');

        % ---- Stage 1: enumerate unique (angle, eccentricity) conditions ----
        % uniquetol (not unique/round): angle & eccentricity are floats, so grouping
        % needs float-noise tolerance -- but rounding (tried, verified against real
        % data) both merges genuinely distinct conditions and pushes borderline
        % eccentricities across an ECC_EDGES band boundary (e.g. 9.9998 -> 10.0). A
        % tight ABSOLUTE tolerance (DataScale=1) avoids that: uniquetol's default
        % scales relative to the whole [angle,ecc] matrix, which under/over-merges
        % when the two columns have very different ranges (angle ~360, ecc ~20) --
        % the same failure mode rounding had, just via a different mechanism.
        valid = ~isnan(xk) & ~isnan(yk) & ~isnan(mRelKt);
        angRaw = cd.Target_1_angle;
        eccRaw = cd.Target_1_eccentricity;
        [cond, ~, condId] = uniquetol([angRaw(valid), eccRaw(valid)], 1e-6, ...
            'ByRows', true, 'DataScale', 1);
        nCond = size(cond, 1);
        angC  = mod(90 - cond(:, 1), 360);    % compass Target_1_angle -> math convention
        eccC  = cond(:, 2);
        sIdxC = arrayfun(@(k) getSectorIdx(angC(k), eccC(k), ECC_EDGES), (1:nCond)');

        % Grid placement reuses the existing x/y columns (one representative
        % position per condition; members of a condition share one target).
        xRep = accumarray(condId, xk(valid), [nCond, 1], @mean);
        yRep = accumarray(condId, yk(valid), [nCond, 1], @mean);
        ixC  = discretize(xRep, GRID_EDGES);
        iyC  = discretize(yRep, GRID_EDGES);

        % ---- Stage 2a: RF grid, per condition -> grid --------------------
        rV = rateKt(valid);
        condSum = accumarray(condId, rV, [nCond, 1], @(v) sum(v(~isnan(v))), 0);
        condCnt = accumarray(condId, ~isnan(rV), [nCond, 1], @sum, 0);
        okGrid  = ~isnan(ixC) & ~isnan(iyC);
        linIdx  = sub2ind([nG, nG], iyC(okGrid), ixC(okGrid));
        gridSum = reshape(accumarray(linIdx, condSum(okGrid), [nG * nG, 1], @sum, 0), nG, nG);
        gridCnt = reshape(accumarray(linIdx, condCnt(okGrid), [nG * nG, 1], @sum, 0), nG, nG);

        % ---- Stage 2b: spatial PSTH + raster, per sector ------------------
        sectorOfTrial = sIdxC(condId);        % sector for each valid trial
        validIdx = find(valid);
        for s = 1:N_SECTORS
            trIdx = validIdx(sectorOfTrial == s);
            n = numel(trIdx);
            psthN(s) = n;
            if n == 0
                continue
            end
            spMs = cellfun(@(spk, mRel) (spk - mRel) * 1000, tc(trIdx), ...
                num2cell(mRelKt(trIdx)).', 'UniformOutput', false);
            counts = cell2mat(cellfun(@(sp) histcounts(sp, t_edges), spMs, 'UniformOutput', false).');
            fr = counts / (BIN_MS / 1000);
            psthMean(s, :) = mean(fr, 1);
            if n > 1
                psthSEM(s, :) = std(fr, 0, 1) / sqrt(n);
            end
            raster{s} = cellfun(@(sp) sp(sp >= psthWin(1) & sp <= psthWin(2)), spMs, 'UniformOutput', false);
        end

        % Panel titles: actual (angle, eccentricity) of the real condition(s) that
        % contributed trials to each sector (nominal octant/band as fallback when a
        % sector has no trials), built here since cond/sIdxC are per-unit-call already.
        sectorLabel = repmat({''}, N_SECTORS, 1);
        for s = 1:N_SECTORS
            inSec = find(sIdxC == s);
            if isempty(inSec)
                sOct  = ceil(s / nRings);
                sRing = s - (sOct - 1) * nRings;
                sectorLabel{s} = sprintf('%d%s, ecc %s (no data)', OCT_ANGLES(sOct), deg, ECC_BAND_STR{sRing});
            else
                parts = arrayfun(@(k) sprintf('%.0f%s/%.1f', cond(k, 1), deg, cond(k, 2)), inSec, 'UniformOutput', false);
                sectorLabel{s} = strjoin(parts, ', ');
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
                smSEM(s, :) = conv(psthSEM(s, :), kern, 'same');
            end
        end

        fitRes = [];
        if doFit;  fitRes = fitGaussian2D(gridSm, GRID_CTRS);  end

        st = struct();
        st.gridSm = gridSm;
        st.tgt_xy = tgt_xy;
        st.nTrials = nTr;
        st.peakFR  = max([gridSm(:); 0]);
        st.fit     = fitRes;
        st.alignStr = alignStr;
        st.rfWin    = rfWin;
        st.psthWin  = psthWin;
        st.psth = struct('t', t_c, 'mean', smMean, 'sem', smSEM, 'n', psthN, ...
            'raster', {raster}, 'label', {sectorLabel});
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


function task = resolveActiveTask(cd)
% The task this call is analyzing, read from the (already task-scoped) trials
% table instead of being a constant of this file.
%
% RFPlot serves every task that shares this RF analysis -- the router dispatches
% it for both 'visual_saccades_experiment' and 'memory_saccades_experiment' --
% so the task name cannot be hardwired. It is not a filter: the data arrives
% pre-scoped by SetupDataForTask, and this is purely the LABEL written into the
% per-unit summary's Task column. That column is part of
% ExportTaskAnalysisSummary's (Monkey, Date, Task, Channel, Unit) upsert key,
% and re-exporting a (Monkey, Date, Task) block REPLACES it -- so a hardwired
% label did more than mis-name rows: a memory-saccade run would overwrite the
% visual-saccade block for the same session's units, and vice versa.
%
% Pure: reads the table, returns a char row vector.
    if ~ismember('Task', cd.Properties.VariableNames)
        error('RFPlot:NoTaskColumn', ...
            'data.comments has no Task column, so the analyzed task cannot be identified.');
    end

    tasks = unique(cellstr(string(cd.Task)));      % handles cellstr or string
    if isempty(tasks)
        error('RFPlot:NoTrials', ...
            'data.comments is empty; nothing to identify the analyzed task from.');
    end
    if numel(tasks) > 1
        % Fatal rather than picking one: this value keys the master-summary
        % upsert, so guessing here would silently overwrite another task's
        % stored results instead of producing an obviously wrong figure.
        error('RFPlot:MixedTasks', ...
            ['data.comments spans %d tasks (%s). RFPlot expects data already ' ...
             'scoped to a single task by SetupDataForTask.'], ...
            numel(tasks), strjoin(tasks', ', '));
    end

    task = tasks{1};
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


function sIdx = getSectorIdx(ang, ecc, ECC_EDGES)
% (angle deg, eccentricity deg) -> sector index. 8 equal 45 deg compass octants x
% numel(ECC_EDGES)-1 eccentricity bands (each band's upper edge inclusive); ring 1
% is the innermost/nearest band.
    if isnan(ang) || isnan(ecc)
        sIdx = NaN;  return;
    end
    nRings = numel(ECC_EDGES) - 1;
    ang360 = mod(ang, 360);
    secNum = floor(mod(ang360 + 22.5, 360) / 45) + 1;   % 1-8: E,NE,N,NW,W,SW,S,SE
    ring = nRings;                                       % default: outermost band
    for i = 1:nRings
        if ecc <= ECC_EDGES(i+1);  ring = i;  break;  end
    end
    sIdx = (secNum - 1) * nRings + ring;
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
