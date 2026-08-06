classdef BlackrockLoader < handle
% BlackrockLoader  Schema-checked loading and parsing of Blackrock behavior data.
%
% The recording for one session is split across files by role; the loader picks
% each file by its filename prefix and verifies the expected data is actually
% present before using it:
%   <CommentPrefix_primary>-*.nev  -> experiment comments + comment timing
%   <CommentPrefix_legacy>-*.nev   -> legacy fallback for comments
%   <SpikePrefix>-*.nev            -> online spike timing
%   <EyePrefix>-*.ns2           -> eye data (and, by default, the photodiode)
%   <LFPPrefix>-*.ns2              -> local field potential (Hub-*.ns2 by default)
%   photodiode                     -> by default, channels PhotodiodeChannels
%                                      sliced from the eye <EyePrefix>-*.ns2
%                                      stream; falls back to (or, if
%                                      PhotodiodeUseSeparateFile is set, goes
%                                      straight to) a dedicated
%                                      <PhotodiodePrefix>-*.ns4 file
% Legacy exception: in early sessions comments AND spikes were both written to
% the HUB-*.nev file, so comments fall back from NSP to HUB.
%
% This is a stateful (handle) config-property class: the config properties below
% hold the file schema, the load flags, the parsing schema (templates + event
% maps), and the segmentation buffers. Override any of them through the
% constructor, e.g.
%   loader = BlackrockLoader('LoadOnlineSpikeData', false);
% then run the whole pipeline per date folder with the orchestrator:
%   loader.processFolder(DataFolder, OutputPath, 'Blackrock_2026-06-24');
% or drive it step by step (each step stores its result in a loader property):
%   loader.load(DataFolder);   % -> loader.Loaded
%   loader.parseEvents();      % -> loader.Trials, loader.Experiment
%   loader.parseEye();      % -> loader.Eye
%   loader.parseLFP();         % -> loader.LFP
%   loader.parsePhotodiode();  % -> loader.Photodiode
%   loader.parseSpikes();      % -> loader.Spike, loader.SpikeWaveformData
%   loader.prepareExport();    % -> loader.Export (trials table + expmeta lines)
%   loader.export(OutputPath, 'Blackrock_2026-06-24');   % writes the files
% Session state is cleared at the start of every load(), so one loader can be
% reused across a batch of folders without leaking data between them.
%
% Precision rule: VOLTAGES are single, TIMES are always double.
%   single  - segmented sample values (Eye/LFP/Photodiode .data, spike
%             waveforms, the 0/1 raster). Half the memory, and still ~300x finer
%             than the ADC quantum these values are stored on.
%   double  - every timestamp, everywhere: comment/event times, spike times,
%             trial Start/End, timeseq.alignedrawtime, timeseq.relative_time,
%             and waveform_time. Recording clocks run to ~1.5e9 s absolute and
%             down to nanosecond PTP ticks, so single would lose real
%             resolution. Never narrow a time field.
%
% Last updates of the comments --June 27th, 2026
% by Xuefei Yu

    properties
        % --- file schema (which file holds which data product) ---
        CommentPrefix_primary = 'NSP'    % NSP-*.nev: comments + comment timing
        CommentPrefix_legacy  = 'HUB'    % legacy fallback for comments
        SpikePrefix           = 'HUB'    % HUB-*.nev: online spike timing
        EyePrefix          = 'NSP'    % NSP-*.ns2: eye (+ photodiode) data
        EyeIdentifier      = '*.ns2'  % eye stream extension
        LFPPrefix             = 'Hub'    % Hub-*.ns2: local field potential
        LFPIdentifier         = '*.ns2'  % LFP data extension (mirrors EyeIdentifier)

        % --- channel layout of the eye EyePrefix-*.ns2 stream ---
        % The eye file carries both signals, so it is read and segmented ONCE
        % and the resulting per-trial array is split by row: EyeChannels ->
        % obj.Eye, PhotodiodeChannels -> obj.Photodiode.
        EyeChannels               = [1 2 3]  % row indices that carry eye signal

        % --- photodiode: sliced from the eye ns2 stream by default, else a
        % dedicated separate file ---
        PhotodiodeChannels        = [4 5 6]  % row indices in the eye EyePrefix-*.ns2 stream
        PhotodiodePrefix          = 'NSP'    % fallback/forced separate-file prefix
        PhotodiodeIdentifier      = '*.ns4'  % fallback/forced separate-file extension
        PhotodiodeUseSeparateFile = false    % true = skip the ns2 slice attempt and
                                              % load the separate file directly

        % --- what to load ---
        LoadEyeData        = false
        LoadLFPData           = false
        LoadPhotodiodeData    = false
        LoadOnlineSpikeData   = false
        LoadOnlineSpikeWaveform     = false    % opt-in: extract per-spike waveforms (uV);
                                         % requires LoadOnlineSpikeData; exported to its own .mat
        IncludeUnsorted       = false    % keep unit 0 (unsorted) + unit 255 (noise) spikes;
                                         % default false drops both before segmentation.
                                         % Source-agnostic: applies to online or offline spikes

        % --- runtime behaviour ---
        Verbose            = false   % print the per-event parsing chatter from parseEvents.
                                     % Off by default: command-window output is slow, and an
                                     % unrecognised comment format would otherwise emit several
                                     % lines per event across ~1e5 events. Problems still
                                     % surface as warnings when this is off.
        FreeRawAfterParse  = true    % release each raw continuous stream as soon as its
                                     % per-trial product exists, instead of holding raw +
                                     % segmented copies of every stream until the next load().
                                     % Set false to keep obj.Loaded fully inspectable.
        CompressExport     = true    % gzip the .mat exports. On by default: these arrays are
                                     % mostly NaN padding and compress ~6x (measured 9.0 GB
                                     % -> 1.45 GB for one session), which is worth more than
                                     % the ~60 s of single-threaded gzip it costs. Set false
                                     % to spend the disk instead when turning a session
                                     % around quickly.

        % --- parsing schema (filled by static factories if left empty) ---
        TrialTemplate         % struct of NaN-initialised trial fields
        ExpTemplate           % struct of NaN-initialised experiment fields
        EventMaps             % struct of containers.Map + cell-list event maps

        % --- segmentation buffers (ms). Window per trial = [Start-Pre, End+Post] ---
        Segment_PreBuffer  = 500   % ms kept before each trial's Start marker
        Segment_PostBuffer = 500   % ms kept after  each trial's End  marker
        Segment_BinWidth   = 1     % spike raster bin width (ms)
        Spike_ISIViolationMs = 1   % ms; refractory window for info.ViolationRate
    end

    properties (SetAccess = private)
        % --- per-folder session state, populated by the pipeline steps and
        % cleared at the start of every load() (see resetSession) ---
        Loaded            % the S struct from loadSession (events, spikes, continuous streams, statuses, flags)
        Trials            % struct array from parseEvents
        Experiment        % struct array from parseEvents
        TrialStartTicks   % uint64, one per trial: the Start marker's raw clock
                          % tick, parallel to Trials. Lets per-spike times be
                          % measured from Start exactly (see segmentSpikeWaveforms);
                          % 0 where no Start was seen, [] when the comment source
                          % carried no ticks.
        TrialEndTicks     % uint64, one per trial: the End marker's raw clock tick.
                          % With TrialStartTicks this lets segmentContinuous and
                          % segmentSpikes compute the whole trial window in exact
                          % integers instead of on absolute epoch doubles, where
                          % the resolution is only ~238 ns. Same conventions as
                          % TrialStartTicks: 0 = not seen, [] = no ticks.
        Eye               % per-trial eye slices: segmentContinuous output restricted to
                          % EyeChannels ([] when the eye stream was not loaded).
                          % Named for its contents, not its source file -- the
                          % EyePrefix-*.ns2 also carries the photodiode.
        LFP               % segmentContinuous output   ([] when LFP not loaded)
        Photodiode        % segmentContinuous output   ([] when photodiode not loaded)
        Spike             % segmentSpikes output   ([] when spikes not loaded)
        SpikeWaveformData % segmentSpikeWaveforms output ([] unless waveforms on)
        Export            % struct: .trials_table (table) + .expmeta_lines (cellstr)
    end

    methods
        function obj = BlackrockLoader(varargin)
            % Accept name/value overrides for any public property, then fill the
            % parsing schema from the static factories when not supplied.
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
            if isempty(obj.TrialTemplate); obj.TrialTemplate = BlackrockLoader.defaultTrialTemplate(); end
            if isempty(obj.ExpTemplate);   obj.ExpTemplate   = BlackrockLoader.defaultExpTemplate();   end
            if isempty(obj.EventMaps);     obj.EventMaps     = BlackrockLoader.defaultEventMaps();      end
            BlackrockLoader.validateEventMaps(obj.EventMaps);
        end



        function processFolder(obj, DataFolder, OutputPath, BaseName)
        % Run the whole pipeline for one date folder:
        %   load -> parseEvents -> parseEye -> parseLFP -> parsePhotodiode
        %        -> parseSpikes -> prepareExport -> export
        % Exceptions propagate so a batch driver's per-folder try/catch can mark
        % just this folder failed and keep going.
        %
        % Each stage's wall time is printed as it finishes, so a slow folder
        % shows which stage is responsible without needing the profiler.
            stage_names = {'load', 'parseEvents', 'parseEye', 'parseLFP', ...
                           'parsePhotodiode', 'parseSpikes', 'prepareExport', 'export'};
            stage_times = zeros(1, numel(stage_names));

            t = tic; obj.load(DataFolder);            stage_times(1) = toc(t);
            t = tic; obj.parseEvents();               stage_times(2) = toc(t);
            t = tic; obj.parseEye();               stage_times(3) = toc(t);
            t = tic; obj.parseLFP();                  stage_times(4) = toc(t);
            t = tic; obj.parsePhotodiode();           stage_times(5) = toc(t);
            t = tic; obj.parseSpikes();               stage_times(6) = toc(t);
            t = tic; obj.prepareExport();             stage_times(7) = toc(t);
            t = tic; obj.export(OutputPath, BaseName); stage_times(8) = toc(t);

            % interleave name/time so one fprintf prints the whole table
            stage_report = [stage_names; num2cell(stage_times)];
            fprintf('\n--- Stage timing (s) ---\n');
            fprintf('  %-16s %8.2f\n', stage_report{:});
            fprintf('  %-16s %8.2f\n', 'TOTAL', sum(stage_times));
            fprintf('------------------------\n');
        end

        function load(obj, DataFolder)
        % Clear any previous session state, load one date folder's files into
        % obj.Loaded, and report which data products were actually loaded.
            obj.resetSession();
            obj.Loaded = obj.loadSession(DataFolder);

            S = obj.Loaded;
            fprintf('\n--- Loaded Blackrock data ---\n');
            fprintf('  Comments:   %s\n', S.comments_source);
            fprintf('  Eye:        %s\n', S.eye_status);
            fprintf('  LFP:        %s\n', S.lfp_status);
            fprintf('  Photodiode: %s\n', S.photodiode_status);
            fprintf('  Spikes:     %s\n', S.spike_status);
            fprintf('-----------------------------\n');
        end
        

        function S = loadSession(obj, DataFolder)
        % Orchestrator: assemble one date folder's Blackrock products into the
        % session struct S by delegating to loadComments / loadContinuous /
        % loadSpikes. Throws ONLY when comments cannot be obtained (loadComments
        % throws uncaught, so the caller's per-folder try/catch fails just that
        % folder). Continuous streams and spikes are gated by the load flags and fail soft:
        % their throws are caught here, recorded in a status string, and that
        % product is skipped.

            % defaults so every field exists on return
            S.Events           = [];
            S.EventTime        = [];
            S.EventTick        = uint64([]);
            S.EventTimeRes     = [];
            S.comments_source  = '';
            S.online_spike     = BlackrockLoader.spikeContainer();  % generic raw-spike container
            S.spike_status     = 'not requested';
            S.nsxdata          = [];
            S.uv_per_digit     = [];
            S.nsx_samplingrate = [];
            S.nsx_abs_time     = [];
            S.nsx_start_tick        = uint64(0);
            S.lfp_start_tick        = uint64(0);
            S.photodiode_start_tick = uint64(0);
            S.eye_status    = 'not requested';
            S.lfp_nsxdata          = [];
            S.lfp_uv_per_digit     = [];
            S.lfp_samplingrate     = [];
            S.lfp_abs_time         = [];
            S.lfp_timeresolution   = [];
            S.lfp_status           = 'not requested';
            S.photodiode_nsxdata        = [];
            S.photodiode_uv_per_digit   = [];
            S.photodiode_samplingrate   = [];
            S.photodiode_abs_time       = [];
            S.photodiode_timeresolution = [];
            S.photodiode_status         = 'not requested';
            % true when the photodiode rides in the eye ns2 stream, so it is
            % segmented together with the eye channels in one pass instead of
            % holding and re-cutting its own copy (see parseEye).
            S.photodiode_from_eye       = false;
            S.LoadEyeData      = obj.LoadEyeData;
            S.LoadLFPData         = obj.LoadLFPData;
            S.LoadPhotodiodeData  = obj.LoadPhotodiodeData;
            S.LoadOnlineSpikeData = obj.LoadOnlineSpikeData;
            S.LoadOnlineSpikeWaveform   = obj.LoadOnlineSpikeWaveform;
            S.IncludeUnsorted           = obj.IncludeUnsorted;
            S.timeresolution = [];

            % Parsed .nev structs shared between loadComments and loadSpikes for
            % this folder only: on legacy recordings both live in the same HUB
            % file, and parsing it costs a full read of a multi-GB file. Local,
            % so it is released when this call returns.
            nevCache = containers.Map('KeyType', 'char', 'ValueType', 'any');

            % --- Comments + comment timing (required): throws if none found ---
            C = obj.loadComments(DataFolder, nevCache);
            S.Events          = C.Events;
            S.EventTime       = C.EventTime;
            S.EventTick       = C.EventTick;
            S.EventTimeRes    = C.TimeRes;
            S.comments_source = C.comments_source;

             % Waveforms reuse the online-spike products, so they need spikes on.
            if obj.LoadOnlineSpikeWaveform && ~S.LoadOnlineSpikeData
                warning(['LoadOnlineSpikeWaveform is on but LoadOnlineSpikeData is off; ' ...
                    'spike waveforms need online spikes and are skipped.']);
            end

            % --- Online spike timing (gated, soft failure) ---
            % Deliberately loaded right after comments, before the continuous files:
            % on legacy recordings both come from the same HUB .nev, so running
            % them back-to-back lets the shared parse be dropped below instead of
            % staying resident through the (much larger) continuous-stream loads.
            if S.LoadOnlineSpikeData
                try
                    R = obj.loadSpikes(DataFolder, nevCache);
                    S.online_spike = R.online_spike;
                    S.spike_status = R.spike_status;
                catch ME_spk
                    S.LoadOnlineSpikeData = false;
                    S.spike_status = ['failed: ' ME_spk.message];
                    warning('%s', ['Spike loading ' S.spike_status]);
                end
            end
            remove(nevCache, keys(nevCache));   % every .nev consumer is done

            % --- Eye data, from the EyePrefix-*.ns2 (gated, soft failure) ---
            if S.LoadEyeData
                try
                    % [] keeps obj.EyeIdentifier; the prefix must be passed
                    % explicitly since loadContinuous defaults to match-any.
                    A = obj.loadContinuous(DataFolder, [], obj.EyePrefix);
                    S.nsxdata          = A.nsxdata;
                    S.uv_per_digit     = A.uv_per_digit;
                    S.nsx_samplingrate = A.nsx_samplingrate;
                    S.nsx_abs_time     = A.nsx_abs_time;
                    S.timeresolution   = A.timeresolution;
                    S.nsx_start_tick   = A.nsx_start_tick;
                    S.eye_status    = A.status;
                catch ME_ana
                    S.LoadEyeData = false;
                    S.eye_status = ['failed: ' ME_ana.message];
                    warning('%s', ['Eye loading ' S.eye_status]);
                end
            end

            % --- LFP (gated, soft failure). Independent of the eye stream:
            % same logic as loadContinuous above, different file schema. ---
            if S.LoadLFPData
                try
                    A = obj.loadContinuous(DataFolder, obj.LFPIdentifier, obj.LFPPrefix);
                    S.lfp_nsxdata        = A.nsxdata;
                    S.lfp_uv_per_digit   = A.uv_per_digit;
                    S.lfp_samplingrate   = A.nsx_samplingrate;
                    S.lfp_abs_time       = A.nsx_abs_time;
                    S.lfp_timeresolution = A.timeresolution;
                    S.lfp_start_tick     = A.nsx_start_tick;
                    S.lfp_status         = A.status;
                catch ME_lfp
                    S.LoadLFPData = false;
                    S.lfp_status = ['failed: ' ME_lfp.message];
                    warning('%s', ['LFP loading ' S.lfp_status]);
                end
            end

            % --- Photodiode (gated, soft failure). By default it rides in the
            % eye ns2 stream just loaded above, on rows PhotodiodeChannels. In
            % that case NOTHING is copied here: the eye stream is segmented once
            % in parseEye and the result is split by row, so we only record
            % that the photodiode comes from there. Falls back to (or, if
            % PhotodiodeUseSeparateFile is set, goes straight to) a dedicated
            % separate file using all of its channels. ---
            if S.LoadPhotodiodeData
                try
                    if obj.PhotodiodeUseSeparateFile
                        A = obj.loadContinuous(DataFolder, obj.PhotodiodeIdentifier, obj.PhotodiodePrefix);
                        S.photodiode_nsxdata        = A.nsxdata;   % all channels in the dedicated file
                        S.photodiode_uv_per_digit   = A.uv_per_digit;
                        S.photodiode_samplingrate   = A.nsx_samplingrate;
                        S.photodiode_abs_time       = A.nsx_abs_time;
                        S.photodiode_timeresolution = A.timeresolution;
                        S.photodiode_start_tick     = A.nsx_start_tick;
                        S.photodiode_status         = A.status;
                    elseif S.LoadEyeData && size(S.nsxdata, 1) >= max(obj.PhotodiodeChannels)
                        S.photodiode_from_eye       = true;
                        S.photodiode_samplingrate   = S.nsx_samplingrate;
                        S.photodiode_abs_time       = S.nsx_abs_time;
                        S.photodiode_timeresolution = S.timeresolution;
                        S.photodiode_start_tick     = S.nsx_start_tick;
                        S.photodiode_status = sprintf('ok (channels %s of the eye ns2)', ...
                            mat2str(obj.PhotodiodeChannels));
                    else
                        A = obj.loadContinuous(DataFolder, obj.PhotodiodeIdentifier, obj.PhotodiodePrefix);
                        S.photodiode_nsxdata        = A.nsxdata;   % all channels present
                        S.photodiode_uv_per_digit   = A.uv_per_digit;
                        S.photodiode_samplingrate   = A.nsx_samplingrate;
                        S.photodiode_abs_time       = A.nsx_abs_time;
                        S.photodiode_timeresolution = A.timeresolution;
                        S.photodiode_start_tick     = A.nsx_start_tick;
                        S.photodiode_status         = A.status;
                    end
                catch ME_pd
                    S.LoadPhotodiodeData = false;
                    S.photodiode_status = ['failed: ' ME_pd.message];
                    warning('%s', ['Photodiode loading ' S.photodiode_status]);
                end
            end
        end

          function C = loadComments(obj, DataFolder, nevCache)
        % Load comment strings + their timing from one date folder (required
        % product). Resolves the .nev by role prefix: NSP primary, then HUB
        % (legacy recordings kept comments in the HUB file). Returns a struct
        % with .Events, .EventTime, .EventTick, .TimeRes, .comments_source.
        %
        % EventTick is the raw uint64 clock ticks; EventTime is the same instants
        % in seconds, DERIVED from the ticks in commentFields (one place, so the
        % two cannot drift). Both are kept because they serve different jobs:
        % seconds is what the rest of the pipeline computes in, while ticks are
        % needed wherever an exact DIFFERENCE matters. These are absolute epoch
        % timestamps (~1.5e18 ns), so in seconds they land in a binade where a
        % double resolves only ~238 ns, and any time obtained by subtracting two
        % such seconds inherits that error from both operands. Subtracting the
        % ticks first and dividing after is exact -- see segmentSpikeWaveforms.
        % Throws if neither file
        % carries comments -- comments are mandatory for downstream parsing.
        % Pure: opens only the .nev it needs, touches no session state.
        %
        % nevCache is an optional containers.Map of already-parsed NEV structs
        % keyed by full path (see loadSession). Legacy recordings keep comments
        % AND spikes in the same HUB file, which loadSpikes then wants too, so
        % sharing the cache saves a second full parse of a multi-GB file. Note
        % openNEV's 'noread' is NOT a cheaper alternative here: it skips the
        % comment packets along with the waveforms.
            if nargin < 3; nevCache = []; end
            C.Events          = [];
            C.EventTime       = [];
            C.EventTick       = uint64([]);   % raw integer clock ticks (see below)
            C.TimeRes         = [];           % ticks per second for EventTick
            C.comments_source = '';

            nev_all = dir(fullfile(DataFolder, '*.nev'));
            nsp_nev = BlackrockLoader.pickByPrefix(nev_all, obj.CommentPrefix_primary);  % '' if none
            hub_nev = BlackrockLoader.pickByPrefix(nev_all, obj.CommentPrefix_legacy);   % '' if none

            if ~isempty(nsp_nev)
                nsp_data = BlackrockLoader.openNevCached(fullfile(DataFolder, nsp_nev), nevCache);
                if BlackrockLoader.hasComments(nsp_data)
                    C = BlackrockLoader.commentFields(nsp_data, nsp_nev);
                end
            end
            if isempty(C.comments_source) && ~isempty(hub_nev)
                hub_data = BlackrockLoader.openNevCached(fullfile(DataFolder, hub_nev), nevCache);
                if BlackrockLoader.hasComments(hub_data)
                    % legacy: comments live in the HUB file
                    C = BlackrockLoader.commentFields(hub_data, hub_nev);
                end
            end
            if isempty(C.comments_source)
                error('No comments found in %s-*.nev or %s-*.nev under: %s', ...
                    obj.CommentPrefix_primary, obj.CommentPrefix_legacy, DataFolder);
            end
        end

        function A = loadContinuous(obj, DataFolder, postFix, preFix)
        % Load ONE continuous (.nsx) stream for a date folder -- eye, LFP or
        % photodiode, depending on the prefix/extension asked for. Returns a struct with
        % .nsxdata, .uv_per_digit, .nsx_samplingrate, .nsx_abs_time,
        % .timeresolution, and .status. Throws if no matching file
        % is present or if the user cancels the multi-file selection dialog; the
        % orchestrator (loadSession) turns such throws into a soft status string.
        % Pure: opens only the .nsx it needs, touches no session state.
        %
        % .nsxdata is RAW int16 as stored on disk, not uV. openNSx's 'uv' option
        % forces the whole array to double (4x the file size in RAM, and these
        % files run to hundreds of MB), so instead we keep the samples int16 and
        % return .uv_per_digit -- the per-channel scale factor, nChan x 1 --
        % alongside. segmentContinuous applies it per trial slice, converting only
        % the data that is actually kept. uV = double(nsxdata) .* uv_per_digit.
        %
        % Both overrides apply to this call only and leave the config properties
        % untouched:
        %   postFix -- file extension. Accepts '.ns6', 'ns6' or '*.ns6'.
        %              Omitted/empty -> obj.EyeIdentifier ('*.ns2').
        %              Note .ns6 is 30 kHz broadband, ~30x the samples of a .ns2.
        %   preFix  -- filename prefix, e.g. 'NSP' or 'Hub1'. Omitted/empty ->
        %              no prefix filter, i.e. any file with that extension
        %              (several matches raise the selection dialog).
        %              loadSession always passes obj.EyePrefix, so the
        %              pipeline stays prefix-pinned.
        %
        %   loadContinuous(f)                  % '*.ns2', any prefix
        %   loadContinuous(f, '.ns6')          % '*.ns6', any prefix
        %   loadContinuous(f, '.ns6', 'NSP')   % '*.ns6', NSP only
        %   loadContinuous(f, [], 'Hub1')      % '*.ns2', Hub1 only
            if nargin < 3 || isempty(postFix)
                ident = obj.EyeIdentifier;
            else
                ident = postFix;
                if ~startsWith(ident, '*')
                    if ~startsWith(ident, '.'); ident = ['.' ident]; end
                    ident = ['*' ident];
                end
            end
            if nargin < 4 || isempty(preFix)
                preFix = '';
            end

            A.nsxdata          = [];
            A.uv_per_digit     = [];
            A.nsx_samplingrate = [];
            A.nsx_abs_time     = [];
            A.timeresolution   = [];
            A.nsx_start_tick   = uint64(0);   % raw tick of sample 1, for the
                                              % exact window arithmetic
            A.status    = '';

            % No prefix -> take every match; filterByPrefix cannot express
            % match-any (its '^' regex returns a zero-length match, which reads
            % as "no match" and would drop everything).
            ns_list = dir(fullfile(DataFolder, ident));
            if ~isempty(preFix)
                ns_list = BlackrockLoader.filterByPrefix(ns_list, preFix);
            end
            if isempty(ns_list)
                if isempty(preFix); prefix_desc = 'any-prefix'; else; prefix_desc = preFix; end
                error('No %s %s continuous file found.', prefix_desc, ident);
            end
            ns_names = {ns_list.name};
            if numel(ns_names) > 1
                [sel, ok] = listdlg('PromptString', ...
                    sprintf('Select eye (%s) file to load (Cancel = skip):', ident), ...
                    'SelectionMode', 'single', 'ListString', ns_names, 'ListSize', [400 200]);
                if ~ok
                    error('Continuous file selection cancelled by user.');
                end
                Filename_ns = ns_names{sel};
            else
                Filename_ns = ns_names{1};
            end

            % 'int16' keeps the samples as stored; the uV conversion is deferred
            % to segmentContinuous via uv_per_digit (see the header comment).
            % Reading without 'uv' makes NPMK warn about the raw units and then
            % PROMPT for a keypress, which would stall a batch run, so the
            % warning is muted for the duration of the call and the user's
            % NPMK setting restored afterwards.
            restoreWarn = BlackrockLoader.muteNpmkUvPrompt();
            cleanup = onCleanup(restoreWarn);
            tmp_ana_data = openNSx(fullfile(DataFolder, Filename_ns), 'read', 'report', 'int16');
            clear cleanup   % restore now rather than at function exit
            A.nsxdata          = tmp_ana_data.Data;                       % raw int16
            % Same per-channel factor openNSx applies for 'uv' (MaxAnalogValue
            % over MaxDigiValue), kept as a column so it broadcasts down the
            % channel dimension of a chan x samples slice.
            A.uv_per_digit     = double([tmp_ana_data.ElectrodesInfo.MaxAnalogValue])' ./ ...
                                 double([tmp_ana_data.ElectrodesInfo.MaxDigiValue])';
            nsx_starttime      = tmp_ana_data.MetaTags.Timestamp;
            nsx_timeresolution = tmp_ana_data.MetaTags.TimeRes;
            A.nsx_samplingrate = tmp_ana_data.MetaTags.SamplingFreq;
            nsx_starttimeSec   = nsx_starttime / nsx_timeresolution;
            N = size(A.nsxdata, 2);
            nsx_rel_time       = (0:N-1) / A.nsx_samplingrate;            % from start time
            A.nsx_abs_time     = nsx_starttimeSec + nsx_rel_time;
            A.timeresolution   = nsx_timeresolution;
            A.nsx_start_tick   = uint64(nsx_starttime);
            A.status    = sprintf('ok (%s)', Filename_ns);
        end

        function R = loadSpikes(obj, DataFolder, nevCache)
        % Load online spike timing (+ optional waveforms) for one date folder.
        % Opens the HUB-*.nev itself and converts timestamps to seconds using the
        % NEV's OWN clock (MetaTags.TimeRes; falls back to 1e9 if absent), so the
        % result is independent of whether the eye stream was loaded. Drops unsorted
        % (unit 0) / noise (unit 255) spikes unless IncludeUnsorted is set.
        % Returns a struct with .online_spike (the generic spike container) and
        % .spike_status. Throws if no HUB file or no spike timestamps are present.
        % Pure: opens only the .nev it needs, touches no session state.
        %
        % nevCache is the same optional already-parsed-NEV map loadComments
        % takes; on legacy recordings both products come out of one HUB file, so
        % passing it means that file is parsed once per folder instead of twice.
            if nargin < 3; nevCache = []; end
            R.online_spike = BlackrockLoader.spikeContainer();
            R.spike_status = '';

            nev_all = dir(fullfile(DataFolder, '*.nev'));
            hub_nev = BlackrockLoader.pickByPrefix(nev_all, obj.SpikePrefix);   % '' if none
            if isempty(hub_nev)
                error('No %s-*.nev file for online spikes.', obj.SpikePrefix);
            end
            hub_data = BlackrockLoader.openNevCached(fullfile(DataFolder, hub_nev), nevCache);
            if ~BlackrockLoader.hasSpikes(hub_data)
                error('No spike timestamps in %s', hub_nev);
            end

            % Load and transform spiketime into seconds using the NEV's own
            % timestamp clock. TimeStamp is uint64; cast to double FIRST,
            % otherwise the divide stays integer-typed and rounds spike times to
            % whole seconds.
            if isfield(hub_data.MetaTags, 'TimeRes') && hub_data.MetaTags.TimeRes > 0
                timeRes = double(hub_data.MetaTags.TimeRes);
            else
                disp('Use empircle time resolution: 10^9')
                timeRes = 10^9;
            end
            spikeTimeTick = hub_data.Data.Spikes.TimeStamp;   % uint64, exact
            spikeTimeSec  = double(spikeTimeTick)/timeRes;
            % keep channel identity for per-trial rasterization
            spikeChannel  = hub_data.Data.Spikes.Electrode;
            spikeUnit     = hub_data.Data.Spikes.Unit;
            spikeWaveform = [];   % stays empty unless waveforms are requested

            % Optional per-spike waveforms (opt-in via LoadOnlineSpikeWaveform).
            % openNEV returns Waveform as [nSamp x nSpikes] int16 with columns
            % aligned 1:1 to TimeStamp/Electrode/Unit. This is the largest array
            % in the session, so it stays int16 and the uV scale travels beside
            % it as a per-spike factor; segmentSpikeWaveforms applies it to the
            % in-window spikes it actually keeps. Same conversion openNEV's 'uv'
            % path uses: wf_uV = raw .* DigitalFactor(electrode) / 1000.
            spikeWaveformScale = [];   % 1 x nSpikes uV-per-digit, [] when no waveforms
            if obj.LoadOnlineSpikeWaveform && isfield(hub_data.Data.Spikes, 'Waveform') ...
                    && ~isempty(hub_data.Data.Spikes.Waveform)
                spikeWaveform = hub_data.Data.Spikes.Waveform;              % [nSamp x nSpikes] int16
                % Look the factor up per electrode, then index by spike. Building
                % it as [ElectrodesInfo(elecIdx).DigitalFactor] instead expands a
                % comma-separated list with one struct element per spike.
                digiByElectrode = double([hub_data.ElectrodesInfo.DigitalFactor]) / 1000;
                spikeWaveformScale = digiByElectrode(double(hub_data.Data.Spikes.Electrode));
            end

            % Drop unsorted (unit 0) and noise (unit 255) spikes unless opted in.
            % time/channel/unit are 1 x nSpikes; waveform is nSamp x nSpikes
            % with columns aligned 1:1 -- filter all together so they stay aligned.
            if ~obj.IncludeUnsorted
                keep = ~ismember(double(spikeUnit), [0 255]);
                nDropped = sum(~keep);
                spikeTimeSec  = spikeTimeSec(keep);
                spikeTimeTick = spikeTimeTick(keep);
                spikeChannel = spikeChannel(keep);
                spikeUnit    = spikeUnit(keep);
                if ~isempty(spikeWaveform)
                    spikeWaveform      = spikeWaveform(:, keep);
                    spikeWaveformScale = spikeWaveformScale(keep);
                end
                R.spike_status = sprintf('ok (%s; dropped %d unsorted/noise spikes)', hub_nev, nDropped);
            else
                R.spike_status = sprintf('ok (%s)', hub_nev);
            end

            % Pack into the generic, source-agnostic container that
            % parseSpikes/segmentSpikes then rasterize per trial.
            R.online_spike.TimeSec  = spikeTimeSec;
            R.online_spike.TimeTick = spikeTimeTick;
            R.online_spike.TimeRes  = timeRes;
            R.online_spike.Channel  = spikeChannel;
            R.online_spike.Unit     = spikeUnit;
            R.online_spike.Waveform = spikeWaveform;
            if ~isempty(spikeWaveform)
                R.online_spike.WaveformScale = spikeWaveformScale;
                R.online_spike.WaveformUnit  = 'microVolts';
            end
            R.online_spike.source = 'online';
        end


        function [trials, experiment, startTicks, endTicks] = parseEvents(obj, Events, EventTime, EventTick)
        % Parse the .nev comment strings into one experiment entry per session
        % and one trials entry per (position-keyed) trial. A single .nev can
        % hold several sessions (task started/stopped), so experiment is a
        % struct array indexed by session; trials are keyed by position so a
        % resetting trial counter starts new trials.
        %
        % Called with no data args it reads obj.Loaded (the stateful pipeline);
        % pass Events/EventTime explicitly to parse an arbitrary comment set.
        % Either way the result is stored in obj.Trials / obj.Experiment /
        % obj.TrialStartTicks AND returned.
        %
        % This is the argument-resolution + state-storing shell; the parse
        % itself lives in the delegate below so that the same inputs can be run
        % through two implementations side by side without either of them
        % clobbering obj state (see Test_parseEvents_AB.m).
            if nargin < 2
                Events    = obj.Loaded.Events;
                EventTime = obj.Loaded.EventTime;
            end
            if nargin < 4
                if nargin < 2 && isfield(obj.Loaded, 'EventTick')
                    EventTick = obj.Loaded.EventTick;
                else
                    EventTick = uint64([]);   % caller supplied seconds only
                end
            end
    
            [trials, experiment, startTicks, endTicks] = ...
                obj.parseEventsFast(Events, EventTime, EventTick);
    
            %{
          disp('Use legacy parser');
             [trials, experiment, startTicks, endTicks] = ...
                obj.parseEventsLegacy(Events, EventTime, EventTick);
            %}
            obj.Trials          = trials;
            obj.Experiment      = experiment;
            obj.TrialStartTicks = startTicks;
            obj.TrialEndTicks   = endTicks;
        end

        function [trials, experiment, startTicks, endTicks] = parseEventsFast(obj, Events, EventTime, EventTick)
        % Set-oriented parse: tokenize every comment at once, index trials by
        % cumsum, classify each DISTINCT event body once, then scatter the
        % values one pass per field.
        %
        % The per-comment parser did the work comment-major even though the
        % information is pattern-major -- a 109k-comment session carries only
        % ~600 distinct event bodies, so it re-ran the same regex battery
        % hundreds of times per pattern. Nothing here loops over comments.
            % openNEV hands these back as 1xN; every scatter below assumes
            % columns, and the mismatch would broadcast silently.
            EventTime = EventTime(:);
            EventTick = EventTick(:);
            has_ticks = numel(EventTick) == size(Events, 1);

            K = BlackrockLoader.tokenizeComments(Events);
            K = BlackrockLoader.indexCommentTrials(K);
            Session = BlackrockLoader.sessionLabelsFromResets(K);

            [ub, ~, ic] = unique(K.body(K.isTrialLine));
            spec = BlackrockLoader.classifyEventBodies(ub, obj.EventMaps, obj.TrialTemplate);

            [cols, dupCells, undCells, startTicks, endTicks, nUndef] = BlackrockLoader.scatterEventWrites( ...
                spec, ic, K, Session, EventTime, EventTick, has_ticks, obj.TrialTemplate);

            trials     = BlackrockLoader.assembleTrialStruct(cols, dupCells, undCells, obj.TrialTemplate);
            experiment = BlackrockLoader.buildExperimentMeta(K, EventTime, obj.ExpTemplate, ...
                                                             obj.EventMaps.ExpEvents, Session);

            if obj.Verbose
                % The per-comment parser printed as it walked, which cannot be
                % reproduced in comment order without the loop it replaced. A
                % summary carries the same information and costs nothing.
                dupAll = vertcat(dupCells{:});
                undAll = vertcat(undCells{:});
                fprintf('parseEvents: %d comments -> %d trials, %d session(s); %d distinct event bodies\n', ...
                    numel(K.txt), K.nTrials, max([Session; 0]), numel(ub));
                fprintf('  undefined %d, duplicates %d, malformed %d\n', ...
                    numel(undAll), numel(dupAll), sum(K.isMalformed));
                if ~isempty(undAll)
                    fprintf('  undefined events:\n');
                    fprintf('    %s\n', unique(undAll));
                end
                if ~isempty(dupAll)
                    fprintf('  duplicated events:\n');
                    fprintf('    %s\n', unique(dupAll));
                end
            elseif nUndef > 0
                warning(['parseEvents: %d comment(s) matched no known event and went to ' ...
                    'trials.undefined. Set the loader''s Verbose flag to list them.'], nUndef);
            end
            if any(K.isMalformed)
                % Neither an Experiment line nor a "Trial N:" line, so there is
                % no trial to attach it to. The per-comment parser died here.
                warning('BlackrockLoader:parseEvents:MalformedComment', ...
                    ['%d comment(s) matched neither the Experiment nor the "Trial N:" ' ...
                     'form and were skipped. First: "%s"'], ...
                    sum(K.isMalformed), K.txt(find(K.isMalformed, 1)));
            end

            trials = BlackrockLoader.addDerivedTrialFeatures(trials);
        end

        function [trials, experiment, startTicks, endTicks] = parseEventsLegacy(obj, Events, EventTime, EventTick)
        % TEMPORARY reference implementation, kept only to A/B against the
        % vectorised parser. Comment-major: one loop iteration per comment
        % string, which is ~1.4e5 iterations for a 5000-trial session.
        % Returns its products instead of writing obj state, so the A/B script
        % can run both parsers over the same inputs.
        %
        % Delete this method (and Test_parseEvents_AB.m) once real-data
        % equivalence has been confirmed.
            has_ticks = numel(EventTick) == size(Events, 1);

            exp_template       = obj.ExpTemplate;
            trial              = obj.TrialTemplate;
            exp_events         = obj.EventMaps.ExpEvents;
            time_events        = obj.EventMaps.TimeEvents;
            segment_events     = obj.EventMaps.SegmentEvents;
            information_events = obj.EventMaps.InformationEvents;
            dash_events        = obj.EventMaps.DashEvents;
            outcome_events     = obj.EventMaps.OutcomeEvents;
            verbose            = obj.Verbose;

            % keys() on a containers.Map builds (and sorts) a fresh cell array
            % every call. These lists are fixed for the whole parse, so they are
            % materialised once here instead of several times per event across
            % ~1e5 events.
            exp_event_keys     = keys(exp_events);
            time_event_keys    = keys(time_events);
            info_event_keys    = keys(information_events);
            segment_event_keys = keys(segment_events);

            % Regex patterns, hoisted for the same reason (the combined one was
            % being re-concatenated on every iteration).
            exp_pattern      = '^Experiment (start|end):\s*(.+)$';
            trial_pattern    = '^Trial\s+(\d+):\s*(.*)$';
            coord_pattern    = '^(.*?)\s*\(\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\)\s*deg$';
            reward_pattern   = '^(.*?)\s*\(([\d\.]+)ms';
            time_pattern     = '^(.*?)\s+([-+]?\d*\.?\d+|None|none)\s*ms$';
            size_pattern     = '^(.*?)\s+([-+]?\d*\.?\d+)\s*(?:deg)?$';
            combined_pattern = [time_pattern, '|', size_pattern];

            EventsNumber = size(Events, 1);

            % Preallocate and grow by doubling, trimming at the end. Extending a
            % 60+ field struct array one element at a time reallocated the whole
            % array on every new trial; sizing it to EventsNumber up front would
            % instead allocate one struct element per comment, most of them
            % unused. Doubling keeps both bounded.
            experiment    = repmat(exp_template, 16, 1);
            trials        = repmat(trial, 1024, 1);
            % Raw integer tick of each trial's Start marker, parallel to trials.
            % Kept OUTSIDE the trial struct on purpose: the template is all
            % doubles and feeds struct2table for the CSV, and a uint64 field
            % would either break that or be silently demoted back to a double
            % (losing the exactness this exists for). 0 = not seen.
            startTicks    = zeros(1024, 1, 'uint64');
            endTicks      = zeros(1024, 1, 'uint64');
            session_index = 0;
            trial_index   = 0;
            prev_trial_number = NaN;
            prev_session      = NaN;
            n_undefined       = 0;   % events no branch claimed; summarised after the loop

            for i = 1:EventsNumber
                curr_event = Events(i, :);
                curr_eventtime = EventTime(i);
                %First check if it is an experimental setup
                exp_flag = regexp(curr_event, exp_pattern, 'tokens');
                if ~isempty(exp_flag)
                    %Get the experiment meta data
                    exp_marker = exp_flag{1}{1}; %start or end
                    exp_token  = strtrim(exp_flag{1}{2});

                    %A new session begins at each "Experiment start: git commit ..." line
                    %(the first line of every metadata block within the recording).
                    if strcmp(exp_marker,'start') && startsWith(exp_token,'git commit')
                        session_index = session_index + 1;
                        if session_index > numel(experiment)
                            % doubling, not per-iteration growth: amortised O(1)
                            experiment = [experiment; repmat(exp_template, numel(experiment), 1)]; %#ok<AGROW>
                        end
                        experiment(session_index) = exp_template;
                        experiment(session_index).start = curr_eventtime;
                    end

                    if session_index >= 1
                        if strcmp(exp_marker,'end')
                            experiment(session_index).end = curr_eventtime; %last end line wins
                            if ~startsWith(exp_token,'git commit')
                                %Capture why the session ended (e.g. 'experimenter closed task').
                                %The git-commit end line is just a commit re-stamp, not a reason.
                                experiment(session_index).end_by = exp_token;
                            end
                        end

                        %Saved meta data into the current session
                        if startsWith(exp_token,'git commit')
                            experiment(session_index).git_commit = strtrim(strrep(exp_token,'git commit',''));
                        elseif startsWith(exp_token,'eyetracker tracking')
                            eye_tokens = regexp(exp_token,'eyetracker tracking (\w+)','tokens');
                            experiment(session_index).eye_tracked = eye_tokens{1}{1};
                        elseif startsWith(exp_token,'photodiode')
                            %Photodiode metadata: 'circles visible/hidden' or a (x, y) deg position
                            coord = regexp(exp_token, '\(\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\)', 'tokens');
                            if startsWith(exp_token,'photodiode circles')
                                experiment(session_index).photodiode_circles = strtrim(strrep(exp_token,'photodiode circles',''));
                            elseif startsWith(exp_token,'photodiode fixation position') && ~isempty(coord)
                                experiment(session_index).photodiode_fixation_position = cellfun(@str2double, coord{1});
                            elseif startsWith(exp_token,'photodiode target_1 position') && ~isempty(coord)
                                experiment(session_index).photodiode_target_1_position = cellfun(@str2double, coord{1});
                            elseif startsWith(exp_token,'photodiode target_2 position') && ~isempty(coord)
                                experiment(session_index).photodiode_target_2_position = cellfun(@str2double, coord{1});
                            end
                        elseif strcmp(exp_token,'experimenter closed task')
                            %end marker text, nothing to store
                        else
                            %Numeric data (viewing distance / screen size / resolution / FPS / rate)
                            num_tokens = regexp(exp_token, ...
                                '^\s*(.*?)\s+(\d+\.?\d*)\D*(\d+\.?\d*)?', 'tokens');
                            if ~isempty(num_tokens)
                                event_exp      = strtrim(num_tokens{1}{1});
                                nums           = cellfun(@str2double,num_tokens{1}(2:end));
                                flag_array     = contains(exp_event_keys,event_exp);
                                if any(flag_array)
                                    field = exp_events(exp_event_keys{flag_array});
                                    experiment(session_index).(field) = nums(~isnan(nums));
                                end
                            end
                        end

                    end

                else %Trial data

                    %Get trial number and event text
                     mainTokens = regexp(curr_event, trial_pattern, 'tokens');
                     TrialNum_curr = str2double(mainTokens{1}{1}); % Get trial number
                     event_text = strtrim(mainTokens{1}{2}); %Get the remaining events

                    % Define the current trial.
                    % A new trial begins whenever the parsed trial number changes from the
                    % previous trial event, OR the session changes. Trials are keyed by
                    % POSITION (trial_index), not by number, so a reset counter
                    % (e.g. ...,30,0,1,...) starts new trials instead of merging into an
                    % earlier same-numbered trial. The session test also splits trials that
                    % share a number across two sessions (e.g. session 1 trial 1 vs session 2
                    % trial 1).
                    if trial_index == 0
                        % first trial event
                        trial_index = 1;
                        trials(trial_index) = trial;
                        trials(trial_index).Trial_number = TrialNum_curr;
                        trials(trial_index).Session = session_index;
                        prev_trial_number = TrialNum_curr;
                        prev_session = session_index;
                    else
                        if TrialNum_curr ~= prev_trial_number || session_index ~= prev_session
                            % trial number or session changed -> start a new trial
                            trial_index = trial_index + 1;
                            if trial_index > numel(trials)
                                % doubling, not per-iteration growth: amortised O(1)
                                trials = [trials; repmat(trial, numel(trials), 1)]; %#ok<AGROW>
                                startTicks = [startTicks; zeros(numel(startTicks), 1, 'uint64')]; %#ok<AGROW>
                                endTicks   = [endTicks;   zeros(numel(endTicks),   1, 'uint64')]; %#ok<AGROW>
                            end
                            currTrial = trial;
                            currTrial.Trial_number = TrialNum_curr;
                            currTrial.Session = session_index;
                            trials(trial_index) = currTrial;
                        end
                        prev_trial_number = TrialNum_curr;
                        prev_session = session_index;
                    end

                   %go through each type of events
                   time_flag = contains(event_text, time_event_keys);
                   info_flag = contains(event_text, info_event_keys);
                   seg_flag = contains(event_text, segment_event_keys);
                   dash_flag = contains(event_text, dash_events) & contains(event_text, '-');
                   outcome_flag = contains(event_text, outcome_events);
                   offset_range_flag = contains(event_text, 'Requested time offset range');


                   if time_flag
                     %Directly assign current time
                     flag_array = contains(time_event_keys,event_text);
                     curr_key = time_event_keys{flag_array};
                     field = time_events(curr_key);

                     if isnan(trials(trial_index).(field))
                         %First check whether it's already assigned
                        trials(trial_index).(field) = curr_eventtime;
                        if has_ticks && strcmp(field, 'Start')
                            % keep the Start marker's exact tick: per-spike times
                            % are measured from it, and doing that subtraction in
                            % seconds would inherit ~238 ns of rounding
                            startTicks(trial_index) = EventTick(i);
                        end
                     else
                         %Otherwise, put it into the duplicates for further debug
                          trials(trial_index).duplicates(end+1,1) = event_text;
                          if verbose; disp('Duplicate found for time event:'); end
                          if verbose; disp(event_text); end

                     end




                   elseif info_flag
                       %Extract values following the event
                       %(coord/reward/time/size/combined patterns are hoisted above the loop)
                       coor_tokens = regexp(event_text, coord_pattern, 'tokens');
                       reward_tokens = regexp(event_text, reward_pattern, 'tokens');


                       if ~isempty(coor_tokens)
                           %Get the event and coordinate/reward amount
                           event_coord = strtrim(coor_tokens{1}{1});
                           coord = cellfun(@str2double, coor_tokens{1}(2:end));
                           flag_array = contains(info_event_keys,event_coord);
                           curr_key = info_event_keys{flag_array};
                           field = information_events(curr_key);
                           if all(isnan(trials(trial_index).(field)))
                               %If it is empty
                               trials(trial_index).(field) = coord;
                           else
                               trials(trial_index).duplicates(end+1,1) = event_coord;
                                if verbose; disp('Duplicate found for coor event:'); end
                                if verbose; disp(event_coord); end

                           end


                       elseif ~isempty(reward_tokens)
                           event_reward = strtrim(reward_tokens{1}{1});
                           reward_amount = cellfun(@str2double, reward_tokens{1}(2:end));
                           flag_array = contains(info_event_keys,event_reward);
                           curr_key = info_event_keys{flag_array};
                           field = information_events(curr_key);
                           if isnan(trials(trial_index).(field) )
                               trials(trial_index).(field) = curr_eventtime;
                           else
                               trials(trial_index).duplicates(end+1,1) = field;
                               if verbose; disp('Duplicate found for reward event:'); end
                                if verbose; disp(event_reward); end
                           end

                           if isnan(trials(trial_index).Reward_amount)
                                trials(trial_index).Reward_amount = reward_amount;
                           else
                               trials(trial_index).duplicates(end+1,1) = 'Reward_amount';
                               if verbose; disp('Duplicate found for reward amount'); end

                           end




                       else
                           tokens = regexp(event_text, combined_pattern, 'tokens');
                           %Get the event and duration

                           event_dur = strtrim(tokens{1}{1});
                           dur = str2double(tokens{1}{2});
                           flag_array = contains(info_event_keys,event_dur);
                           curr_key = info_event_keys{flag_array};
                           field = information_events(curr_key);


                           if isnan(trials(trial_index).(field))
                                trials(trial_index).(field) = dur;
                           else
                               trials(trial_index).duplicates(end+1,1) = field;
                                if verbose; disp('Duplicate found for duration/size event:'); end
                                if verbose; disp(event_dur); end

                           end

                       end



                   elseif seg_flag
                       %segment the text by the last space

                       last_space_idx = find(event_text == ' ', 1, 'last');
                       event_name = strtrim(event_text(1:last_space_idx-1));
                       value = strtrim(event_text(last_space_idx+1:end));
                       flag_array = contains(segment_event_keys,event_name);
                       curr_key = segment_event_keys{flag_array};
                       field = segment_events(curr_key);

                       if isnan(trials(trial_index).(field))
                          trials(trial_index).(field) = value;
                       else
                           trials(trial_index).duplicates(end+1,1) = field;
                           if verbose; disp('Duplicate found for segment event:'); end
                           if verbose; disp(field); end

                       end

                   elseif dash_flag
                       %segment the text by the dash
                       dash_idx = find(event_text == '-', 1, 'first');
                       event   = strtrim(event_text(1:dash_idx-1));
                       outcome = strtrim(event_text(dash_idx+1:end));
                       if contains(event,'End')



                           if isnan(trials(trial_index).End)
                               trials(trial_index).End = curr_eventtime;
                               if has_ticks
                                   % exact End tick, for the same reason as Start
                                   endTicks(trial_index) = EventTick(i);
                               end
                           else
                               trials(trial_index).duplicates(end+1,1) = event;
                                if verbose; disp('Duplicate End  found for dash event:'); end
                                if verbose; disp(event); end

                           end

                           if isnan(trials(trial_index).Trialoutcome)
                                trials(trial_index).Trialoutcome = outcome;
                           else
                               trials(trial_index).duplicates(end+1,1) ='Trialoutcome';
                                if verbose; disp('Duplicate outcome found for dash event:'); end
                                if verbose; disp(event); end

                           end
                       elseif contains(event,'choice')
                           if isnan(trials(trial_index).Choosen_choice)
                                trials(trial_index).Choosen_choice = outcome;
                           else
                               trials(trial_index).duplicates(end+1,1) ='Choosen_choice';
                                if verbose; disp('Duplicate found for dash event:'); end
                                if verbose; disp(event); end

                           end
                       else
                           if verbose; disp('Undefined dash event:'); end
                           if verbose; disp(event_text); end
                           if verbose; disp('Check the undefined var'); end
                           n_undefined = n_undefined + 1;
                           trials(trial_index).undefined(end+1,1) = string(event_text);
                       end

                   elseif outcome_flag
                       %Save the choice outcome and time
                       if isnan(trials(trial_index).Choiceoutcome)
                            trials(trial_index).Choiceoutcome = event_text;
                       else
                           trials(trial_index).duplicates(end+1,1) ='Choiceoutcome';
                                if verbose; disp('Duplicate found for outcome event:'); end
                                if verbose; disp(event_text); end

                       end
                       %{
                       if isnan(trials(trial_index).Choicetime )
                            trials(trial_index).Choicetime = curr_eventtime;
                       else
                            trials(trial_index).duplicates(end+1,1) ='Choicetime';
                                if verbose; disp('Duplicate found for outcome event:'); end
                                if verbose; disp('Choicetime'); end

                       end
                       %}

                   elseif offset_range_flag
                       % "Requested time offset range [min, max] ms (active: [v1, v2, ...])"
                       % Range -> two numeric fields; active list -> a space-separated string
                       % (CSV columns cannot hold multiple values).
                       range_tok  = regexp(event_text, 'range\s*\[\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\]', 'tokens');
                       active_tok = regexp(event_text, 'active:\s*\[([^\]]*)\]', 'tokens');
                       if ~isempty(range_tok)
                           trials(trial_index).Requested_time_offset_min = str2double(range_tok{1}{1});
                           trials(trial_index).Requested_time_offset_max = str2double(range_tok{1}{2});
                       end
                       if ~isempty(active_tok)
                           active_vals = strtrim(strsplit(active_tok{1}{1}, ','));
                           trials(trial_index).Requested_time_offset_active = char(strjoin(active_vals, ' '));
                       end

                   else
                       %Undefined fields
                       if verbose; disp('Undefined event detected:'); end
                       if verbose; disp(event_text); end
                       if verbose; disp('Check the undefined var'); end
                       n_undefined = n_undefined + 1;
                       trials(trial_index).undefined(end+1,1) = string(event_text);

                   end



                   if trials(trial_index).Start > 0
                       trials(trial_index).Save_complete = 1;

                   end

                end %End of if the judgement of if it is experiment flag or trial flag

            end

            % Trim the preallocated slack back to what was actually filled.
            trials     = trials(1:trial_index);
            experiment = experiment(1:session_index);
            startTicks = startTicks(1:trial_index);
            endTicks   = endTicks(1:trial_index);

            % One summary instead of three lines per unmatched event: a task
            % software change can send every event down the undefined path, and
            % printing that per event costs more than the whole parse. The
            % strings are still kept per trial in trials.undefined.
            if n_undefined > 0 && ~verbose
                warning(['parseEvents: %d comment(s) matched no known event and went to ' ...
                    'trials.undefined. Set the loader''s Verbose flag to list them.'], n_undefined);
            end

            trials = BlackrockLoader.addDerivedTrialFeatures(trials);
        end

        function A = parseEye(obj)
        % Segment the loaded eye stream into per-trial slices, stored in
        % obj.Eye (rows EyeChannels). When the photodiode rides in the same
        % file it is produced here too, from the same single segmentation pass.
        % When the eye stream was not loaded, obj.Eye is [].
            obj.segmentEyeStream();
            A = obj.Eye;
        end

        function A = parseLFP(obj)
        % Segment the loaded LFP stream into per-trial slices, stored in
        % obj.LFP. When LFP was not loaded, obj.LFP is [].
            if isempty(obj.Loaded) || ~obj.Loaded.LoadLFPData
                obj.LFP = [];
            else
                S = obj.Loaded;
                obj.LFP = BlackrockLoader.segmentContinuous(obj.Trials, S.lfp_nsxdata, ...
                    S.lfp_abs_time, S.lfp_samplingrate, ...
                    obj.Segment_PreBuffer, obj.Segment_PostBuffer, S.lfp_uv_per_digit, ...
                    obj.TrialStartTicks, obj.TrialEndTicks, S.lfp_start_tick, ...
                    BlackrockLoader.sharedTimeRes(S.EventTimeRes, S.lfp_timeresolution));
                obj.freeRaw({'lfp_nsxdata', 'lfp_abs_time'});
            end
            A = obj.LFP;
        end

        function A = parsePhotodiode(obj)
        % Segment the loaded photodiode stream into per-trial slices, stored in
        % obj.Photodiode. When photodiode was not loaded, obj.Photodiode is [].
        %
        % In the default layout the photodiode lives on rows PhotodiodeChannels
        % of the eye ns2, so the work is done by the shared eye-stream pass --
        % calling this after parseEye is then a no-op, and calling it on its
        % own runs that pass (which also fills obj.Eye). Only a dedicated
        % photodiode file is segmented separately here.
            if isempty(obj.Loaded) || ~obj.Loaded.LoadPhotodiodeData
                obj.Photodiode = [];
            elseif obj.Loaded.photodiode_from_eye
                obj.segmentEyeStream();
            else
                S = obj.Loaded;
                obj.Photodiode = BlackrockLoader.segmentContinuous(obj.Trials, S.photodiode_nsxdata, ...
                    S.photodiode_abs_time, S.photodiode_samplingrate, ...
                    obj.Segment_PreBuffer, obj.Segment_PostBuffer, S.photodiode_uv_per_digit, ...
                    obj.TrialStartTicks, obj.TrialEndTicks, S.photodiode_start_tick, ...
                    BlackrockLoader.sharedTimeRes(S.EventTimeRes, S.photodiode_timeresolution));
                obj.freeRaw({'photodiode_nsxdata', 'photodiode_abs_time'});
            end
            A = obj.Photodiode;
        end

        function segmentEyeStream(obj)
        % Segment the eye ns2 ONCE and split the result by channel row into
        % obj.Eye (EyeChannels) and, when the photodiode rides in the same
        % file, obj.Photodiode (PhotodiodeChannels).
        %
        % Both products come out of a single segmentContinuous pass because they are
        % the same samples on the same clock -- cutting the stream twice was
        % pure duplicated work. Memoised on the products already existing, so
        % parseEye and parsePhotodiode can be called in either order, or
        % individually, and the pass still runs exactly once.
            if isempty(obj.Loaded) || ~obj.Loaded.LoadEyeData
                obj.Eye = [];
                return
            end
            S = obj.Loaded;
            wants_pd = S.LoadPhotodiodeData && S.photodiode_from_eye;
            if ~isempty(obj.Eye) && (~wants_pd || ~isempty(obj.Photodiode))
                return   % already segmented
            end
            if isempty(S.nsxdata)
                % raw stream already released (FreeRawAfterParse) and whatever
                % was asked for is gone -- nothing left to segment
                return
            end

            full = BlackrockLoader.segmentContinuous(obj.Trials, S.nsxdata, ...
                S.nsx_abs_time, S.nsx_samplingrate, ...
                obj.Segment_PreBuffer, obj.Segment_PostBuffer, S.uv_per_digit, ...
                obj.TrialStartTicks, obj.TrialEndTicks, S.nsx_start_tick, ...
                BlackrockLoader.sharedTimeRes(S.EventTimeRes, S.timeresolution));

            nChan = size(full.data, 1);
            obj.Eye = BlackrockLoader.subsetChannels(full, ...
                BlackrockLoader.clampChannels(obj.EyeChannels, nChan, 'EyeChannels'));
            if wants_pd
                obj.Photodiode = BlackrockLoader.subsetChannels(full, ...
                    BlackrockLoader.clampChannels(obj.PhotodiodeChannels, nChan, 'PhotodiodeChannels'));
            end
            obj.freeRaw({'nsxdata', 'nsx_abs_time'});
        end

        function freeRaw(obj, fields)
        % Release named raw fields of obj.Loaded once their per-trial product
        % exists. Raw continuous streams are the largest thing the loader holds;
        % without this the raw and segmented copies of every stream stay live
        % until the next load(), which is what pushes big sessions into swap.
        % Disabled by FreeRawAfterParse when you want obj.Loaded inspectable.
            if ~obj.FreeRawAfterParse || isempty(obj.Loaded)
                return
            end
            for k = 1:numel(fields)
                if isfield(obj.Loaded, fields{k})
                    obj.Loaded.(fields{k}) = [];
                end
            end
        end

        function R = parseSpikes(obj)
        % Parse the spikes into trial based structor and rasterize the loaded online spikes into obj.Spike and, when
        % LoadOnlineSpikeWaveform is on, collect per-spike waveforms into
        % obj.SpikeWaveformData. Products that were not loaded stay [].
            obj.Spike = [];
            obj.SpikeWaveformData = [];
            if isempty(obj.Loaded)
                R = obj.Spike;
                return
            end
            L = obj.Loaded;
            S = L.online_spike;   % source-agnostic spikeContainer (TimeSec/Channel/Unit/Waveform)
            if L.LoadOnlineSpikeData
                wfForMean = [];
                if L.LoadOnlineSpikeWaveform && ~isempty(S.Waveform)
                    wfForMean = S.Waveform;   % [nSamp x nSpikes] raw, aligned to S.TimeSec/Channel/Unit
                end
                obj.Spike = BlackrockLoader.segmentSpikes(obj.Trials, S.TimeSec, ...
                    S.Channel, S.Unit, ...
                    obj.Segment_PreBuffer, obj.Segment_PostBuffer, obj.Segment_BinWidth, ...
                    obj.Spike_ISIViolationMs, wfForMean, S.WaveformScale, ...
                    S.TimeTick, obj.TrialStartTicks, obj.TrialEndTicks, ...
                    BlackrockLoader.sharedTimeRes(L.EventTimeRes, S.TimeRes));
            end
            if L.LoadOnlineSpikeWaveform && ~isempty(S.Waveform)
                obj.SpikeWaveformData = BlackrockLoader.segmentSpikeWaveforms(obj.Trials, ...
                    S.TimeSec, S.Channel, S.Unit, S.Waveform, ...
                    obj.Segment_PreBuffer, obj.Segment_PostBuffer, S.WaveformScale, ...
                    S.TimeTick, obj.TrialStartTicks, S.TimeRes);
            end
            % The raw waveform matrix is the largest array in the session and is
            % of no further use once both spike products exist.
            if obj.FreeRawAfterParse && ~isempty(obj.Loaded.online_spike)
                obj.Loaded.online_spike.Waveform = [];
            end
            R = obj.Spike;
        end

        function E = prepareExport(obj)
        % Build the export-ready products from obj.Trials / obj.Experiment and
        % store them in obj.Export (.trials_table and .expmeta_lines). This is
        % pure preparation; export() does the file writing.
            trials     = obj.Trials;
            experiment = obj.Experiment;

            % --- experiment meta: one text block per session ---
            % "Session N:" header, then "field: value" (mat2str for numerics),
            % then a blank line.
            expmeta_lines = {};
            for s = 1:numel(experiment)
                expmeta_lines{end+1,1} = sprintf('Session %d:', s); %#ok<AGROW>
                fields = fieldnames(experiment(s));
                for i = 1:numel(fields)
                    val = experiment(s).(fields{i});
                    if isnumeric(val)
                        expmeta_lines{end+1,1} = sprintf('%s: %s', fields{i}, mat2str(val)); %#ok<AGROW>
                    else
                        expmeta_lines{end+1,1} = sprintf('%s: %s', fields{i}, string(val)); %#ok<AGROW>
                    end
                end
                expmeta_lines{end+1,1} = ''; %#ok<AGROW>
            end

            % --- trials table: drop bookkeeping, add index, split _x/_y ---
            trials_flat  = rmfield(trials, {'undefined', 'duplicates'});
            trials_table = struct2table(trials_flat);

            % Explicit 0-based sequential row index (pandas-friendly:
            % read_csv(index_col='index')). Kept separate from Trial_number,
            % which holds the real (resetting) trial number.
            trials_table = addvars(trials_table, (0:height(trials_table)-1)', ...
                'Before', 1, 'NewVariableNames', 'index');

            % Split any 2-column numeric fields (positions) into _x/_y columns.
            for col = trials_table.Properties.VariableNames
                c = col{1};
                if isnumeric(trials_table.(c)) && size(trials_table.(c), 2) == 2
                    trials_table.([c '_x']) = trials_table.(c)(:,1);
                    trials_table.([c '_y']) = trials_table.(c)(:,2);
                    trials_table.(c) = [];
                end
            end

            % Text fields start life as NaN in the trial template, so any column
            % that some trials fill with text is a cell of char and numeric NaN.
            % writetable prints those NaN as the literal text "NaN", which parses
            % back as a number: readtable then types the whole column double and
            % silently drops every text value (Trial_type, Choosen_choice,
            % Target_1_side, ...). Convert to string with missing so the CSV
            % carries empty fields, which survive the round trip.
            for col = trials_table.Properties.VariableNames
                c = col{1};
                v = trials_table.(c);
                if ~iscell(v);  continue;  end
                is_text = cellfun(@(x) ischar(x) || isstring(x), v);
                if ~any(is_text);  continue;  end
                s = strings(numel(v), 1);
                s(is_text)  = string(v(is_text));
                s(~is_text) = missing;              % the NaN placeholders
                trials_table.(c) = s;
            end

            obj.Export = struct('trials_table', trials_table, ...
                                'expmeta_lines', {expmeta_lines});
            E = obj.Export;
        end

        function export(obj, OutputPath, BaseName)
        % Write the prepared products to OutputPath, filenames stemmed on
        % BaseName (e.g. 'Blackrock_2026-06-24'):
        %   <BaseName>_expmeta_matlab.txt          (always)
        %   <BaseName>_trials_matlab.csv           (always)
        %   <BaseName>_eye_matlab.mat              (if the eye stream was segmented)
        %   <BaseName>_lfp_matlab.mat              (if LFP was segmented)
        %   <BaseName>_photodiode_matlab.mat       (if photodiode was segmented)
        %   <BaseName>_spikes_matlab.mat           (if spikes were segmented)
        %   <BaseName>_spikes_waveform_matlab.mat  (if waveforms were segmented)
        %
        % All .mat products use -v7.3: every one of them is a dense per-trial
        % array that can exceed the 2 GB per-variable cap of the default format.
        % Compression is on unless CompressExport is cleared: these arrays are
        % mostly NaN padding and compress ~6x, which outweighs the
        % single-threaded gzip time on anything but a quick turnaround.
            if ~exist(OutputPath, 'dir')
                mkdir(OutputPath);
            end
            src = obj.Loaded.comments_source;
            if obj.CompressExport
                save_opts = {'-v7.3'};
            else
                save_opts = {'-v7.3', '-nocompression'};
            end

            % Experiment meta (.txt)
            fname_exp = [BaseName '_expmeta_matlab.txt'];
            fid = fopen(fullfile(OutputPath, fname_exp), 'w');
            fprintf(fid, '%s\n', obj.Export.expmeta_lines{:});
            fclose(fid);
            fprintf('File:%s Experiment meta has been parsed into %s\n', src, fname_exp);

            % Trials (.csv)
            fname_trials = [BaseName '_trials_matlab.csv'];
            writetable(obj.Export.trials_table, fullfile(OutputPath, fname_trials));
            fprintf('File:%s Trials Data has been parsed into %s\n', src, fname_trials);

            % Eye (.mat) - only when segmented
            if ~isempty(obj.Eye)
                eye = obj.Eye; %#ok<NASGU>
                fname_eye = [BaseName '_eye_matlab.mat'];
                save(fullfile(OutputPath, fname_eye), 'eye', save_opts{:});
                fprintf('File:%s Eye segmented (%d trials) into %s\n', ...
                    src, size(obj.Eye.data, 2), fname_eye);
            end

            % LFP (.mat) - only when segmented
            if ~isempty(obj.LFP)
                lfp = obj.LFP; %#ok<NASGU>
                fname_lfp = [BaseName '_lfp_matlab.mat'];
                save(fullfile(OutputPath, fname_lfp), 'lfp', save_opts{:});
                fprintf('File:%s LFP segmented (%d trials) into %s\n', ...
                    src, size(obj.LFP.data, 2), fname_lfp);
            end

            % Photodiode (.mat) - only when segmented
            if ~isempty(obj.Photodiode)
                photodiode = obj.Photodiode; %#ok<NASGU>
                fname_pd = [BaseName '_photodiode_matlab.mat'];
                save(fullfile(OutputPath, fname_pd), 'photodiode', save_opts{:});
                fprintf('File:%s Photodiode segmented (%d trials) into %s\n', ...
                    src, size(obj.Photodiode.data, 2), fname_pd);
            end

            % Spikes (.mat) - only when segmented
            if ~isempty(obj.Spike)
                online_spike = obj.Spike; %#ok<NASGU>
                fname_spikes = [BaseName '_spikes_matlab.mat'];
                save(fullfile(OutputPath, fname_spikes), 'online_spike', save_opts{:});
                fprintf('File:%s Spikes rasterized (%d units x %d trials) into %s\n', ...
                    src, size(obj.Spike.data, 1), size(obj.Spike.data, 2), fname_spikes);
            end

            % Spike waveforms (.mat) - only when segmented
            if ~isempty(obj.SpikeWaveformData)
                online_spike_waveform = obj.SpikeWaveformData; %#ok<NASGU>
                fname_wf = [BaseName '_spikes_waveform_matlab.mat'];
                save(fullfile(OutputPath, fname_wf), 'online_spike_waveform', save_opts{:});
                fprintf('File:%s Spike waveforms (%d samples, up to %d spk/unit-trial) into %s\n', ...
                    src, obj.SpikeWaveformData.waveform_nsamp, ...
                    obj.SpikeWaveformData.info.maxSpikes, fname_wf);
            end
        end

        function resetSession(obj)
        % Clear all per-folder session state so one loader can be reused across
        % a batch without leaking data from a previous folder.
            obj.Loaded            = [];
            obj.Trials            = [];
            obj.Experiment        = [];
            obj.TrialStartTicks   = [];
            obj.TrialEndTicks     = [];
            obj.Eye            = [];
            obj.LFP               = [];
            obj.Photodiode        = [];
            obj.Spike             = [];
            obj.SpikeWaveformData = [];
            obj.Export            = [];
        end
    end

    methods (Static)
        function folders = resolveFolders(Folder, DataTypePath)
        % Normalize Folder into a cellstr list of YYYY-MM-DD folder names.
        % Empty Folder -> auto-discover every date folder under DataTypePath.
            datePat = '^\d{4}-\d{2}-\d{2}$';
            if isempty(Folder)
                d = dir(DataTypePath);
                names = {d([d.isdir]).name};
                keep = ~cellfun('isempty', regexp(names, datePat, 'once'));
                folders = sort(names(keep));
            else
                folders = cellstr(Folder);   % char, string array, or cellstr -> cellstr
            end
            if isempty(folders)
                error('No date folders to process under: %s', DataTypePath);
            end
        end

        function name = pickByPrefix(d, prefix)
        % Largest file in dir-struct d whose name starts with prefix (case-insensitive).
        % Returns '' when nothing matches.
            name = '';
            if isempty(d); return; end
            keep = ~cellfun('isempty', regexpi({d.name}, ['^' prefix], 'once'));
            d = d(keep);
            if isempty(d); return; end
            [~, i] = max([d.bytes]);
            name = d(i).name;
        end

        function d = filterByPrefix(d, prefix)
        % Subset of dir-struct d whose names start with prefix (case-insensitive).
            if isempty(d); return; end
            keep = ~cellfun('isempty', regexpi({d.name}, ['^' prefix], 'once'));
            d = d(keep);
        end

        function tf = hasComments(s)
        % True when an openNEV struct carries comment text and comment timing.
            tf = ~isempty(s) && isfield(s, 'Data') && isfield(s.Data, 'Comments') ...
                && isfield(s.Data.Comments, 'Text') && ~isempty(s.Data.Comments.Text) ...
                && isfield(s.Data.Comments, 'TimeStampSec') && ~isempty(s.Data.Comments.TimeStampSec);
        end

        function T = commentsWithTime(Events, EventTime)
        % Pair raw comment strings with their timestamps for inspection/debugging.
        % Events    : N-by-* char matrix (Data.Comments.Text, as returned in S.Events)
        % EventTime : N-by-1 timestamps in seconds (S.EventTime)
        % Returns an N-row table [TimeStampSec, Comment] in recording order, so the
        % raw, UNPARSED comments can be eyeballed (e.g. when a comment-string format
        % change is sending events into trials.undefined).
            T = table(EventTime(:), string(Events), ...
                'VariableNames', {'TimeStampSec', 'Comment'});
        end

        function tf = hasSpikes(s)
        % True when an openNEV struct carries spike timestamps.
            tf = ~isempty(s) && isfield(s, 'Data') && isfield(s.Data, 'Spikes') ...
                && isfield(s.Data.Spikes, 'TimeStamp') && ~isempty(s.Data.Spikes.TimeStamp);
        end

        function s = spikeContainer()
        % Canonical, source-agnostic raw-spike container. Every spike source
        % (online now, offline later) fills this same shape, then feeds it to
        % parseSpikes/segmentSpikes. All per-spike arrays are aligned 1:1 (same length / column
        % count), so they can be filtered or segmented together.
            s = struct( ...
                'TimeSec',       [], ...  % spike times (s, recording clock); 1 x nSpikes
                'TimeTick',      uint64([]), ... % the same times as raw integer clock
                                    ...          % ticks; exact, unlike TimeSec (see
                                    ...          % loadComments). 1 x nSpikes, or []
                'TimeRes',       [], ...  % ticks per second for TimeTick
                'Channel',       [], ...  % electrode per spike; 1 x nSpikes
                'Unit',          [], ...  % unit id per spike;   1 x nSpikes
                'Waveform',      [], ...  % [nSamp x nSpikes] raw int16, or [] when none
                'WaveformScale', [], ...  % 1 x nSpikes uV per digit for Waveform, or []
                                    ...   % when Waveform is already in WaveformUnit
                'WaveformUnit',  '', ...  % e.g. 'microVolts' (unit AFTER WaveformScale)
                'source',        '');     % provenance: 'online' | 'offline'
        end

        function [spkIdx, trialOf] = trialSpikeIndex(sortedTimes, t_start, t_end)
        % Map every (trial, in-window spike) pair to a flat pair of index
        % vectors: spkIdx into sortedTimes, trialOf into the trial list. The
        % window is [t_start, t_end) -- the same bounds the per-trial masks
        % (spikeTimes >= t0 & spikeTimes < t1) used.
        %
        % sortedTimes must be ascending, so each trial's spikes are a CONTIGUOUS
        % range of it. Finding the two bounds per trial replaces scanning all
        % spikes once per trial, which is what made segmentation cost
        % nTrials x nSpikes. Trials with a NaN window contribute nothing.
        %
        % Ranges may overlap between trials -- with pre/post buffers wider than
        % the inter-trial interval a spike legitimately belongs to two trials --
        % so this deliberately does not assign each spike to a single trial.
            nS = numel(sortedTimes);
            nT = numel(t_start);
            ok = ~isnan(t_start(:)) & ~isnan(t_end(:));

            spkIdx = zeros(0, 1);
            trialOf = zeros(0, 1);
            if nS == 0 || ~any(ok)
                return
            end

            % #{spikes strictly before q} for every window bound, in ONE pass
            % over the spikes. histcounts needs increasing edges, so ask about
            % the sorted unique bounds and map the answers back. (Spike times
            % themselves may repeat -- simultaneous spikes on different
            % electrodes -- which is why they are the data here, not the edges.)
            q = [t_start(ok); t_end(ok)];
            [qs, ~, back] = unique(q(:));
            nBefore = cumsum(histcounts(sortedTimes, [-inf; qs(:); inf]));
            nBefore = nBefore(1:numel(qs));     % nBefore(j) = #{spikes < qs(j)}
            bound   = nBefore(back);
            m       = sum(ok);

            lo = nan(nT, 1);  hi = nan(nT, 1);
            lo(ok) = bound(1:m)     + 1;   % first index with time >= t_start
            hi(ok) = bound(m+1:end);       % last  index with time <  t_end

            n = hi - lo + 1;
            n(isnan(n) | n < 0) = 0;
            total = sum(n);
            if total == 0
                return
            end

            % Concatenate lo(k):hi(k) for every kept trial without a loop: step
            % by 1 everywhere, except at each block's first element, where the
            % step jumps from the previous block's end to this block's lo.
            keep = find(n > 0);
            nk   = n(keep);
            lok  = lo(keep);
            trialOf = repelem(keep, nk);

            step       = ones(total, 1);
            blockStart = cumsum([1; nk(1:end-1)]);
            prevEnd    = [0; lok(1:end-1) + nk(1:end-1) - 1];
            step(blockStart) = lok - prevEnd;
            spkIdx     = cumsum(step);
        end

        function restoreFcn = muteNpmkUvPrompt()
        % Turn off NPMK's "data are in units of 1/4 uV" warning, and with it the
        % interactive "warn every time? (Y/n)" prompt openNSx fires when data is
        % read without 'uv' (openNSx.m:1353-1367). That prompt blocks until a
        % key is pressed, which would hang any unattended batch run.
        %
        % Returns a function handle that puts the user's setting back; call it
        % (or let an onCleanup do so) as soon as the openNSx call returns, so the
        % preference is only suppressed for our own reads.
            restoreFcn = @() [];   % no settingsManager on the path -> nothing to do
            if exist('settingsManager', 'file') ~= 2
                return
            end
            try
                s = settingsManager();
                if ~isfield(s, 'ShowuVWarning') || ~s.ShowuVWarning
                    return   % already off; leave it alone
                end
                previous = s.ShowuVWarning;
                s.ShowuVWarning = 0;
                settingsManager(s);
                restoreFcn = @() BlackrockLoader.restoreNpmkUvWarning(previous);
            catch
                % settings are a convenience, never a reason to fail a load
            end
        end

        function restoreNpmkUvWarning(previous)
            try
                s = settingsManager();
                s.ShowuVWarning = previous;
                settingsManager(s);
            catch
            end
        end

        function C = commentFields(nev, sourceName)
        % Pull the comment product out of an already-parsed NEV.
        %
        % EventTime is DERIVED here from EventTick rather than copied from
        % openNEV's precomputed Data.Comments.TimeStampSec. The two are
        % identical bit-for-bit (openNEV computes exactly this quotient), so
        % this changes no value -- it exists so the tick -> second relationship
        % is stated once, in our code, where a reader looks for it. Ticks are
        % the raw datum; seconds are a derived view of them, and deriving them
        % in one place is what stops the two from ever drifting apart.
        %
        % Both branches of loadComments come through here for the same reason:
        % duplicating these five assignments was itself a way for the primary
        % and legacy paths to diverge.
            C.Events          = nev.Data.Comments.Text;
            C.EventTick       = nev.Data.Comments.TimeStamp;      % uint64, exact
            C.TimeRes         = double(nev.MetaTags.TimeRes);     % ticks per second
            C.EventTime       = double(C.EventTick) / C.TimeRes;  % seconds, derived
            C.comments_source = sourceName;
        end

        function nev = openNevCached(nevPath, cache)
        % openNEV, but reusing an already-parsed struct when the caller supplies
        % a cache (a containers.Map keyed by full path). Parsing a .nev means
        % reading every packet in the file, so a multi-GB HUB file that carries
        % both comments and spikes would otherwise be read twice per folder.
        % With cache omitted this is a plain openNEV call.
        %
        % Test the class, not isempty: a containers.Map with nothing in it is
        % isempty()==true, so an isempty guard would skip the store on the very
        % first call and the cache could never fill.
            usable = isa(cache, 'containers.Map');
            if usable && isKey(cache, nevPath)
                nev = cache(nevPath);
                return
            end
            nev = openNEV(nevPath, 'report', 'nosave');
            if usable
                cache(nevPath) = nev; %#ok<NASGU> handle object, mutated in place
            end
        end

        function B = subsetChannels(A, rows)
        % Take a channel subset of a segmentContinuous product. Only .data is
        % indexed; timeseq/info describe the trials and the clock, which the
        % subset shares, so they carry through unchanged.
            B = A;
            B.data = A.data(rows, :, :);
        end

        function rows = clampChannels(rows, nChan, name)
        % Drop requested channel rows that the stream does not actually have, so
        % a file with fewer channels than the configured layout degrades to the
        % rows that exist instead of erroring mid-pipeline.
            keep = rows <= nChan;
            if ~all(keep)
                warning(['%s requests channel(s) %s but the stream has only %d; ' ...
                    'using %s.'], name, mat2str(rows(~keep)), nChan, mat2str(rows(keep)));
                rows = rows(keep);
            end
        end

        function res = sharedTimeRes(a, b)
        % The common tick rate of two files, or [] when they do not share one.
        %
        % Trial Start/End ticks come from the comment .nev; the samples they are
        % matched against come from an .nsx, and the spikes from another .nev.
        % Doing the window arithmetic in integer ticks is only valid when those
        % clocks tick at the same rate (they do on PTP rigs -- 1e9 everywhere).
        % Returning [] makes the caller fall back to the double path rather than
        % silently mix two clocks.
            res = [];
            if isempty(a) || isempty(b) || a <= 0 || b <= 0 || double(a) ~= double(b)
                return
            end
            res = double(a);
        end

        function [ok, perUnit, preTicks, postTicks] = exactTickGrid(timeRes, rate, preMs, postMs)
        % Ticks per sample/bin and per buffer, and whether they are all integral.
        %
        % The exact-integer window arithmetic in segmentContinuous/segmentSpikes
        % only works when the clock divides evenly into samples (or bins) and
        % into each ms buffer -- true for the usual 1e9 tick / 1 kHz / 500 ms
        % combination (1e6 ticks per sample, 5e8 per buffer), not for an
        % arbitrary rate. ok = false tells the caller to use the double path.
            ok = false; perUnit = 0; preTicks = 0; postTicks = 0;
            if isempty(timeRes) || isempty(rate) || timeRes <= 0 || rate <= 0
                return
            end
            perUnit   = double(timeRes) / double(rate);
            preTicks  = double(preMs)  * double(timeRes) / 1000;
            postTicks = double(postMs) * double(timeRes) / 1000;
            v = [perUnit, preTicks, postTicks];
            ok = all(v == floor(v)) && all(isfinite(v));
        end

        function A = segmentContinuous(trials, nsxdata, nsx_abs_time, nsx_samplingrate, preMs, postMs, uvScale, startTicks, endTicks, refTick, timeRes)
        % Cut a continuous stream into one slice per trial.
        % For each trial the window is [Start - preMs, End + postMs] (ms buffers),
        % matched against nsx_abs_time (seconds, same NSP clock as the event
        % timestamps). Slices are left-aligned (each starts at its own window
        % start) and NaN-padded to the longest trial, so the result is one
        % chan x nTrials x maxSamples array that lines up 1:1 with trials.
        % A trial whose Start/End is NaN (or that has no samples in range) gets
        % an all-NaN slice so the 3rd dimension stays index-aligned with trials.
        %
        % nsxdata may be raw int16 (as loadContinuous now returns it) together with
        % uvScale, a per-channel uV-per-digit column vector; each slice is then
        % scaled on the way in. Omit/empty uvScale when nsxdata is already in uV.
        % Output .data is single -- half the memory of double, and well beyond
        % the ~5 significant figures a 16-bit ADC can actually resolve.
        %
        % The sample window is computed arithmetically rather than searched:
        % nsx_abs_time is uniform by construction (see loadContinuous), so the
        % window bounds follow from the first sample's time and the sampling
        % rate. Only nsx_abs_time(1) is read, which keeps this O(nTrials)
        % instead of scanning the whole time vector once per trial.
            if nargin < 5 || isempty(preMs);  preMs  = 500; end   % default buffer (ms)
            if nargin < 6 || isempty(postMs); postMs = 500; end
            if nargin < 7; uvScale = []; end                      % [] -> data already in uV
            if nargin < 8;  startTicks = uint64([]); end
            if nargin < 9;  endTicks   = uint64([]); end
            if nargin < 10; refTick    = []; end
            if nargin < 11; timeRes    = []; end

            pre  = preMs  / 1000;   % seconds
            post = postMs / 1000;

            nChan   = size(nsxdata, 1);
            nSample = size(nsxdata, 2);
            nTrials = numel(trials);

            if ~isempty(uvScale)
                uvScale = double(uvScale(:));   % nChan x 1, broadcast down the columns
            end

            % --- first pass: each trial's sample window, in closed form ---
            % nsx_abs_time(k) = tRef + (k-1)/fs, so the first sample at or after
            % t0 is ceil((t0-tRef)*fs)+1 and the last at or before t1 is
            % floor((t1-tRef)*fs)+1 -- the same inclusive window the old
            % find(>= t0 & <= t1) produced.
            %
            % These are absolute epoch timestamps (~1.5e9 s), where a double
            % resolves only ~2.4e-7 s. At 1 kHz that is ~2.4e-4 of a sample, so
            % the stored grid is not perfectly even -- successive steps vary in
            % the last bits -- and the arithmetic above can land one sample off
            % at a window edge. The candidate is therefore snapped against the
            % actual sample times, which is still O(1) per trial: only the
            % candidate and its neighbour are read, never the whole vector.
            tRef   = nsx_abs_time(1);
            starts = [trials.Start]';
            ends   = [trials.End]';
            ok     = ~isnan(starts) & ~isnan(ends);
            t0     = starts - pre;
            t1     = ends   + post;

            % Exact path: when the raw ticks are available and the clock divides
            % evenly into samples and buffers, the whole window is integer
            % arithmetic. The sample grid is uniform by construction (index k
            % sits at refTick + k*ticksPerSample exactly), so solving for the
            % first index at or after t0 and the last at or before t1 is just
            % integer division -- no rounding, and the snap below is unnecessary.
            % This is what stops a trial whose edge lands within ~238 ns of a
            % sample boundary from going either way.
            [grid_ok, tps, preTicks, postTicks] = BlackrockLoader.exactTickGrid( ...
                timeRes, nsx_samplingrate, preMs, postMs);
            useTicks = grid_ok && ~isempty(refTick) && ...
                       numel(startTicks) == nTrials && numel(endTicks) == nTrials;

            if useTicks
                st = int64(startTicks(:));
                en = int64(endTicks(:));
                have = ok & st ~= 0 & en ~= 0;
                i0 = zeros(nTrials, 1);
                i1 = -ones(nTrials, 1);
                num0 = (st(have) - int64(preTicks))  - int64(refTick);
                num1 = (en(have) + int64(postTicks)) - int64(refTick);
                % ceil / floor division on signed integers, then back to 1-based
                i0(have) = double(-idivide(-num0, int64(tps), 'floor')) + 1;
                i1(have) = double( idivide( num1, int64(tps), 'floor')) + 1;
                ok = have;
            else
            i0 = ceil ((t0 - tRef) * nsx_samplingrate) + 1;   % may fall outside 1..nSample
            i1 = floor((t1 - tRef) * nsx_samplingrate) + 1;

            % i0 := smallest index whose time is >= t0
            sel = ok & i0 >= 1 & i0 <= nSample;
            adj = false(nTrials, 1);
            adj(sel) = reshape(nsx_abs_time(i0(sel)), [], 1) < t0(sel);
            i0(adj) = i0(adj) + 1;
            sel = ok & i0 >= 2 & i0 <= nSample + 1;
            adj = false(nTrials, 1);
            adj(sel) = reshape(nsx_abs_time(i0(sel) - 1), [], 1) >= t0(sel);
            i0(adj) = i0(adj) - 1;

            % i1 := largest index whose time is <= t1
            sel = ok & i1 >= 1 & i1 <= nSample;
            adj = false(nTrials, 1);
            adj(sel) = reshape(nsx_abs_time(i1(sel)), [], 1) > t1(sel);
            i1(adj) = i1(adj) - 1;
            sel = ok & i1 >= 0 & i1 <= nSample - 1;
            adj = false(nTrials, 1);
            adj(sel) = reshape(nsx_abs_time(i1(sel) + 1), [], 1) <= t1(sel);
            i1(adj) = i1(adj) + 1;
            end

            % Clamp on one side each, so a window lying entirely outside the
            % recording ends up with i1 < i0 and is dropped rather than
            % collapsing onto a bogus single sample.
            i0 = max(i0, 1);
            i1 = min(i1, nSample);

            n        = i1 - i0 + 1;
            n(~ok)   = 0;              % missing marker -> all-NaN slice
            n(n < 0) = 0;              % window entirely outside the recording
            rawstarttime = starts;
            rawstarttime(n == 0) = NaN;   % abs time of the Start marker (s)

            % --- second pass: stack into NaN-padded 3-D array (left-aligned) ---
            % Allocated directly as chan x nTrials x maxSamples; the old version
            % built chan x maxSamples x nTrials and permuted, which duplicated
            % the whole array at peak memory.
            maxSamples = max([n; 0]);
            data = nan(nChan, nTrials, maxSamples, 'single');
            for i = find(n > 0)'
                slice = single(nsxdata(:, i0(i):i1(i)));
                if ~isempty(uvScale)
                    slice = slice .* single(uvScale);
                end
                data(:, i, 1:n(i)) = reshape(slice, nChan, 1, n(i));
            end

            % reltime: 0 at the Start marker, negative through the pre-buffer
            reltime = ((0:maxSamples-1) / nsx_samplingrate) - pre;

            A = struct();
            A.data    = data;       % chan x nTrials x maxSamples, NaN-padded, single
            A.timeseq.alignedrawtime = rawstarttime;  % nTrials x 1, abs time of the Start marker (s)
            A.timeseq.aligned_marker = 'Start';        % event that relative_time=0 is aligned to
            A.timeseq.relative_time  = reltime;        % 1 x maxSamples, seconds from the aligned marker
            A.info.samplingrate = nsx_samplingrate;
            A.info.Session      = [trials.Session]';        % nTrials x 1
            A.info.Trial_number = [trials.Trial_number]';   % nTrials x 1
        end

        function R = segmentSpikes(trials, spikeTimes, spikeElectrode, spikeUnit, preMs, postMs, binMs, violMs, spikeWaveform, waveformScale, spikeTicks, startTicks, endTicks, timeRes)
        % Rasterize online spikes into one binary slice per trial.
        % For each trial the window is [Start - preMs, End + postMs] (ms buffers),
        % matched against spikeTimes (seconds, NSP/HUB clock). Time is binned at
        % binMs (default 1 ms); a bin is 1 if any spike of that row falls in it,
        % 0 otherwise. Slices are left-aligned (bin 1 at the window start) and
        % NaN-padded to the longest trial, giving one NtotalUnit x nTrials x maxBins
        % array that lines up 1:1 with trials (same layout as segmentContinuous).
        % Rows are one per (electrode, unit) pair, so NtotalUnit is the total
        % isolated units summed across channels (a channel with 2 units -> 2 rows);
        % info.Channel_Number / info.Unit_No record the IDs per row.
        % info.ViolationRate carries each unit's overall ISI-violation rate
        % (fraction of ISIs < violMs, default 1 ms) over its full continuous spike
        % train -- a timing-only QC metric that needs no waveform product.
        % info.MeanWaveform carries each unit's average waveform (uV, one row per
        % unit x nSamp) over its FULL set of spikes when spikeWaveform is supplied
        % ([nSamp x nSpikes], columns aligned to spikeTimes); [] otherwise.
        % waveformScale is the optional per-spike uV-per-digit factor that goes
        % with a raw int16 spikeWaveform; omit/empty when it is already in uV.
        % A trial whose Start/End is NaN gets an all-NaN slice so the trial
        % dimension stays index-aligned with trials.
        % (Per-spike waveforms are a separate product: see segmentSpikeWaveforms.)
            if nargin < 5 || isempty(preMs);  preMs  = 500; end   % default buffer (ms)
            if nargin < 6 || isempty(postMs); postMs = 500; end
            if nargin < 7 || isempty(binMs);  binMs  = 1;   end   % bin width (ms)
            if nargin < 8 || isempty(violMs); violMs = 1;   end   % ISI-violation window (ms)
            if nargin < 9  || isempty(spikeWaveform); spikeWaveform = []; end  % [nSamp x nSpikes], or []
            if nargin < 10; waveformScale = []; end                            % [] -> already uV
            if nargin < 11; spikeTicks = uint64([]); end
            if nargin < 12; startTicks = uint64([]); end
            if nargin < 13; endTicks   = uint64([]); end
            if nargin < 14; timeRes    = [];         end

            pre    = preMs  / 1000;   % seconds
            post   = postMs / 1000;
            binSec = binMs  / 1000;

            spikeTimes     = double(spikeTimes(:));
            spikeElectrode = double(spikeElectrode(:));
            spikeUnit      = double(spikeUnit(:));

            % --- channel list: one row per (electrode, unit), sorted ---
            chanKeys  = unique([spikeElectrode, spikeUnit], 'rows');  % sorted by col1 then col2
            electrode = chanKeys(:, 1);
            unit      = chanKeys(:, 2);
            nChan     = size(chanKeys, 1);
            % map each spike to its channel row
            [~, spikeRow] = ismember([spikeElectrode, spikeUnit], chanKeys, 'rows');

            % --- overall ISI-violation rate per unit (row-aligned to chanKeys) ---
            % Fraction of ISIs < violMs over each unit's FULL continuous spike train
            % (not per-trial): a pure timing metric, independent of the raster and
            % of the waveform product. NaN for a unit with fewer than 2 spikes.
            % Sort by (unit, time) once, so every unit's train is a contiguous
            % ascending run. The old form re-scanned all spikes once per unit.
            violSec  = violMs / 1000;
            violRate = nan(nChan, 1);
            rowSorted = sortrows([spikeRow, spikeTimes], [1 2]);
            unitOf = rowSorted(:, 1);
            isi    = diff(rowSorted(:, 2));
            sameUnit = diff(unitOf) == 0;              % drop the gaps between units
            if any(sameUnit)
                violRate = accumarray(unitOf(find(sameUnit)), ...
                    isi(sameUnit) < violSec, [nChan 1], @mean, NaN);
            end

            % --- overall mean waveform per unit (uV, row-aligned to chanKeys) ---
            % Mean over the unit's FULL set of spikes (all trials), or [] when no
            % waveform product was loaded. NaN row for a unit with no waveform columns.
            % Sorting the spikes by unit turns "this unit's columns" into one
            % contiguous block of the ordering, so each unit gathers only its own
            % columns and the whole loop touches every column exactly once. The
            % old form scanned the entire matrix once per unit; converting the
            % whole matrix up front instead would mean a full double copy of the
            % largest array in the session.
            if ~isempty(spikeWaveform)
                nSamp  = size(spikeWaveform, 1);
                counts = accumarray(spikeRow, 1, [nChan 1]);
                [~, byUnit] = sort(spikeRow);
                stop   = cumsum(counts);
                start  = stop - counts + 1;
                meanWf = nan(nChan, nSamp);
                for r = find(counts > 0)'
                    cols_r = byUnit(start(r):stop(r));
                    block  = single(spikeWaveform(:, cols_r));
                    if ~isempty(waveformScale)
                        block = block .* single(reshape(waveformScale(cols_r), 1, []));
                    end
                    meanWf(r, :) = mean(double(block), 2, 'omitnan').';
                end
            else
                meanWf = [];
            end

            nTrials = numel(trials);

            % --- first pass: each trial's bin count and window ---
            starts = [trials.Start]';
            ends   = [trials.End]';
            ok     = ~isnan(starts) & ~isnan(ends);   % missing marker -> all-NaN slice

            t_start = nan(nTrials, 1);   t_start(ok) = starts(ok) - pre;
            t_end   = nan(nTrials, 1);   t_end(ok)   = ends(ok)   + post;
            nBins   = zeros(nTrials, 1);
            nBins(ok) = max(round((t_end(ok) - t_start(ok)) / binSec), 0);
            rawstarttime = nan(nTrials, 1);
            rawstarttime(ok) = starts(ok);   % abs time of the Start marker (s)

            % --- second pass: fill NaN-padded binary raster (left-aligned) ---
            % Allocated directly as NtotalUnit x nTrials x maxBins; building it
            % transposed and permuting at the end duplicated the whole array.
            maxBins = max([nBins; 0]);
            raster  = nan(nChan, nTrials, maxBins, 'single');
            for i = find(nBins > 0)'
                raster(:, i, 1:nBins(i)) = 0;   % within-window bins start at 0
            end

            % Every (trial, in-window spike) pair at once, then a single indexed
            % write -- rather than rescanning all spikes, and read-modify-writing
            % a slice, once per trial.
            % Membership and bin index in exact integer ticks when they are
            % available: in seconds these are absolute epoch values (~1.5e9 s)
            % where a double resolves only ~238 ns, so a spike within that band
            % of a bin edge would land on either side depending on the last bit.
            [grid_ok, binTicks, preTicks, postTicks] = BlackrockLoader.exactTickGrid( ...
                timeRes, 1/binSec, preMs, postMs);
            useTicks = grid_ok && numel(spikeTicks) == numel(spikeTimes) && ...
                       numel(startTicks) == nTrials && numel(endTicks) == nTrials;

            if useTicks
                st = int64(startTicks(:));  en = int64(endTicks(:));
                haveT = ok & st ~= 0 & en ~= 0;
                lo = zeros(nTrials, 1, 'int64');  hi = zeros(nTrials, 1, 'int64');
                lo(haveT) = st(haveT) - int64(preTicks);
                hi(haveT) = en(haveT) + int64(postTicks);
                [sortedTicks, sortIdx] = sort(int64(spikeTicks(:)));

                % Rebase before handing the bounds to trialSpikeIndex, which
                % bins with histcounts and therefore works in double: an
                % absolute PTP tick (~1.5e18) is far past 2^53, where doubles
                % stop representing every integer, but a session-relative tick
                % (< ~2e13 for a 5.5 h recording) sits comfortably inside it and
                % so stays exact. NaN marks trials with no window, which is what
                % trialSpikeIndex already expects.
                base  = sortedTicks(1);
                relT  = double(sortedTicks - base);
                relLo = nan(nTrials, 1);  relHi = nan(nTrials, 1);
                relLo(haveT) = double(lo(haveT) - base);
                relHi(haveT) = double(hi(haveT) - base);
                [spkIdx, trialOf] = BlackrockLoader.trialSpikeIndex(relT, relLo, relHi);
                if ~isempty(spkIdx)
                    % The bin index itself stays in int64 -- exact, no rebasing.
                    bins = double(idivide(sortedTicks(spkIdx) - lo(trialOf), ...
                                          int64(binTicks), 'floor')) + 1;
                end
            else
                [sortedTimes, sortIdx] = sort(spikeTimes);
                [spkIdx, trialOf] = BlackrockLoader.trialSpikeIndex(sortedTimes, t_start, t_end);
                if ~isempty(spkIdx)
                    bins = floor((sortedTimes(spkIdx) - t_start(trialOf)) / binSec) + 1;
                end
            end
            if ~isempty(spkIdx)
                bins = min(bins, nBins(trialOf));        % guard the right edge
                bins = max(bins, 1);
                rows = spikeRow(sortIdx(spkIdx));
                raster(sub2ind([nChan, nTrials, maxBins], rows, trialOf, bins)) = 1;
            end

            % reltime: 0 at the Start marker, negative through the pre-buffer
            reltime = ((0:maxBins-1) * binSec) - pre;

            R = struct();
            R.data    = raster;     % NtotalUnit x nTrials x maxBins, 0/1, NaN-padded
            R.timeseq.alignedrawtime = rawstarttime;  % nTrials x 1, abs time of the Start marker (s)
            R.timeseq.aligned_marker = 'Start';        % event that relative_time=0 is aligned to
            R.timeseq.relative_time  = reltime;        % 1 x maxBins, seconds from the aligned marker
            R.info.samplingrate   = 1 / binSec;            % bin rate (Hz), 1000 for 1 ms bins
            R.info.Session        = [trials.Session]';     % nTrials x 1
            R.info.Trial_number   = [trials.Trial_number]';% nTrials x 1
            R.info.Channel_Number = electrode;             % NtotalUnit x 1, electrode per row
            R.info.Unit_No        = unit;                  % NtotalUnit x 1, unit per row
            R.info.ViolationRate  = violRate;              % NtotalUnit x 1, frac ISIs < violMs (full train)
            R.info.MeanWaveform     = meanWf;              % NtotalUnit x nSamp (uV), or []
            R.info.MeanWaveformUnit = 'microVolts';
        end

        function W = segmentSpikeWaveforms(trials, spikeTimes, spikeElectrode, spikeUnit, spikeWaveform, preMs, postMs, waveformScale, spikeTicks, startTicks, timeRes)
        % Collect the raw waveform (uV) of every in-window spike into a dense,
        % NaN-padded 4-D array. Rows are one per (electrode, unit) in the SAME
        % order as segmentSpikes, so waveform rows line up 1:1 with the raster.
        % For each trial the window is [Start - preMs, End + postMs] (ms buffers),
        % matched against spikeTimes (seconds). spikeWaveform is [nSamp x nSpikes]
        % with columns aligned 1:1 to spikeTimes/spikeElectrode/spikeUnit.
        %   W.waveform       NtotalUnit x nTrials x maxSpk x nSamp  (uV, NaN-padded)
        %   W.waveform_time  NtotalUnit x nTrials x maxSpk          (s, relative to Start)
        % maxSpk is the largest per-(unit,trial) in-window spike count, shared
        % across all rows/trials -> the busiest unit drives memory. Trials with a
        % NaN Start/End contribute no spikes (all-NaN slice), staying index-aligned.
        % waveformScale is the optional per-spike uV-per-digit factor that goes
        % with a raw int16 spikeWaveform; omit/empty when it is already in uV.
            if nargin < 6 || isempty(preMs);  preMs  = 500; end   % default buffer (ms)
            if nargin < 7 || isempty(postMs); postMs = 500; end
            if nargin < 8; waveformScale = []; end                % [] -> already uV
            if nargin < 9;  spikeTicks = uint64([]); end
            if nargin < 10; startTicks = uint64([]); end
            if nargin < 11; timeRes    = [];         end

            pre  = preMs  / 1000;   % seconds
            post = postMs / 1000;

            spikeTimes     = double(spikeTimes(:));
            spikeElectrode = double(spikeElectrode(:));
            spikeUnit      = double(spikeUnit(:));
            % Force columns: these get compared elementwise against per-pair
            % column vectors below, and a stray row would broadcast into an
            % nPair x nPair matrix instead of comparing pairwise.
            spikeTicks     = spikeTicks(:);
            startTicks     = startTicks(:);
            nSamp = size(spikeWaveform, 1);   % [nSamp x nSpikes]

            % --- channel list: one row per (electrode, unit), sorted (matches segmentSpikes) ---
            chanKeys  = unique([spikeElectrode, spikeUnit], 'rows');
            electrode = chanKeys(:, 1);
            unit      = chanKeys(:, 2);
            nChan     = size(chanKeys, 1);
            [~, spikeRow] = ismember([spikeElectrode, spikeUnit], chanKeys, 'rows');

            nTrials = numel(trials);

            % --- trial windows ---
            starts = [trials.Start]';
            ends   = [trials.End]';
            ok     = ~isnan(starts) & ~isnan(ends);   % missing marker -> all-NaN slice

            t_start = nan(nTrials, 1);   t_start(ok) = starts(ok) - pre;
            t_end   = nan(nTrials, 1);   t_end(ok)   = ends(ok)   + post;
            rawstarttime = nan(nTrials, 1);
            rawstarttime(ok) = starts(ok);   % abs time of the Start marker (s)

            % --- every (trial, in-window spike) pair, and each spike's position
            % 1..k within its (row, trial) group ---
            % This replaces both the old per-trial scan for maxSpk and the
            % per-spike scalar 4-D assignment: the pairs come from one binary
            % search per trial bound, and the position is a rank-within-group
            % computed by sorting rather than by a running counter.
            [sortedTimes, sortIdx] = sort(spikeTimes);
            [spkIdx, trialOf] = BlackrockLoader.trialSpikeIndex(sortedTimes, t_start, t_end);
            origIdx = sortIdx(spkIdx);          % index into the unsorted spike arrays
            rowOf   = spikeRow(origIdx);

            nPair = numel(spkIdx);
            pos   = zeros(nPair, 1);
            if nPair > 0
                % rank within each (row, trial) group: sort by group (stable, so
                % time order is kept inside a group), then run a counter that
                % resets at every group boundary.
                g = (trialOf - 1) * nChan + rowOf;
                [gs, gord] = sort(g);
                isNew = [true; diff(gs) ~= 0];
                run   = (1:nPair)';
                pos(gord) = run - cummax(run .* isNew) + 1;
            end
            maxSpk = max([pos; 0]);

            % --- allocate (warn first if the dense array is large) ---
            if nChan*nTrials*maxSpk*nSamp*4 > 2e9
                warning(['segmentSpikeWaveforms: waveform array is %.1f GB ' ...
                    '(%d units x %d trials x %d spikes x %d samples). ' ...
                    'Consider narrowing the data (fewer/sorted units or trials).'], ...
                    nChan*nTrials*maxSpk*nSamp*4/1e9, nChan, nTrials, maxSpk, nSamp);
            end
            wf      = nan(nChan, nTrials, maxSpk, nSamp, 'single');   % uV, NaN-padded
            % Times stay double. Only voltages go single: at a few seconds from
            % the marker a single resolves ~0.5 us, which would throw away real
            % resolution on a 30 kHz (let alone nanosecond PTP) spike clock.
            % This array is nSamp times smaller than wf, so the cost is minor.
            wf_time = nan(nChan, nTrials, maxSpk);                    % s, relative to Start

            % --- fill: two indexed writes instead of a scalar write per spike ---
            if nPair > 0
                base = sub2ind([nChan, nTrials, maxSpk], rowOf, trialOf, pos);

                % Time of each spike relative to its trial's Start marker.
                % Both clocks are absolute epoch values (~1.5e18 ns), so in
                % seconds a double resolves only ~238 ns and the subtraction
                % below would inherit that from BOTH operands. When the raw
                % integer ticks are available, subtract them first (exact in
                % uint64) and divide after -- the result then lands near zero,
                % where a double resolves ~0.004 ns.
                exact_ticks = ~isempty(spikeTicks) && ~isempty(startTicks) && ...
                              ~isempty(timeRes) && numel(spikeTicks) == numel(spikeTimes) && ...
                              numel(startTicks) == nTrials;
                if exact_ticks
                    st_tick  = spikeTicks(sortIdx);          % same order as sortedTimes
                    spkTick  = reshape(st_tick(spkIdx), [], 1);
                    refTick  = reshape(startTicks(trialOf), [], 1);
                    % uint64 cannot go negative; split so pre-Start spikes keep
                    % their sign instead of saturating at zero.
                    after    = spkTick >= refTick;
                    dt       = zeros(nPair, 1);
                    dt( after) =  double(spkTick( after) - refTick( after)) / timeRes;
                    dt(~after) = -double(refTick(~after) - spkTick(~after)) / timeRes;
                    % trials with no recorded Start tick fall back to seconds
                    noRef        = refTick == 0;
                    dt(noRef)    = sortedTimes(spkIdx(noRef)) - rawstarttime(trialOf(noRef));
                    wf_time(base) = dt;
                else
                    wf_time(base) = sortedTimes(spkIdx) - rawstarttime(trialOf);
                end

                % wf is [row, trial, spk, samp]; the sample dimension is last, so
                % consecutive samples of one spike sit a whole page apart.
                page  = nChan * nTrials * maxSpk;
                block = single(spikeWaveform(:, origIdx));               % nSamp x nPair
                if ~isempty(waveformScale)
                    block = block .* single(reshape(waveformScale(origIdx), 1, nPair));
                end
                wf(base + (0:nSamp-1) * page) = block.';
            end

            W = struct();
            W.waveform       = wf;       % NtotalUnit x nTrials x maxSpk x nSamp, uV, NaN-padded
            W.waveform_time  = wf_time;  % NtotalUnit x nTrials x maxSpk, s, relative to Start
            W.waveform_nsamp = nSamp;    % samples per waveform
            W.waveform_unit  = 'microVolts';
            W.timeseq.alignedrawtime = rawstarttime;   % nTrials x 1, abs Start time (s)
            W.timeseq.aligned_marker = 'Start';        % waveform_time = 0 at the Start marker
            W.info.Session        = [trials.Session]';     % nTrials x 1
            W.info.Trial_number   = [trials.Trial_number]';% nTrials x 1
            W.info.Channel_Number = electrode;             % NtotalUnit x 1, electrode per row
            W.info.Unit_No        = unit;                  % NtotalUnit x 1, unit per row
            W.info.maxSpikes      = maxSpk;                % spike-dimension length (busiest unit-trial)
        end

        function K = tokenizeComments(Events)
        % Split the whole comment char matrix at once into the pieces the parse
        % needs: trial number, event body, and the Experiment marker/token.
        %
        % Replaces two regexp calls per comment with a handful of whole-array
        % string operations. For 1.1e5 comments this runs in ~0.17 s, and
        % str2double over the trial numbers is the single biggest line in it.
        %
        % Returned struct K (all comment-length vectors are N x 1):
        %   txt/tnum/body   trimmed comment, trial number (NaN if none), body
        %   isExpLine/isTrialLine/isMalformed   disjoint classification
        %   expIdx/expMarker/expToken           the Experiment lines only
            % Observed .nev comment text is space-padded, but strtrim strips
            % NUL on neither char nor string (isspace(char(0)) is false), so a
            % NUL-padded file would silently defeat every match below. One
            % normalising pass removes the question entirely.
            Events(Events == char(0)) = ' ';
            K.txt = strtrim(string(Events));

            % extractBefore/extractAfter split at the FIRST colon, exactly where
            % '^Trial\s+(\d+):' splits, so a colon inside the body is safe.
            % Both yield <missing> when there is no colon; str2double(<missing>)
            % is NaN, and that NaN is what routes a malformed comment to the
            % fail-soft path instead of the crash the per-comment parser had.
            prefix = extractBefore(K.txt, ":");
            K.tnum = str2double(extractAfter(prefix, "Trial "));
            K.body = strtrim(extractAfter(K.txt, ":"));
            % unique() keeps every <missing> distinct (same rule as NaN), so
            % leaving them in would collapse the whole point of uniquing the
            % bodies. "" merges normally.
            K.body(ismissing(K.body)) = "";

            % Cheap prefilter, then the real pattern on those ~30 rows only.
            % '(.*)' not '(.+)': the per-comment parser matched the UNtrimmed
            % row, which always carried trailing padding, so a bare
            % "Experiment end:" still matched. Against trimmed text '(.+)'
            % fails and the session end timestamp would be lost.
            ei  = find(startsWith(K.txt, "Experiment "));
            tok = BlackrockLoader.regexpTokensOnce(K.txt(ei), '^Experiment (start|end):\s*(.*)$');
            % cellfun('isempty', ...) reports FALSE for an empty string element
            % -- the fast-string form only understands cell/char. The function
            % handle is required here, not a style preference.
            ok  = ~cellfun(@isempty, tok);
            K.expIdx = ei(ok);
            if isempty(K.expIdx)
                K.expMarker = strings(0,1);
                K.expToken  = strings(0,1);
            else
                % string input to regexp yields string tokens, so this vertcat
                % gives an M x 2 string matrix directly.
                V = vertcat(tok{ok});
                K.expMarker = V(:,1);
                K.expToken  = strtrim(V(:,2));
            end

            K.isExpLine = false(size(K.txt));
            K.isExpLine(K.expIdx) = true;
            K.isTrialLine = ~K.isExpLine & startsWith(K.txt, "Trial ") & ~isnan(K.tnum);
            % Anything claimed by neither branch. The per-comment parser fell
            % through to the trial branch here and died indexing mainTokens{1}.
            K.isMalformed = ~K.isExpLine & ~K.isTrialLine;
        end

        function K = indexCommentTrials(K)
        % Assign each trial comment its trial row, by cumsum instead of by
        % carrying prev_trial_number/prev_session through a loop.
        %
        % Reproduces the per-comment rule exactly: a new trial opens when the
        % parsed number differs from the previous TRIAL comment, or the
        % git-marker session changed (which is what splits two trials that
        % share a number across a session boundary).
            isGitStart = false(size(K.txt));
            if ~isempty(K.expIdx)
                isGitStart(K.expIdx(K.expMarker == "start" & ...
                                    startsWith(K.expToken, "git commit"))) = true;
            end
            % 0 before the first marker, matching the old session_index.
            K.sessGit = cumsum(isGitStart);

            c = find(K.isTrialLine);
            K.trialCommentIdx   = c;
            K.trialRowOfComment = zeros(size(K.txt));
            if isempty(c)
                K.tnumPerTrial    = zeros(0,1);
                K.sessGitPerTrial = zeros(0,1);
                K.nTrials         = 0;
                return
            end

            tn = K.tnum(c);
            sg = K.sessGit(c);
            newTrial = [true; diff(tn) ~= 0 | diff(sg) ~= 0];
            rowOf    = cumsum(newTrial);

            K.trialRowOfComment(c) = rowOf;
            K.tnumPerTrial    = tn(newTrial);
            K.sessGitPerTrial = sg(newTrial);
            K.nTrials         = rowOf(end);
        end

        function Session = sessionLabelsFromResets(K)
        % Label sessions from trial-number resets, cross-checked against the
        % "Experiment start: git commit" markers.
        %
        % The markers alone are not trustworthy: a file that was not saved
        % cleanly can be missing the leading metadata block, and the old rule
        % then stamped every trial of that block Session = 0 -- which matters,
        % because Session is a join key downstream (SpikeTrialAlignmentCheck
        % pairs comments to spikes on (Session, Trial_number)). Counting resets
        % always yields 1-based labels covering every trial.
        %
        % The markers are still parsed and used as a consistency check: when
        % the two partitions disagree, that is a real anomaly worth surfacing,
        % so it warns rather than silently preferring one.
        %
        % '<= 0' rather than '< 0' because indexCommentTrials keeps the
        % git-session term in its boundary rule: two adjacent trial rows can
        % share a trial number only when a marker split them, which is itself a
        % session change.
            if K.nTrials == 0
                Session = zeros(0,1);
                return
            end

            newSessReset = [true; diff(K.tnumPerTrial) <= 0];
            Session      = cumsum(newSessReset);

            if max(K.sessGitPerTrial) == 0
                warning('BlackrockLoader:parseEvents:NoGitMarker', ...
                    ['No "Experiment start: git commit" marker precedes any trial; ' ...
                     'session labels derive from trial-number resets alone (%d session(s)).'], ...
                    Session(end));
                return
            end

            newSessGit = [true; diff(K.sessGitPerTrial) ~= 0];
            if ~isequal(newSessReset, newSessGit)
                d = find(newSessReset ~= newSessGit, 1);
                warning('BlackrockLoader:parseEvents:SessionMismatch', ...
                    ['Session partition from trial-number resets (%d session(s)) disagrees ' ...
                     'with the git-commit markers (%d session(s)); first disagreement at ' ...
                     'trial row %d (Trial_number %d). Using the reset-derived labels.'], ...
                    Session(end), sum(newSessGit), d, K.tnumPerTrial(d));
            end
        end

        function validateEventMaps(maps)
        % Assert the invariant that lets exact-match lookup stand in for the
        % per-comment parser's substring reverse lookup, contains(keys, name).
        % The two agree only while no key in a map is a proper substring of
        % another key in the SAME map. Adding e.g. 'Fixation point' alongside
        % 'Fixation point on' would silently bind events to the wrong field, so
        % fail here instead.
            names = {'TimeEvents', 'InformationEvents', 'SegmentEvents'};
            for n = 1:numel(names)
                kk = string(keys(maps.(names{n})));
                for a = 1:numel(kk)
                    inside = contains(kk, kk(a));
                    inside(a) = false;
                    if any(inside)
                        error('BlackrockLoader:EventMaps:SubstringKey', ...
                            ['%s: key "%s" is a substring of "%s". Event lookup is ' ...
                             'exact-match and cannot disambiguate these.'], ...
                            names{n}, kk(a), kk(find(inside, 1)));
                    end
                end
            end
        end

        function spec = classifyEventBodies(ub, maps, trialTemplate)
        % Decide, once per DISTINCT event body, which trial field(s) it writes
        % and what value it carries.
        %
        % This is where the saving lives. The bodies repeat heavily across
        % trials -- a 109k-comment session has ~600 distinct ones -- so the
        % regex work collapses by more than 100x, and the per-comment pass
        % downstream is reduced to scattering already-parsed values.
        %
        % Returns arrays indexed by unique-body, with up to 3 write slots (the
        % most any branch emits, from the offset-range line):
        %   field    nU x 3  index into fieldnames(trialTemplate); 0 = no write
        %   mode     nU x 3  1 = comment timestamp, 2 = scalar, 3 = [x y], 4 = text
        %   num      nU x 3  value for mode 2
        %   xy       nU x 2  value for mode 3 (slot 1 only)
        %   txt      nU x 3  value for mode 4
        %   dupLab   nU x 3  what a losing write appends to trials.duplicates
        %   lastWins nU x 3  overwrite instead of first-write-wins, no duplicate
        %   isUndef  nU x 1  body matched nothing; goes to trials.undefined
        %
        % Mode 1 is the reason this cannot be purely per-body: those values come
        % from each comment's own timestamp, so they are scattered per comment.
            ub = ub(:);
            nU = numel(ub);
            fn = fieldnames(trialTemplate);

            spec.field    = zeros(nU, 3);
            spec.mode     = zeros(nU, 3);
            spec.num      = nan(nU, 3);
            spec.xy       = nan(nU, 2);
            spec.txt      = strings(nU, 3);
            spec.dupLab   = strings(nU, 3);
            spec.lastWins = false(nU, 3);
            spec.isUndef  = false(nU, 1);

            timeKeys = string(keys(maps.TimeEvents));   timeVals = string(values(maps.TimeEvents));
            infoKeys = string(keys(maps.InformationEvents)); infoVals = string(values(maps.InformationEvents));
            segKeys  = string(keys(maps.SegmentEvents)); segVals  = string(values(maps.SegmentEvents));

            % Same tests as the per-comment chain, assigned in reverse priority
            % so the highest-priority branch (time) overwrites the rest.
            kind = zeros(nU, 1);
            kind(contains(ub, 'Requested time offset range'))               = 6;
            kind(contains(ub, string(maps.OutcomeEvents)))                  = 5;
            kind(contains(ub, string(maps.DashEvents)) & contains(ub, '-')) = 4;
            kind(contains(ub, segKeys))                                     = 3;
            kind(contains(ub, infoKeys))                                    = 2;
            kind(contains(ub, timeKeys))                                    = 1;

            % Patterns copied verbatim from the per-comment parser. The time and
            % size patterns are applied in sequence rather than as one
            % alternation: the combined form has four capture groups but its
            % result was read as if it had two, which only worked because
            % non-participating groups are dropped. Both are '^'-anchored, so
            % "time else size" is exactly what the alternation meant.
            coord_pattern  = '^(.*?)\s*\(\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\)\s*deg$';
            reward_pattern = '^(.*?)\s*\(([\d\.]+)ms';
            time_pattern   = '^(.*?)\s+([-+]?\d*\.?\d+|None|none)\s*ms$';
            size_pattern   = '^(.*?)\s+([-+]?\d*\.?\d+)\s*(?:deg)?$';

            % ---- kind 1: time events -> the comment's own timestamp ----------
            sel = find(kind == 1);
            [hit, loc] = ismember(ub(sel), timeKeys);
            spec.field(sel(hit), 1)  = BlackrockLoader.fieldIndex(timeVals(loc(hit)), fn);
            spec.mode(sel(hit), 1)   = 1;
            spec.dupLab(sel(hit), 1) = ub(sel(hit));      % duplicate label = the body
            spec.isUndef(sel(~hit))  = true;

            % ---- kind 2: information events ---------------------------------
            % Sub-branches in the per-comment order: coordinate, then reward,
            % then a plain scalar.
            sel = find(kind == 2);
            cTok = BlackrockLoader.regexpTokensOnce(ub(sel), coord_pattern);
            rTok = BlackrockLoader.regexpTokensOnce(ub(sel), reward_pattern);
            isC  = ~cellfun(@isempty, cTok);
            isR  = ~isC & ~cellfun(@isempty, rTok);
            isS  = ~isC & ~isR;

            % coordinate: '<name> (x, y) deg' -> a 1x2 field
            if any(isC)
                r = sel(isC);  V = vertcat(cTok{isC});
                [f, ok] = BlackrockLoader.lookupEventField(strtrim(V(:,1)), infoKeys, infoVals, fn);
                spec.field(r(ok), 1)  = f(ok);
                spec.mode(r(ok), 1)   = 3;
                spec.xy(r(ok), :)     = [str2double(V(ok,2)), str2double(V(ok,3))];
                spec.dupLab(r(ok), 1) = strtrim(V(ok,1));   % label = the key name
                spec.isUndef(r(~ok))  = true;
            end

            % reward: '<name> (<amount>ms...' -> the field takes the TIMESTAMP,
            % and the amount lands in Reward_amount, each guarded separately.
            if any(isR)
                r = sel(isR);  V = vertcat(rTok{isR});
                [f, ok] = BlackrockLoader.lookupEventField(strtrim(V(:,1)), infoKeys, infoVals, fn);
                spec.field(r(ok), 1)  = f(ok);
                spec.mode(r(ok), 1)   = 1;
                spec.dupLab(r(ok), 1) = infoVals(BlackrockLoader.matchIndex(strtrim(V(ok,1)), infoKeys));
                spec.field(r(ok), 2)  = BlackrockLoader.fieldIndex("Reward_amount", fn);
                spec.mode(r(ok), 2)   = 2;
                spec.num(r(ok), 2)    = str2double(V(ok,2));
                spec.dupLab(r(ok), 2) = "Reward_amount";
                spec.isUndef(r(~ok))  = true;
            end

            % scalar: '<name> <value> ms' else '<name> <value> [deg]'.
            % str2double turns the None/none alternative into NaN by itself.
            if any(isS)
                r = sel(isS);
                tTok = BlackrockLoader.regexpTokensOnce(ub(r), time_pattern);
                useT = ~cellfun(@isempty, tTok);
                sTok = BlackrockLoader.regexpTokensOnce(ub(r), size_pattern);
                useS = ~useT & ~cellfun(@isempty, sTok);
                V = strings(numel(r), 2);
                if any(useT), V(useT, :) = vertcat(tTok{useT}); end
                if any(useS), V(useS, :) = vertcat(sTok{useS}); end
                got = useT | useS;
                [f, ok] = BlackrockLoader.lookupEventField(strtrim(V(:,1)), infoKeys, infoVals, fn);
                ok = ok & got;
                spec.field(r(ok), 1)  = f(ok);
                spec.mode(r(ok), 1)   = 2;
                spec.num(r(ok), 1)    = str2double(V(ok, 2));
                spec.dupLab(r(ok), 1) = infoVals(BlackrockLoader.matchIndex(strtrim(V(ok,1)), infoKeys));
                spec.isUndef(r(~ok))  = true;
            end

            % ---- kind 3: segment events, split at the LAST space -------------
            sel = find(kind == 3);
            if ~isempty(sel)
                gTok = BlackrockLoader.regexpTokensOnce(ub(sel), '^(.*) ([^ ]*)$');   % greedy = last space
                got  = ~cellfun(@isempty, gTok);
                r = sel(got);  V = vertcat(gTok{got});
                [f, ok] = BlackrockLoader.lookupEventField(strtrim(V(:,1)), segKeys, segVals, fn);
                spec.field(r(ok), 1)  = f(ok);
                spec.mode(r(ok), 1)   = 4;
                spec.txt(r(ok), 1)    = strtrim(V(ok, 2));
                spec.dupLab(r(ok), 1) = segVals(BlackrockLoader.matchIndex(strtrim(V(ok,1)), segKeys));
                spec.isUndef(r(~ok))  = true;
                spec.isUndef(sel(~got)) = true;
            end

            % ---- kind 4: dash events, split at the FIRST dash ----------------
            sel = find(kind == 4);
            if ~isempty(sel)
                dTok = BlackrockLoader.regexpTokensOnce(ub(sel), '^([^-]*)-(.*)$');
                got  = ~cellfun(@isempty, dTok);
                r = sel(got);  V = vertcat(dTok{got});
                ev  = strtrim(V(:,1));
                out = strtrim(V(:,2));

                isEnd = contains(ev, 'End');
                spec.field(r(isEnd), 1)  = BlackrockLoader.fieldIndex("End", fn);
                spec.mode(r(isEnd), 1)   = 1;                 % End takes the timestamp
                spec.dupLab(r(isEnd), 1) = ev(isEnd);
                spec.field(r(isEnd), 2)  = BlackrockLoader.fieldIndex("Trialoutcome", fn);
                spec.mode(r(isEnd), 2)   = 4;
                spec.txt(r(isEnd), 2)    = out(isEnd);
                spec.dupLab(r(isEnd), 2) = "Trialoutcome";

                isCh = ~isEnd & contains(ev, 'choice');
                spec.field(r(isCh), 1)  = BlackrockLoader.fieldIndex("Choosen_choice", fn);
                spec.mode(r(isCh), 1)   = 4;
                spec.txt(r(isCh), 1)    = out(isCh);
                spec.dupLab(r(isCh), 1) = "Choosen_choice";

                spec.isUndef(r(~isEnd & ~isCh)) = true;
                spec.isUndef(sel(~got))         = true;
            end

            % ---- kind 5: choice outcome, stored as the whole body ------------
            sel = find(kind == 5);
            spec.field(sel, 1)  = BlackrockLoader.fieldIndex("Choiceoutcome", fn);
            spec.mode(sel, 1)   = 4;
            spec.txt(sel, 1)    = ub(sel);
            spec.dupLab(sel, 1) = "Choiceoutcome";

            % ---- kind 6: requested time offset range -------------------------
            % Alone among the branches this has no already-written guard, so it
            % is last-write-wins and records no duplicates. A line matching
            % neither token writes nothing and is NOT undefined -- the
            % per-comment parser silently ignored it.
            sel = find(kind == 6);
            if ~isempty(sel)
                gTok = BlackrockLoader.regexpTokensOnce(ub(sel), 'range\s*\[\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\]');
                got  = ~cellfun(@isempty, gTok);
                if any(got)
                    r = sel(got);  V = vertcat(gTok{got});
                    spec.field(r, 1)    = BlackrockLoader.fieldIndex("Requested_time_offset_min", fn);
                    spec.mode(r, 1)     = 2;
                    spec.num(r, 1)      = str2double(V(:,1));
                    spec.lastWins(r, 1) = true;
                    spec.field(r, 2)    = BlackrockLoader.fieldIndex("Requested_time_offset_max", fn);
                    spec.mode(r, 2)     = 2;
                    spec.num(r, 2)      = str2double(V(:,2));
                    spec.lastWins(r, 2) = true;
                end

                aTok = BlackrockLoader.regexpTokensOnce(ub(sel), 'active:\s*\[([^\]]*)\]');
                gotA = ~cellfun(@isempty, aTok);
                if any(gotA)
                    r = sel(gotA);  A = vertcat(aTok{gotA});
                    vals = arrayfun(@(s) strjoin(strtrim(strsplit(s, ',')), ' '), A(:,1), ...
                                    'UniformOutput', false);
                    spec.field(r, 3)    = BlackrockLoader.fieldIndex("Requested_time_offset_active", fn);
                    spec.mode(r, 3)     = 4;
                    spec.txt(r, 3)      = string(vals);
                    spec.lastWins(r, 3) = true;
                end
            end

            % ---- kind 0: claimed by nothing ---------------------------------
            spec.isUndef(kind == 0) = true;
        end

        function [cols, dupCells, undCells, startTicks, endTicks, nUndef] = scatterEventWrites( ...
                spec, ic, K, Session, EventTime, EventTick, has_ticks, trialTemplate)
        % Fill one column per trial field, one pass per FIELD rather than one
        % per comment.
        %
        % Grouping by target field (not by event key) is what makes the
        % many-to-one cases correct for free: 'Target 1 acquired' and
        % 'Target 2 acquired' both write Choicetime, and first-write-wins has to
        % apply across their union, which it does when they share a pass.
            fn      = fieldnames(trialTemplate);
            nF      = numel(fn);
            nTrials = K.nTrials;
            nU      = size(spec.field, 1);

            cmtIdx  = K.trialCommentIdx;
            nTC     = numel(cmtIdx);
            rowOfTC = K.trialRowOfComment(cmtIdx);
            timeOfTC = EventTime(cmtIdx);

            % Which fields end up holding text, and which hold an [x y] pair.
            % Decided from what this file actually wrote, not from a fixed list:
            % a field nobody wrote text to must stay a plain double column, or
            % prepareExport's iscell test would change the exported column type.
            isTextField = false(nF, 1);
            isTextField(spec.field(spec.mode == 4 & spec.field > 0)) = true;
            isPairField = false(nF, 1);
            for k = 1:nF
                isPairField(k) = isnumeric(trialTemplate.(fn{k})) && numel(trialTemplate.(fn{k})) == 2;
            end

            cols = cell(nF, 1);
            for k = 1:nF
                if isTextField(k)
                    cols{k} = repmat({NaN}, nTrials, 1);
                elseif isPairField(k)
                    cols{k} = nan(nTrials, 2);
                else
                    cols{k} = nan(nTrials, 1);
                end
            end

            startTicks = zeros(nTrials, 1, 'uint64');
            endTicks   = zeros(nTrials, 1, 'uint64');
            dupCells   = repmat({strings(0,1)}, nTrials, 1);
            undCells   = repmat({strings(0,1)}, nTrials, 1);

            if nTrials == 0
                nUndef = 0;
                return
            end

            % Identity columns come straight from the index pass.
            cols{BlackrockLoader.fieldIndex("Trial_number", fn)} = K.tnumPerTrial(:);
            cols{BlackrockLoader.fieldIndex("Session", fn)}      = Session(:);

            % Flatten the three write slots of every trial comment into one list
            % of (comment, slot) pairs, carrying indices rather than copies.
            flatU    = repmat(ic(:), 3, 1);
            flatSlot = repelem((1:3)', nTC, 1);
            flatCmt  = repmat((1:nTC)', 3, 1);
            lin      = flatU + (flatSlot - 1) * nU;
            flatFld  = spec.field(lin);
            keep     = flatFld > 0;

            dupRow = []; dupOrd = []; dupLab = strings(0,1);
            usedFields = unique(flatFld(keep));

            for f = usedFields'
                sel = find(keep & flatFld == f);
                % Comment order. A single body never writes one field twice, so
                % ordering by comment is a total order within a field.
                [~, o] = sort(flatCmt(sel));
                sel = sel(o);
                r   = rowOfTC(flatCmt(sel));

                if any(spec.lastWins(lin(sel)))
                    % The offset-range fields have no already-written guard, so
                    % the last line of a trial wins and nothing is recorded as a
                    % duplicate.
                    [~, iaRev] = unique(flipud(r), 'stable');
                    ia = sort(numel(r) + 1 - iaRev);
                    isLoser = [];
                else
                    [~, ia] = unique(r, 'stable');     % first occurrence per trial
                    won = false(numel(r), 1);
                    won(ia) = true;
                    isLoser = find(~won);
                end

                sub = sel(ia);
                md  = spec.mode(lin(sub));
                rw  = r(ia);

                if isTextField(f)
                    cols{f}(rw) = cellstr(spec.txt(lin(sub)));
                elseif isPairField(f)
                    cols{f}(rw, :) = spec.xy(flatU(sub), :);
                else
                    v = nan(numel(sub), 1);
                    m1 = md == 1;  v(m1) = timeOfTC(flatCmt(sub(m1)));
                    m2 = md == 2;  v(m2) = spec.num(lin(sub(m2)));
                    cols{f}(rw) = v;
                    % Keep the Start and End markers' exact ticks: the trial
                    % window and every per-spike time are measured from them, and
                    % doing those subtractions in seconds would inherit ~238 ns
                    % of rounding from each operand (see segmentContinuous /
                    % segmentSpikes / segmentSpikeWaveforms).
                    if has_ticks && f == BlackrockLoader.fieldIndex("Start", fn)
                        startTicks(rw(m1)) = EventTick(cmtIdx(flatCmt(sub(m1))));
                    elseif has_ticks && f == BlackrockLoader.fieldIndex("End", fn)
                        endTicks(rw(m1))   = EventTick(cmtIdx(flatCmt(sub(m1))));
                    end
                end

                if ~isempty(isLoser)
                    dupRow = [dupRow; r(isLoser)];                       %#ok<AGROW>
                    dupOrd = [dupOrd; flatCmt(sel(isLoser)) * 4 + flatSlot(sel(isLoser))]; %#ok<AGROW>
                    dupLab = [dupLab; spec.dupLab(lin(sel(isLoser)))];   %#ok<AGROW>
                end
            end

            % Bodies that matched no branch, attributed to the trial they fell in.
            undMask = spec.isUndef(ic(:));
            nUndef  = sum(undMask);
            undCells = BlackrockLoader.groupLabelsByTrial(rowOfTC(undMask), find(undMask), ...
                                                          K.body(cmtIdx(undMask)), nTrials);

            % Duplicates are appended in the order the comments arrived, which
            % interleaves across fields -- so they are ordered globally by
            % (trial, comment, slot) rather than by the field loop above.
            dupCells = BlackrockLoader.groupLabelsByTrial(dupRow, dupOrd, dupLab, nTrials);

            % Equivalent to the per-comment 'if Start > 0 then Save_complete = 1'
            % re-evaluated after every comment: NaN > 0 is false, and Start is
            % written at most once, so the fixpoint is just the test itself.
            cols{BlackrockLoader.fieldIndex("Save_complete", fn)} = ...
                double(cols{BlackrockLoader.fieldIndex("Start", fn)} > 0);
        end

        function C = groupLabelsByTrial(rows, ord, labels, nTrials)
        % Bucket (trial, order, label) triples into one string array per trial,
        % ordered by ord. Returns nTrials x 1 cell of string columns, empty ones
        % being strings(0,1) to match the template.
            C = repmat({strings(0,1)}, nTrials, 1);
            if isempty(rows)
                return
            end
            [~, o] = sortrows([rows(:), ord(:)]);
            rows   = rows(o);
            labels = labels(o);
            cnt    = accumarray(rows, 1, [nTrials 1]);
            hit    = find(cnt > 0);
            parts  = mat2cell(labels(:), cnt(cnt > 0), 1);
            C(hit) = parts;
        end

        function trials = assembleTrialStruct(cols, dupCells, undCells, trialTemplate)
        % Turn the per-field columns into the struct array the rest of the
        % loader expects, preserving each field's runtime type: plain double,
        % 1x2 double, or char-where-written/NaN-where-not.
            fn      = fieldnames(trialTemplate);
            nF      = numel(fn);
            nTrials = size(cols{1}, 1);
            if nTrials == 0
                trials = repmat(trialTemplate, 0, 1);
                return
            end

            C = cell(nF, nTrials);
            for k = 1:nF
                switch fn{k}
                    case 'duplicates', C(k,:) = dupCells';
                    case 'undefined',  C(k,:) = undCells';
                    otherwise
                        if iscell(cols{k})
                            C(k,:) = cols{k}';
                        elseif size(cols{k}, 2) == 2
                            C(k,:) = num2cell(cols{k}, 2)';
                        else
                            C(k,:) = num2cell(cols{k})';
                        end
                end
            end
            % nF x nTrials with dim 1 as the field axis yields nTrials x 1,
            % matching the orientation the per-comment parser produced.
            trials = cell2struct(C, fn, 1);
        end

        function experiment = buildExperimentMeta(K, EventTime, expTemplate, expEvents, Session)
        % Build the per-session metadata entries, then index them by the
        % reset-derived Session label.
        %
        % Still a loop, deliberately: there are ~30 Experiment lines in a
        % session against ~1e5 comments, so restricting the original loop to
        % them is already a >1000x cut and the branchy per-key handling stays
        % readable. Only the loop bound changed.
            expKeys = keys(expEvents);
            nExp    = numel(K.expIdx);

            gitStart  = K.expMarker == "start" & startsWith(K.expToken, "git commit");
            markerCmt = K.expIdx(gitStart);
            nMarkers  = numel(markerCmt);

            expByMarker = repmat(expTemplate, nMarkers, 1);
            sIdx = 0;
            for e = 1:nExp
                ci     = K.expIdx(e);
                marker = K.expMarker(e);
                tokStr = K.expToken(e);
                tok    = char(tokStr);

                if marker == "start" && startsWith(tokStr, "git commit")
                    sIdx = sIdx + 1;
                    expByMarker(sIdx)       = expTemplate;
                    expByMarker(sIdx).start = EventTime(ci);
                end
                if sIdx < 1
                    % Metadata before the first git-commit start has nowhere to
                    % go, exactly as before.
                    continue
                end

                if marker == "end"
                    expByMarker(sIdx).end = EventTime(ci);      % last end wins
                    if ~startsWith(tokStr, "git commit")
                        % Why the session ended; the git-commit end line is just
                        % a commit re-stamp, not a reason.
                        expByMarker(sIdx).end_by = tok;
                    end
                end

                if startsWith(tokStr, "git commit")
                    expByMarker(sIdx).git_commit = strtrim(strrep(tok, 'git commit', ''));
                elseif startsWith(tokStr, "eyetracker tracking")
                    eye_tokens = regexp(tok, 'eyetracker tracking (\w+)', 'tokens');
                    if ~isempty(eye_tokens)
                        expByMarker(sIdx).eye_tracked = eye_tokens{1}{1};
                    end
                elseif startsWith(tokStr, "photodiode")
                    coord = regexp(tok, '\(\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\)', 'tokens');
                    if startsWith(tokStr, "photodiode circles")
                        expByMarker(sIdx).photodiode_circles = strtrim(strrep(tok, 'photodiode circles', ''));
                    elseif startsWith(tokStr, "photodiode fixation position") && ~isempty(coord)
                        expByMarker(sIdx).photodiode_fixation_position = cellfun(@str2double, coord{1});
                    elseif startsWith(tokStr, "photodiode target_1 position") && ~isempty(coord)
                        expByMarker(sIdx).photodiode_target_1_position = cellfun(@str2double, coord{1});
                    elseif startsWith(tokStr, "photodiode target_2 position") && ~isempty(coord)
                        expByMarker(sIdx).photodiode_target_2_position = cellfun(@str2double, coord{1});
                    end
                elseif strcmp(tok, 'experimenter closed task')
                    % end marker text, nothing to store
                else
                    % Numeric metadata (viewing distance / screen size /
                    % resolution / FPS / eyetracker rate).
                    num_tokens = regexp(tok, '^\s*(.*?)\s+(\d+\.?\d*)\D*(\d+\.?\d*)?', 'tokens');
                    if ~isempty(num_tokens)
                        event_exp  = strtrim(num_tokens{1}{1});
                        nums       = cellfun(@str2double, num_tokens{1}(2:end));
                        flag_array = find(contains(expKeys, event_exp));
                        % A non-unique match used to throw; skip it instead.
                        if isscalar(flag_array)
                            field = expEvents(expKeys{flag_array});
                            expByMarker(sIdx).(field) = nums(~isnan(nums));
                        end
                    end
                end
            end

            % Re-index from "one entry per git-commit marker" to "one entry per
            % Session label". These coincide for a clean file; they diverge when
            % a file is missing its leading metadata block, which is exactly the
            % case the reset-derived labels exist to handle. Sessions with no
            % metadata keep a blank template entry so experiment(Session) is
            % always addressable.
            nSess        = max([Session(:); 0]);
            sessOfMarker = zeros(nMarkers, 1);
            for m = 1:nMarkers
                nxt = find(K.trialCommentIdx > markerCmt(m), 1, 'first');
                if isempty(nxt)
                    % Trailing marker with no trials after it; give it its own
                    % session rather than dropping the metadata.
                    nSess = nSess + 1;
                    sessOfMarker(m) = nSess;
                else
                    sessOfMarker(m) = Session(K.trialRowOfComment(K.trialCommentIdx(nxt)));
                end
            end

            experiment = repmat(expTemplate, nSess, 1);
            filled     = false(nSess, 1);
            for m = 1:nMarkers
                s = sessOfMarker(m);
                if ~filled(s)
                    experiment(s) = expByMarker(m);
                    filled(s)     = true;
                else
                    % Two markers inside one reset-session: keep the opening
                    % block and take the closing one's end/end_by. Only reachable
                    % when sessionLabelsFromResets already warned.
                    experiment(s).end    = expByMarker(m).end;
                    experiment(s).end_by = expByMarker(m).end_by;
                end
            end
        end

        function tok = regexpTokensOnce(strs, pat)
        % regexp(..., 'tokens', 'once') over a list of strings, always returning
        % an N x 1 cell.
        %
        % Given a SCALAR string, regexp returns the token row unwrapped rather
        % than inside a 1x1 cell, so every "cellfun(@isempty, tok)" downstream
        % would silently index per-token instead of per-string. Only bites when
        % a session happens to contain exactly one distinct body of some kind,
        % which is why it survives most real files.
            strs = strs(:);
            tok  = regexp(strs, pat, 'tokens', 'once');
            if ~iscell(tok)
                tok = {tok};
            end
        end

        function idx = fieldIndex(names, fn)
        % Position of each field name within the trial template's field order.
            [~, idx] = ismember(cellstr(names(:)), fn);
        end

        function idx = matchIndex(names, keyList)
        % Index of each name in keyList: exact match where one exists, else the
        % sole substring match (what the per-comment reverse lookup did). 0 when
        % neither is unique.
            names = names(:);
            idx = zeros(numel(names), 1);
            [hit, loc] = ismember(names, keyList);
            idx(hit) = loc(hit);
            for k = find(~hit)'
                cand = find(contains(keyList, names(k)));
                if isscalar(cand); idx(k) = cand; end
            end
        end

        function [f, ok] = lookupEventField(names, keyList, valList, fn)
        % Map extracted event names to trial-field indices. ok is false where
        % the name matched no key (or matched ambiguously), which routes the
        % body to trials.undefined instead of erroring -- the per-comment parser
        % died here on an empty or multiple match.
            idx = BlackrockLoader.matchIndex(names, keyList);
            ok  = idx > 0;
            f   = zeros(numel(idx), 1);
            if any(ok)
                f(ok) = BlackrockLoader.fieldIndex(valList(idx(ok)), fn);
            end
        end

        function trials = addDerivedTrialFeatures(trials)
        % Post-parse tail: relabel memory-type visual saccades, then append the
        % seven derived geometry/choice fields. Shared by every parser
        % implementation so an A/B diff shows parse differences only, never
        % differences in this block.
        %
        % Pure: takes the trials struct array, returns it with fields added.
            if isempty(trials)
                % vertcat of nothing is [], and [](:,1) errors. A comment set
                % with no trial lines is a legitimate (if useless) input.
                return
            end

            %% Change visual guided saccade (memory type) into memory guided saccade
            tasks = {trials.Task};
            trial_type = {trials.Trial_type};

            memory_idx = strcmp(trial_type, 'memory');
            task_idx = strcmp(tasks, 'visual_saccades_experiment');

            tasks(memory_idx&task_idx) = {'memory_saccades_experiment'};
            [trials.Task] = deal(tasks{:});

            %% Add a few feature for further analysis
            %1. Transform Cartesian into Polar for target postion
            % -180(left) to 180(right)
            Target_1_xy = vertcat(trials.Target_1_position);
            [theta, Target_1_ecc] = cart2pol(Target_1_xy(:,1),Target_1_xy(:,2));
            Target_1_angle = mod(90 - rad2deg(theta), 360);
            Target_1_angle(Target_1_angle >= 180) = Target_1_angle(Target_1_angle >= 180) - 360;

            Target_2_xy = vertcat(trials.Target_2_position);
            [theta, Target_2_ecc] = cart2pol(Target_2_xy(:,1),Target_2_xy(:,2));
            Target_2_angle = mod(90 - rad2deg(theta), 360);
            Target_2_angle(Target_2_angle >= 180) = Target_2_angle(Target_2_angle >= 180) - 360;

            stimulus_dir = (Target_1_angle >= 0) * 2 - 1;
            stimulus_dir(isnan(Target_1_angle)) = NaN;

            %2. Transform choice into target1/target2 and left/right
            ChooseTarget = cellfun(@(s) str2double(s(end)), {trials.Choosen_choice});
            ChooseLeftRight = ChooseTarget;
            ChooseLeftRight(ChooseTarget==1) = (Target_1_angle(ChooseTarget==1) >= 0) * 2 - 1;
            ChooseLeftRight(ChooseTarget==2) = (Target_2_angle(ChooseTarget==2) >= 0) * 2 - 1;

            %3. Add these features back
            Target1Angle_cell = num2cell(Target_1_angle);
            [trials.Target_1_angle] = deal(Target1Angle_cell{:});

            Target2Angle_cell = num2cell(Target_2_angle);
            [trials.Target_2_angle] = deal(Target2Angle_cell{:});

            stimulus_dir_cell = num2cell(stimulus_dir);
            [trials.Stimulus_direction] = deal(stimulus_dir_cell{:});

            ChooseTarget_cell = num2cell(ChooseTarget);
            [trials.Choose_target] = deal(ChooseTarget_cell{:});
            ChooseLeftRight_cell = num2cell(ChooseLeftRight);
            [trials.Choose_leftright] = deal(ChooseLeftRight_cell{:});

            Target_1_ecc_cell = num2cell(Target_1_ecc);
            [trials.Target_1_eccentricity] = deal(Target_1_ecc_cell{:});

            Target_2_ecc_cell = num2cell(Target_2_ecc);
            [trials.Target_2_eccentricity] = deal(Target_2_ecc_cell{:});
        end

        function exp_template = defaultExpTemplate()
        % Experimental meta data (one entry per session within the recording).
            exp_template = struct();
            exp_template.git_commit                   = NaN;
            exp_template.viewing_distance             = NaN;          % in cm
            exp_template.screen_size                  = [NaN, NaN];   % W x H cm
            exp_template.screen_resolution            = [NaN, NaN];   % pixels
            exp_template.FPS                          = NaN;          % Hz
            exp_template.eyetracker_rate              = NaN;          % Hz
            exp_template.eye_tracked                  = NaN;          % string
            exp_template.photodiode_circles           = NaN;          % 'visible'/'hidden'
            exp_template.photodiode_fixation_position = [NaN, NaN];   % deg
            exp_template.photodiode_target_1_position = [NaN, NaN];   % deg
            exp_template.photodiode_target_2_position = [NaN, NaN];   % deg
            exp_template.start                        = NaN;          % in s
            exp_template.end                          = NaN;          % in s
            exp_template.end_by                       = NaN;          % reason the session ended
        end

        function trial = defaultTrialTemplate()
        % Per-trial record; every field NaN-initialised so unseen events stay NaN.
            trial = struct();
            trial.Trial_number = NaN; %Current trial number
            trial.Session = NaN; %which experiment session this trial belongs to
            trial.Task = NaN; %TaskType
            trial.Trial_type = NaN;
            trial.Start = NaN; % trial start time, in s
            trial.Fixation_position = [NaN,NaN];%array:1-2: postion;%in deg
            trial.Fixation_size = NaN;% in deg
            trial.Fixation_acceptance_window=NaN; % in deg
            trial.Fixation_color = NaN;%color
            trial.Requested_fixation_hold_time = NaN; % in ms
            trial.Requested_fixation_duration = NaN; %in ms
            trial.Requested_timeout = NaN; % in ms
            trial.Requested_time_between_trials = NaN; % in ms
            trial.Target_1_position = [NaN,NaN];

            trial.Target_1_size = NaN; % in deg
            trial.Target_1_acceptance_window = NaN; % in deg
            trial.Target_1_color = NaN; % in deg
            trial.Requested_target_1_hold_time  = NaN; %in ms
            trial.Requested_target_1_timeout = NaN; %in ms
            trial.Requested_target_1_duration = NaN; %in ms

            trial.Target_2_position = [NaN,NaN];
            trial.Target_2_size = NaN; % in deg
            trial.Target_2_acceptance_window = NaN; % in deg
            trial.Target_2_color = NaN; % in deg

            trial.Requested_target_2_time_offset = NaN; %in ms
            trial.Requested_target_2_hold_time  = NaN; %in ms
            trial.Requested_penalty_box_duration = NaN; %in ms

            trial.Requested_target_dim_opacity = NaN;% 0 to 1
            trial.Requested_target_1_visible_duration = NaN; %in ms

            trial.Fixation_point_on = NaN; %in ms
            trial.Fixation_acquired = NaN; %in ms
            trial.Fixation_point_off = NaN; %in ms
            trial.Broke_fixation = NaN; %in ms
            trial.Target_1_presented =NaN; %in ms
            trial.Target_2_presented =NaN; %in ms
            trial.Targets_off = NaN; %in ms
            trial.Target_1_off = NaN; %in ms

            trial.Choiceoutcome = NaN;
            trial.Choosen_choice = NaN; %1 or 2
            trial.Choicetime = NaN; %in s
            trial.End = NaN; %in ms
            trial.Trialoutcome = NaN; %Correct or time out or others
            trial.Reward_start = NaN; %in s
            trial.Reward_amount = NaN; %in s
            trial.Reward_end =NaN; %in s
            trial.Save_complete = 0; %true: completely saved(have start marker); otherwise, false

            % Newly added trial events  06-17-2026
            trial.Feedback_flash_on              = NaN; %in s (event time)
            trial.Feedback_flash_off             = NaN; %in s (event time)
            trial.Fixation_exited                = NaN; %in s (event time)
            trial.Target_deadline_exceeded       = NaN; %in s (event time)
            trial.Requested_feedback_flash_duration = NaN; %in ms
            trial.Requested_choice_timeout       = NaN; %in ms
            trial.Requested_target_reach_deadline = NaN; %in ms (None -> NaN)
            trial.Target_1_side                  = NaN; %'left' or 'right'
            trial.Requested_time_offset_min      = NaN; %in ms
            trial.Requested_time_offset_max      = NaN; %in ms
            trial.Requested_time_offset_active   = NaN; %string, space-separated active offsets (ms)

            trial.undefined = strings(0,1);%Duplicates or undefind events
            trial.duplicates = strings(0,1);%Duplicates or undefind events
        end

        function maps = defaultEventMaps()
        % The comment-string -> struct-field maps. To capture a new event from
        % the task software, add a key here (and a matching field in the trial /
        % experiment template above).

            % For experimental meta file map
            maps.ExpEvents = containers.Map({'git commit','viewing distance','screen size','screen resolution','FPS','eyetracker sample rate','eyetracker tracking'},...
                {'git_commit','viewing_distance','screen_size','screen_resolution','FPS','eyetracker_rate','eye_tracked'});

            %For trial map
            maps.TimeEvents = containers.Map( {'Start', 'Fixation point on','Fixation point off','Reward end','Target 1 presented','Target 2 presented','Targets off',...
                'Fixation acquired','Broke fixation','Target 1 acquired','Target 2 acquired','Target 1 off',...
                'Feedback flash on','Feedback flash off','Fixation exited','Target deadline exceeded'}, ...
                {'Start','Fixation_point_on','Fixation_point_off','Reward_end','Target_1_presented','Target_2_presented','Targets_off',...
                'Fixation_acquired','Broke_fixation','Choicetime','Choicetime','Target_1_off',...
                'Feedback_flash_on','Feedback_flash_off','Fixation_exited','Target_deadline_exceeded'} ...
            );

            maps.SegmentEvents = containers.Map( {'Experiment','Fixation color','Target 1 color','Target 2 color','Trial type','Target 1 on the'},...
                {'Task','Fixation_color','Target_1_color','Target_2_color','Trial_type','Target_1_side'});

            maps.InformationEvents = containers.Map( ...
                {'Fixation position','Fixation size','Fixation acceptance window'...
                   'Target 1 size','Target 1 acceptance window','Requested fixation hold time',...
                   'Requested timeout','Requested time between trials',...
                   'Target 1 position','Target 1 size','Target 1 acceptance window','Requested fixation duration',...
                   'Requested target 1 hold time','Requested target 2 hold time'...
                   'Target 2 position','Target 2 size','Target 2 acceptance window',...
                   'Requested target 1 duration','Requested target 2 time offset',...
                   'Requested target 1 timeout','Requested penalty box duration',...
                   'Reward start','Requested target dim opacity','Requested target 1 visible duration',...
                   'Requested feedback flash duration','Requested choice timeout','Requested target reach deadline'
                   },...
                {'Fixation_position','Fixation_size','Fixation_acceptance_window' ...
                'Target_1_size','Target_1_acceptance_window','Requested_fixation_hold_time',...
                'Requested_timeout','Requested_time_between_trials',...
                'Target_1_position','Target_1_size','Target_1_acceptance_window','Requested_fixation_duration',...
                'Requested_target_1_hold_time','Requested_target_2_hold_time'...
                'Target_2_position','Target_2_size','Target_2_acceptance_window',...
                'Requested_target_1_duration','Requested_target_2_time_offset',...
                'Requested_target_1_timeout','Requested_penalty_box_duration',...
                'Reward_start','Requested_target_dim_opacity','Requested_target_1_visible_duration',...
                'Requested_feedback_flash_duration','Requested_choice_timeout','Requested_target_reach_deadline'
                });

            maps.DashEvents    = {'End','Correct choice','Wrong choice'};
            maps.OutcomeEvents = {'Correct choice','No choice','Wrong choice'};
        end
    end
end
