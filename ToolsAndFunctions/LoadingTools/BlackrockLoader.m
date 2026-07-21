classdef BlackrockLoader < handle
% BlackrockLoader  Schema-checked loading and parsing of Blackrock behavior data.
%
% The recording for one session is split across files by role; the loader picks
% each file by its filename prefix and verifies the expected data is actually
% present before using it:
%   <CommentPrefix_primary>-*.nev  -> experiment comments + comment timing
%   <CommentPrefix_legacy>-*.nev   -> legacy fallback for comments
%   <SpikePrefix>-*.nev            -> online spike timing
%   <AnalogPrefix>-*.ns2           -> online analog (eye) data
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
%   loader.parseAnalog();      % -> loader.Analog
%   loader.parseSpikes();      % -> loader.Spike, loader.SpikeWaveformData
%   loader.prepareExport();    % -> loader.Export (trials table + expmeta lines)
%   loader.export(OutputPath, 'Blackrock_2026-06-24');   % writes the files
% Session state is cleared at the start of every load(), so one loader can be
% reused across a batch of folders without leaking data between them.
%
% Last updates of the comments --June 27th, 2026
% by Xuefei Yu

    properties
        % --- file schema (which file holds which data product) ---
        CommentPrefix_primary = 'NSP'    % NSP-*.nev: comments + comment timing
        CommentPrefix_legacy  = 'HUB'    % legacy fallback for comments
        SpikePrefix           = 'HUB'    % HUB-*.nev: online spike timing
        AnalogPrefix          = 'NSP'    % NSP-*.ns2: analog/eye data
        AnalogIdentifier      = '*.ns2'  % analog data extension

        % --- what to load ---
        LoadAnalogData        = false
        LoadOnlineSpikeData   = false
        LoadOnlineSpikeWaveform     = false    % opt-in: extract per-spike waveforms (uV);
                                         % requires LoadOnlineSpikeData; exported to its own .mat
        IncludeUnsorted       = false    % keep unit 0 (unsorted) + unit 255 (noise) spikes;
                                         % default false drops both before segmentation.
                                         % Source-agnostic: applies to online or offline spikes

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
        Loaded            % the S struct from loadSession (events, spikes, analog, statuses, flags)
        Trials            % struct array from parseEvents
        Experiment        % struct array from parseEvents
        Analog            % segmentAnalog output   ([] when analog not loaded)
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
        end



        function processFolder(obj, DataFolder, OutputPath, BaseName)
        % Run the whole pipeline for one date folder:
        %   load -> parseEvents -> parseAnalog -> parseSpikes -> prepareExport -> export
        % Exceptions propagate so a batch driver's per-folder try/catch can mark
        % just this folder failed and keep going.
            obj.load(DataFolder);
            obj.parseEvents();
            obj.parseAnalog();
            obj.parseSpikes();
            obj.prepareExport();
            obj.export(OutputPath, BaseName);
        end

        function load(obj, DataFolder)
        % Clear any previous session state, load one date folder's files into
        % obj.Loaded, and report which data products were actually loaded.
            obj.resetSession();
            obj.Loaded = obj.loadSession(DataFolder);

            S = obj.Loaded;
            fprintf('\n--- Loaded Blackrock data ---\n');
            fprintf('  Comments: %s\n', S.comments_source);
            fprintf('  Analog:   %s\n', S.analog_status);
            fprintf('  Spikes:   %s\n', S.spike_status);
            fprintf('-----------------------------\n');
        end
        

        function S = loadSession(obj, DataFolder)
        % Orchestrator: assemble one date folder's Blackrock products into the
        % session struct S by delegating to loadComments / loadAnalog /
        % loadSpikes. Throws ONLY when comments cannot be obtained (loadComments
        % throws uncaught, so the caller's per-folder try/catch fails just that
        % folder). Analog/spikes are gated by the load flags and fail soft:
        % their throws are caught here, recorded in a status string, and that
        % product is skipped.

            % defaults so every field exists on return
            S.Events           = [];
            S.EventTime        = [];
            S.comments_source  = '';
            S.online_spike     = BlackrockLoader.spikeContainer();  % generic raw-spike container
            S.spike_status     = 'not requested';
            S.nsxdata          = [];
            S.nsx_samplingrate = [];
            S.nsx_abs_time     = [];
            S.analog_status    = 'not requested';
            S.LoadAnalogData      = obj.LoadAnalogData;
            S.LoadOnlineSpikeData = obj.LoadOnlineSpikeData;
            S.LoadOnlineSpikeWaveform   = obj.LoadOnlineSpikeWaveform;
            S.IncludeUnsorted           = obj.IncludeUnsorted;
            S.timeresolution = [];

            % --- Comments + comment timing (required): throws if none found ---
            C = obj.loadComments(DataFolder);
            S.Events          = C.Events;
            S.EventTime       = C.EventTime;
            S.comments_source = C.comments_source;


            % --- Online analog / eye data (gated, soft failure) ---
            if S.LoadAnalogData
                try
                    % [] keeps obj.AnalogIdentifier; the prefix must be passed
                    % explicitly since loadAnalog defaults to match-any.
                    A = obj.loadAnalog(DataFolder, [], obj.AnalogPrefix);
                    S.nsxdata          = A.nsxdata;
                    S.nsx_samplingrate = A.nsx_samplingrate;
                    S.nsx_abs_time     = A.nsx_abs_time;
                    S.timeresolution   = A.timeresolution;
                    S.analog_status    = A.analog_status;
                catch ME_ana
                    S.LoadAnalogData = false;
                    S.analog_status = ['failed: ' ME_ana.message];
                    warning('%s', ['Analog loading ' S.analog_status]);
                end
            end

             % Waveforms reuse the online-spike products, so they need spikes on.
            if obj.LoadOnlineSpikeWaveform && ~S.LoadOnlineSpikeData
                warning(['LoadOnlineSpikeWaveform is on but LoadOnlineSpikeData is off; ' ...
                    'spike waveforms need online spikes and are skipped.']);
            end

             % --- Online spike timing (gated, soft failure) ---
            if S.LoadOnlineSpikeData
                try
                    R = obj.loadSpikes(DataFolder);
                    S.online_spike = R.online_spike;
                    S.spike_status = R.spike_status;
                catch ME_spk
                    S.LoadOnlineSpikeData = false;
                    S.spike_status = ['failed: ' ME_spk.message];
                    warning('%s', ['Spike loading ' S.spike_status]);
                end
            end
        end

          function C = loadComments(obj, DataFolder)
        % Load comment strings + their timing from one date folder (required
        % product). Resolves the .nev by role prefix: NSP primary, then HUB
        % (legacy recordings kept comments in the HUB file). Returns a struct
        % with .Events, .EventTime, .comments_source. Throws if neither file
        % carries comments -- comments are mandatory for downstream parsing.
        % Pure: opens only the .nev it needs, touches no session state.
            C.Events          = [];
            C.EventTime       = [];
            C.comments_source = '';

            nev_all = dir(fullfile(DataFolder, '*.nev'));
            nsp_nev = BlackrockLoader.pickByPrefix(nev_all, obj.CommentPrefix_primary);  % '' if none
            hub_nev = BlackrockLoader.pickByPrefix(nev_all, obj.CommentPrefix_legacy);   % '' if none

            if ~isempty(nsp_nev)
                nsp_data = openNEV(fullfile(DataFolder, nsp_nev), 'report', 'nosave');
                if BlackrockLoader.hasComments(nsp_data)
                    C.Events          = nsp_data.Data.Comments.Text;
                    C.EventTime       = nsp_data.Data.Comments.TimeStampSec;
                    C.comments_source = nsp_nev;
                end
            end
            if isempty(C.comments_source) && ~isempty(hub_nev)
                hub_data = openNEV(fullfile(DataFolder, hub_nev), 'report', 'nosave');
                if BlackrockLoader.hasComments(hub_data)
                    C.Events          = hub_data.Data.Comments.Text;
                    C.EventTime       = hub_data.Data.Comments.TimeStampSec;
                    C.comments_source = hub_nev;   % legacy: comments live in the HUB file
                end
            end
            if isempty(C.comments_source)
                error('No comments found in %s-*.nev or %s-*.nev under: %s', ...
                    obj.CommentPrefix_primary, obj.CommentPrefix_legacy, DataFolder);
            end
        end

        function A = loadAnalog(obj, DataFolder, postFix, preFix)
        % Load analog / eye data for one date folder. Returns a struct with
        % .nsxdata (uV), .nsx_samplingrate, .nsx_abs_time, .timeresolution, and
        % .analog_status. Throws if no matching analog file is present or if the
        % user cancels the multi-file selection dialog; the orchestrator
        % (loadSession) turns such throws into a soft status string.
        % Pure: opens only the .nsx it needs, touches no session state.
        %
        % Both overrides apply to this call only and leave the config properties
        % untouched:
        %   postFix -- file extension. Accepts '.ns6', 'ns6' or '*.ns6'.
        %              Omitted/empty -> obj.AnalogIdentifier ('*.ns2').
        %              Note .ns6 is 30 kHz broadband, ~30x the samples of a .ns2.
        %   preFix  -- filename prefix, e.g. 'NSP' or 'Hub1'. Omitted/empty ->
        %              no prefix filter, i.e. any file with that extension
        %              (several matches raise the selection dialog).
        %              loadSession always passes obj.AnalogPrefix, so the
        %              pipeline stays prefix-pinned.
        %
        %   loadAnalog(f)                  % '*.ns2', any prefix
        %   loadAnalog(f, '.ns6')          % '*.ns6', any prefix
        %   loadAnalog(f, '.ns6', 'NSP')   % '*.ns6', NSP only
        %   loadAnalog(f, [], 'Hub1')      % '*.ns2', Hub1 only
            if nargin < 3 || isempty(postFix)
                ident = obj.AnalogIdentifier;
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
            A.nsx_samplingrate = [];
            A.nsx_abs_time     = [];
            A.timeresolution   = [];
            A.analog_status    = '';

            % No prefix -> take every match; filterByPrefix cannot express
            % match-any (its '^' regex returns a zero-length match, which reads
            % as "no match" and would drop everything).
            ns_list = dir(fullfile(DataFolder, ident));
            if ~isempty(preFix)
                ns_list = BlackrockLoader.filterByPrefix(ns_list, preFix);
            end
            if isempty(ns_list)
                if isempty(preFix); prefix_desc = 'any-prefix'; else; prefix_desc = preFix; end
                error('No %s %s analog file found.', prefix_desc, ident);
            end
            ns_names = {ns_list.name};
            if numel(ns_names) > 1
                [sel, ok] = listdlg('PromptString', ...
                    sprintf('Select eye (%s) file to load (Cancel = skip):', ident), ...
                    'SelectionMode', 'single', 'ListString', ns_names, 'ListSize', [400 200]);
                if ~ok
                    error('Analog file selection cancelled by user.');
                end
                Filename_ns = ns_names{sel};
            else
                Filename_ns = ns_names{1};
            end

            tmp_ana_data = openNSx(fullfile(DataFolder, Filename_ns), 'read', 'report', 'uv');
            A.nsxdata          = tmp_ana_data.Data;                       % in uV
            nsx_starttime      = tmp_ana_data.MetaTags.Timestamp;
            nsx_timeresolution = tmp_ana_data.MetaTags.TimeRes;
            A.nsx_samplingrate = tmp_ana_data.MetaTags.SamplingFreq;
            nsx_starttimeSec   = nsx_starttime / nsx_timeresolution;
            N = length(A.nsxdata);
            nsx_rel_time       = (0:N-1) / A.nsx_samplingrate;            % from start time
            A.nsx_abs_time     = nsx_starttimeSec + nsx_rel_time;
            A.timeresolution   = nsx_timeresolution;
            A.analog_status    = sprintf('ok (%s)', Filename_ns);
        end

        function R = loadSpikes(obj, DataFolder)
        % Load online spike timing (+ optional waveforms) for one date folder.
        % Opens the HUB-*.nev itself and converts timestamps to seconds using the
        % NEV's OWN clock (MetaTags.TimeRes; falls back to 1e9 if absent), so the
        % result is independent of whether analog was loaded. Drops unsorted
        % (unit 0) / noise (unit 255) spikes unless IncludeUnsorted is set.
        % Returns a struct with .online_spike (the generic spike container) and
        % .spike_status. Throws if no HUB file or no spike timestamps are present.
        % Pure: opens only the .nev it needs, touches no session state.
            R.online_spike = BlackrockLoader.spikeContainer();
            R.spike_status = '';

            nev_all = dir(fullfile(DataFolder, '*.nev'));
            hub_nev = BlackrockLoader.pickByPrefix(nev_all, obj.CommentPrefix_legacy);   % '' if none
            if isempty(hub_nev)
                error('No %s-*.nev file for online spikes.', obj.SpikePrefix);
            end
            hub_data = openNEV(fullfile(DataFolder, hub_nev), 'report', 'nosave');
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
            spikeTimeSec  = double(hub_data.Data.Spikes.TimeStamp)/timeRes;
            % keep channel identity for per-trial rasterization
            spikeChannel  = hub_data.Data.Spikes.Electrode;
            spikeUnit     = hub_data.Data.Spikes.Unit;
            spikeWaveform = [];   % stays empty unless waveforms are requested

            % Optional per-spike waveforms (opt-in via LoadOnlineSpikeWaveform),
            % converted to uV. openNEV returns Waveform as [nSamp x nSpikes]
            % int16 with columns aligned 1:1 to TimeStamp/Electrode/Unit. We scale
            % here (rather than passing 'uv' to openNEV) so the conversion is
            % independent of how hub_data was opened. This mirrors openNEV's 'uv'
            % path exactly: wf_uV = raw .* DigitalFactor(electrode) / 1000.
            if obj.LoadOnlineSpikeWaveform && isfield(hub_data.Data.Spikes, 'Waveform') ...
                    && ~isempty(hub_data.Data.Spikes.Waveform)
                rawWf   = double(hub_data.Data.Spikes.Waveform);            % [nSamp x nSpikes]
                elecIdx = double(hub_data.Data.Spikes.Electrode);
                digi    = double([hub_data.ElectrodesInfo(elecIdx).DigitalFactor]); % 1 x nSpikes
                spikeWaveform = bsxfun(@times, rawWf, digi/1000);          % uV
            end

            % Drop unsorted (unit 0) and noise (unit 255) spikes unless opted in.
            % time/channel/unit are 1 x nSpikes; waveform is nSamp x nSpikes
            % with columns aligned 1:1 -- filter all together so they stay aligned.
            if ~obj.IncludeUnsorted
                keep = ~ismember(double(spikeUnit), [0 255]);
                nDropped = sum(~keep);
                spikeTimeSec = spikeTimeSec(keep);
                spikeChannel = spikeChannel(keep);
                spikeUnit    = spikeUnit(keep);
                if ~isempty(spikeWaveform)
                    spikeWaveform = spikeWaveform(:, keep);
                end
                R.spike_status = sprintf('ok (%s; dropped %d unsorted/noise spikes)', hub_nev, nDropped);
            else
                R.spike_status = sprintf('ok (%s)', hub_nev);
            end

            % Pack into the generic, source-agnostic container that
            % parseSpikes/segmentSpikes then rasterize per trial.
            R.online_spike.TimeSec  = spikeTimeSec;
            R.online_spike.Channel  = spikeChannel;
            R.online_spike.Unit     = spikeUnit;
            R.online_spike.Waveform = spikeWaveform;
            if ~isempty(spikeWaveform)
                R.online_spike.WaveformUnit = 'microVolts';
            end
            R.online_spike.source = 'online';
        end


        function [trials, experiment] = parseEvents(obj, Events, EventTime)
        % Single pass over the .nev comment strings, building one experiment
        % entry per session and one trials entry per (position-keyed) trial.
        % A single .nev can hold several sessions (task started/stopped), so
        % experiment is a struct array indexed by session_index; trials are
        % keyed by position so a resetting trial counter starts new trials.
        %
        % Called with no data args it reads obj.Loaded (the stateful pipeline);
        % pass Events/EventTime explicitly to parse an arbitrary comment set.
        % Either way the result is stored in obj.Trials / obj.Experiment AND
        % returned.
            if nargin < 2
                Events    = obj.Loaded.Events;
                EventTime = obj.Loaded.EventTime;
            end

            exp_template       = obj.ExpTemplate;
            trial              = obj.TrialTemplate;
            exp_events         = obj.EventMaps.ExpEvents;
            time_events        = obj.EventMaps.TimeEvents;
            segment_events     = obj.EventMaps.SegmentEvents;
            information_events = obj.EventMaps.InformationEvents;
            dash_events        = obj.EventMaps.DashEvents;
            outcome_events     = obj.EventMaps.OutcomeEvents;

            experiment    = exp_template([]);   % empty struct array, grows per session
            trials        = trial([]);          % empty struct array, grows per trial
            session_index = 0;
            trial_index   = 0;
            prev_trial_number = NaN;
            prev_session      = NaN;

            EventsNumber = size(Events, 1);
            for i = 1:EventsNumber
                curr_event = Events(i, :);
                curr_eventtime = EventTime(i);
                %First check if it is an experimental setup
                exp_pattern = '^Experiment (start|end):\s*(.+)$';
                exp_flag = regexp(curr_event, exp_pattern, 'tokens');
                if ~isempty(exp_flag)
                    %Get the experiment meta data
                    exp_marker = exp_flag{1}{1}; %start or end
                    exp_token  = strtrim(exp_flag{1}{2});

                    %A new session begins at each "Experiment start: git commit ..." line
                    %(the first line of every metadata block within the recording).
                    if strcmp(exp_marker,'start') && startsWith(exp_token,'git commit')
                        session_index = session_index + 1;
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
                                exp_event_keys = keys(exp_events);
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
                     mainTokens = regexp(curr_event, '^Trial\s+(\d+):\s*(.*)$', 'tokens');
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
                    if isempty(trials)
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
                            currTrial = trial;
                            currTrial.Trial_number = TrialNum_curr;
                            currTrial.Session = session_index;
                            trials(trial_index) = currTrial;
                        end
                        prev_trial_number = TrialNum_curr;
                        prev_session = session_index;
                    end

                   %go through each type of events
                   time_flag = contains(event_text, keys(time_events));
                   info_flag = contains(event_text, keys(information_events));
                   seg_flag = contains(event_text, keys(segment_events));
                   dash_flag = contains(event_text, dash_events) & contains(event_text, '-');
                   outcome_flag = contains(event_text, outcome_events);
                   offset_range_flag = contains(event_text, 'Requested time offset range');


                   if time_flag
                     %Directly assign current time
                     time_event_keys = keys(time_events);
                     flag_array = contains(time_event_keys,event_text);
                     curr_key = time_event_keys{flag_array};
                     field = time_events(curr_key);

                     if isnan(trials(trial_index).(field))
                         %First check whether it's already assigned
                        trials(trial_index).(field) = curr_eventtime;
                     else
                         %Otherwise, put it into the duplicates for further debug
                          trials(trial_index).duplicates(end+1,1) = event_text;
                          disp('Duplicate found for time event:');
                          disp(event_text);

                     end




                   elseif info_flag
                       %Extract values following the event
                       coord_pattern = '^(.*?)\s*\(\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\)\s*deg$';
                       reward_pattern = '^(.*?)\s*\(([\d\.]+)ms';
                       time_pattern = '^(.*?)\s+([-+]?\d*\.?\d+|None|none)\s*ms$';
                       size_pattern = '^(.*?)\s+([-+]?\d*\.?\d+)\s*(?:deg)?$';


                       coor_tokens = regexp(event_text, coord_pattern, 'tokens');
                       reward_tokens = regexp(event_text, reward_pattern, 'tokens');


                       if ~isempty(coor_tokens)
                           %Get the event and coordinate/reward amount
                           event_coord = strtrim(coor_tokens{1}{1});
                           coord = cellfun(@str2double, coor_tokens{1}(2:end));

                           info_event_keys = keys(information_events);
                           flag_array = contains(info_event_keys,event_coord);
                           curr_key = info_event_keys{flag_array};
                           field = information_events(curr_key);
                           if all(isnan(trials(trial_index).(field)))
                               %If it is empty
                               trials(trial_index).(field) = coord;
                           else
                               trials(trial_index).duplicates(end+1,1) = event_coord;
                                disp('Duplicate found for coor event:');
                                disp(event_coord);

                           end


                       elseif ~isempty(reward_tokens)
                           event_reward = strtrim(reward_tokens{1}{1});
                           reward_amount = cellfun(@str2double, reward_tokens{1}(2:end));

                           info_event_keys = keys(information_events);
                           flag_array = contains(info_event_keys,event_reward);
                           curr_key = info_event_keys{flag_array};
                           field = information_events(curr_key);
                           if isnan(trials(trial_index).(field) )
                               trials(trial_index).(field) = curr_eventtime;
                           else
                               trials(trial_index).duplicates(end+1,1) = field;
                               disp('Duplicate found for reward event:');
                                disp(event_reward);
                           end

                           if isnan(trials(trial_index).Reward_amount)
                                trials(trial_index).Reward_amount = reward_amount;
                           else
                               trials(trial_index).duplicates(end+1,1) = 'Reward_amount';
                               disp('Duplicate found for reward amount');

                           end




                       else
                           combined_pattern = [ time_pattern, '|', size_pattern];
                           tokens = regexp(event_text, combined_pattern, 'tokens');
                           %Get the event and duration

                           event_dur = strtrim(tokens{1}{1});
                           dur = str2double(tokens{1}{2});


                           info_event_keys = keys(information_events);
                           flag_array = contains(info_event_keys,event_dur);
                           curr_key = info_event_keys{flag_array};
                           field = information_events(curr_key);


                           if isnan(trials(trial_index).(field))
                                trials(trial_index).(field) = dur;
                           else
                               trials(trial_index).duplicates(end+1,1) = field;
                                disp('Duplicate found for duration/size event:');
                                disp(event_dur);

                           end

                       end



                   elseif seg_flag
                       %segment the text by the last space

                       last_space_idx = find(event_text == ' ', 1, 'last');
                       event_name = strtrim(event_text(1:last_space_idx-1));
                       value = strtrim(event_text(last_space_idx+1:end));

                       segment_event_keys = keys(segment_events);
                       flag_array = contains(segment_event_keys,event_name);
                       curr_key = segment_event_keys{flag_array};
                       field = segment_events(curr_key);

                       if isnan(trials(trial_index).(field))
                          trials(trial_index).(field) = value;
                       else
                           trials(trial_index).duplicates(end+1,1) = field;
                           disp('Duplicate found for segment event:');
                           disp(field);

                       end

                   elseif dash_flag
                       %segment the text by the dash
                       dash_idx = find(event_text == '-', 1, 'first');
                       event   = strtrim(event_text(1:dash_idx-1));
                       outcome = strtrim(event_text(dash_idx+1:end));
                       if contains(event,'End')



                           if isnan(trials(trial_index).End)
                               trials(trial_index).End = curr_eventtime;
                           else
                               trials(trial_index).duplicates(end+1,1) = event;
                                disp('Duplicate End  found for dash event:');
                                disp(event);

                           end

                           if isnan(trials(trial_index).Trialoutcome)
                                trials(trial_index).Trialoutcome = outcome;
                           else
                               trials(trial_index).duplicates(end+1,1) ='Trialoutcome';
                                disp('Duplicate outcome found for dash event:');
                                disp(event);

                           end
                       elseif contains(event,'choice')
                           if isnan(trials(trial_index).Choosen_choice)
                                trials(trial_index).Choosen_choice = outcome;
                           else
                               trials(trial_index).duplicates(end+1,1) ='Choosen_choice';
                                disp('Duplicate found for dash event:');
                                disp(event);

                           end
                       else
                           disp('Undefined dash event:');
                           disp(event_text);
                           disp('Check the undefined var');
                           trials(trial_index).undefined(end+1,1) = string(event_text);
                       end

                   elseif outcome_flag
                       %Save the choice outcome and time
                       if isnan(trials(trial_index).Choiceoutcome)
                            trials(trial_index).Choiceoutcome = event_text;
                       else
                           trials(trial_index).duplicates(end+1,1) ='Choiceoutcome';
                                disp('Duplicate found for outcome event:');
                                disp(event_text);

                       end
                       %{
                       if isnan(trials(trial_index).Choicetime )
                            trials(trial_index).Choicetime = curr_eventtime;
                       else
                            trials(trial_index).duplicates(end+1,1) ='Choicetime';
                                disp('Duplicate found for outcome event:');
                                disp('Choicetime');

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
                       disp('Undefined event detected:');
                       disp(event_text);
                       disp('Check the undefined var');
                       trials(trial_index).undefined(end+1,1) = string(event_text);

                   end



                   if trials(trial_index).Start > 0
                       trials(trial_index).Save_complete = 1;

                   end

                end %End of if the judgement of if it is experiment flag or trial flag

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

            obj.Trials     = trials;
            obj.Experiment = experiment;
        end

        function A = parseAnalog(obj)
        % Segment the loaded analog stream into per-trial slices, stored in
        % obj.Analog. When analog was not loaded, obj.Analog is [].
            if isempty(obj.Loaded) || ~obj.Loaded.LoadAnalogData
                obj.Analog = [];
            else
                S = obj.Loaded;
                obj.Analog = BlackrockLoader.segmentAnalog(obj.Trials, S.nsxdata, ...
                    S.nsx_abs_time, S.nsx_samplingrate, ...
                    obj.Segment_PreBuffer, obj.Segment_PostBuffer);
            end
            A = obj.Analog;
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
                obj.Spike = BlackrockLoader.segmentSpikes(obj.Trials, S.TimeSec, ...
                    S.Channel, S.Unit, ...
                    obj.Segment_PreBuffer, obj.Segment_PostBuffer, obj.Segment_BinWidth, ...
                    obj.Spike_ISIViolationMs);
            end
            if L.LoadOnlineSpikeWaveform && ~isempty(S.Waveform)
                obj.SpikeWaveformData = BlackrockLoader.segmentSpikeWaveforms(obj.Trials, ...
                    S.TimeSec, S.Channel, S.Unit, S.Waveform, ...
                    obj.Segment_PreBuffer, obj.Segment_PostBuffer);
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
        %   <BaseName>_analog_matlab.mat           (if analog was segmented)
        %   <BaseName>_spikes_matlab.mat           (if spikes were segmented)
        %   <BaseName>_spikes_waveform_matlab.mat  (if waveforms were segmented)
            if ~exist(OutputPath, 'dir')
                mkdir(OutputPath);
            end
            src = obj.Loaded.comments_source;

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

            % Analog (.mat) - only when segmented
            if ~isempty(obj.Analog)
                analog = obj.Analog; %#ok<NASGU>
                fname_analog = [BaseName '_analog_matlab.mat'];
                save(fullfile(OutputPath, fname_analog), 'analog');
                fprintf('File:%s Analog segmented (%d trials) into %s\n', ...
                    src, size(obj.Analog.data, 2), fname_analog);
            end

            % Spikes (.mat) - only when segmented
            if ~isempty(obj.Spike)
                online_spike = obj.Spike; %#ok<NASGU>
                fname_spikes = [BaseName '_spikes_matlab.mat'];
                save(fullfile(OutputPath, fname_spikes), 'online_spike');
                fprintf('File:%s Spikes rasterized (%d units x %d trials) into %s\n', ...
                    src, size(obj.Spike.data, 1), size(obj.Spike.data, 2), fname_spikes);
            end

            % Spike waveforms (.mat, -v7.3) - only when segmented. The dense 4-D
            % array can exceed the 2 GB per-variable cap of the default format.
            if ~isempty(obj.SpikeWaveformData)
                online_spike_waveform = obj.SpikeWaveformData; %#ok<NASGU>
                fname_wf = [BaseName '_spikes_waveform_matlab.mat'];
                save(fullfile(OutputPath, fname_wf), 'online_spike_waveform', '-v7.3');
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
            obj.Analog            = [];
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
                'TimeSec',      [], ...   % spike times (s, recording clock); 1 x nSpikes
                'Channel',      [], ...   % electrode per spike; 1 x nSpikes
                'Unit',         [], ...   % unit id per spike;   1 x nSpikes
                'Waveform',     [], ...   % [nSamp x nSpikes] uV, or [] when none
                'WaveformUnit', '', ...   % e.g. 'microVolts' (label for Waveform)
                'source',       '');      % provenance: 'online' | 'offline'
        end

        function A = segmentAnalog(trials, nsxdata, nsx_abs_time, nsx_samplingrate, preMs, postMs)
        % Cut the continuous analog stream into one slice per trial.
        % For each trial the window is [Start - preMs, End + postMs] (ms buffers),
        % matched against nsx_abs_time (seconds, same NSP clock as the event
        % timestamps). Slices are left-aligned (each starts at its own window
        % start) and NaN-padded to the longest trial, so the result is one
        % chan x nTrials x maxSamples array that lines up 1:1 with trials.
        % A trial whose Start/End is NaN (or that has no samples in range) gets
        % an all-NaN slice so the 3rd dimension stays index-aligned with trials.
            if nargin < 5 || isempty(preMs);  preMs  = 500; end   % default buffer (ms)
            if nargin < 6 || isempty(postMs); postMs = 500; end

            pre  = preMs  / 1000;   % seconds
            post = postMs / 1000;

            nChan   = size(nsxdata, 1);
            nTrials = numel(trials);

            % --- first pass: find each trial's sample window ---
            idx          = cell(nTrials, 1);
            n            = zeros(nTrials, 1);
            rawstarttime = nan(nTrials, 1);
            for i = 1:nTrials
                if isnan(trials(i).Start) || isnan(trials(i).End)
                    continue   % missing marker -> all-NaN slice
                end
                t0 = trials(i).Start - pre;
                t1 = trials(i).End   + post;
                w  = find(nsx_abs_time >= t0 & nsx_abs_time <= t1);
                if isempty(w)
                    continue
                end
                idx{i}          = w;
                n(i)            = numel(w);
                rawstarttime(i) = trials(i).Start;      % abs time of the Start marker (s)
            end

            % --- second pass: stack into NaN-padded 3-D array (left-aligned) ---
            % built chan x maxSamples x nTrials, then permuted to chan x nTrials x maxSamples
            maxSamples = max([n; 0]);
            data = nan(nChan, maxSamples, nTrials);
            for i = 1:nTrials
                if n(i) > 0
                    data(:, 1:n(i), i) = nsxdata(:, idx{i});
                end
            end
            data = permute(data, [1 3 2]);   % -> chan x nTrials x maxSamples

            % reltime: 0 at the Start marker, negative through the pre-buffer
            reltime = ((0:maxSamples-1) / nsx_samplingrate) - pre;

            A = struct();
            A.data    = data;       % chan x nTrials x maxSamples, NaN-padded
            A.timeseq.alignedrawtime = rawstarttime;  % nTrials x 1, abs time of the Start marker (s)
            A.timeseq.aligned_marker = 'Start';        % event that relative_time=0 is aligned to
            A.timeseq.relative_time  = reltime;        % 1 x maxSamples, seconds from the aligned marker
            A.info.samplingrate = nsx_samplingrate;
            A.info.Session      = [trials.Session]';        % nTrials x 1
            A.info.Trial_number = [trials.Trial_number]';   % nTrials x 1
        end

        function R = segmentSpikes(trials, spikeTimes, spikeElectrode, spikeUnit, preMs, postMs, binMs, violMs)
        % Rasterize online spikes into one binary slice per trial.
        % For each trial the window is [Start - preMs, End + postMs] (ms buffers),
        % matched against spikeTimes (seconds, NSP/HUB clock). Time is binned at
        % binMs (default 1 ms); a bin is 1 if any spike of that row falls in it,
        % 0 otherwise. Slices are left-aligned (bin 1 at the window start) and
        % NaN-padded to the longest trial, giving one NtotalUnit x nTrials x maxBins
        % array that lines up 1:1 with trials (same layout as segmentAnalog).
        % Rows are one per (electrode, unit) pair, so NtotalUnit is the total
        % isolated units summed across channels (a channel with 2 units -> 2 rows);
        % info.Channel_Number / info.Unit_No record the IDs per row.
        % info.ViolationRate carries each unit's overall ISI-violation rate
        % (fraction of ISIs < violMs, default 1 ms) over its full continuous spike
        % train -- a timing-only QC metric that needs no waveform product.
        % A trial whose Start/End is NaN gets an all-NaN slice so the trial
        % dimension stays index-aligned with trials.
        % (Per-spike waveforms are a separate product: see segmentSpikeWaveforms.)
            if nargin < 5 || isempty(preMs);  preMs  = 500; end   % default buffer (ms)
            if nargin < 6 || isempty(postMs); postMs = 500; end
            if nargin < 7 || isempty(binMs);  binMs  = 1;   end   % bin width (ms)
            if nargin < 8 || isempty(violMs); violMs = 1;   end   % ISI-violation window (ms)

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
            violSec  = violMs / 1000;
            violRate = nan(nChan, 1);
            for r = 1:nChan
                tr = sort(spikeTimes(spikeRow == r));
                if numel(tr) >= 2
                    violRate(r) = mean(diff(tr) < violSec);
                end
            end

            nTrials = numel(trials);

            % --- first pass: find each trial's bin count and window ---
            nBins        = zeros(nTrials, 1);
            t_start      = nan(nTrials, 1);
            t_end        = nan(nTrials, 1);
            rawstarttime = nan(nTrials, 1);
            for i = 1:nTrials
                if isnan(trials(i).Start) || isnan(trials(i).End)
                    continue   % missing marker -> all-NaN slice
                end
                t0 = trials(i).Start - pre;
                t1 = trials(i).End   + post;
                nBins(i)        = max(round((t1 - t0) / binSec), 0);
                t_start(i)      = t0;
                t_end(i)        = t1;
                rawstarttime(i) = trials(i).Start;   % abs time of the Start marker (s)
            end

            % --- second pass: fill NaN-padded binary raster (left-aligned) ---
            maxBins = max([nBins; 0]);
            raster  = nan(nChan, maxBins, nTrials);
            for i = 1:nTrials
                if nBins(i) <= 0
                    continue
                end
                t0 = t_start(i);
                t1 = t_end(i);
                raster(:, 1:nBins(i), i) = 0;   % within-window bins start at 0
                sel = spikeTimes >= t0 & spikeTimes < t1;
                if ~any(sel)
                    continue
                end
                bins = floor((spikeTimes(sel) - t0) / binSec) + 1;
                bins = min(bins, nBins(i));     % guard the right edge
                rows = spikeRow(sel);
                lin  = sub2ind([nChan, nBins(i)], rows, bins);
                slice = raster(:, 1:nBins(i), i);
                slice(lin) = 1;                 % binary: spike present (clamped)
                raster(:, 1:nBins(i), i) = slice;
            end
            % NtotalUnit x nTrials x maxBins (one row per channel x unit)
            raster = permute(raster, [1 3 2]);

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
        end

        function W = segmentSpikeWaveforms(trials, spikeTimes, spikeElectrode, spikeUnit, spikeWaveform, preMs, postMs)
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
            if nargin < 6 || isempty(preMs);  preMs  = 500; end   % default buffer (ms)
            if nargin < 7 || isempty(postMs); postMs = 500; end

            pre  = preMs  / 1000;   % seconds
            post = postMs / 1000;

            spikeTimes     = double(spikeTimes(:));
            spikeElectrode = double(spikeElectrode(:));
            spikeUnit      = double(spikeUnit(:));
            nSamp = size(spikeWaveform, 1);   % [nSamp x nSpikes]

            % --- channel list: one row per (electrode, unit), sorted (matches segmentSpikes) ---
            chanKeys  = unique([spikeElectrode, spikeUnit], 'rows');
            electrode = chanKeys(:, 1);
            unit      = chanKeys(:, 2);
            nChan     = size(chanKeys, 1);
            [~, spikeRow] = ismember([spikeElectrode, spikeUnit], chanKeys, 'rows');

            nTrials = numel(trials);

            % --- first pass: window per trial + busiest (unit,trial) spike count ---
            t_start      = nan(nTrials, 1);
            t_end        = nan(nTrials, 1);
            rawstarttime = nan(nTrials, 1);
            maxSpk       = 0;
            for i = 1:nTrials
                if isnan(trials(i).Start) || isnan(trials(i).End)
                    continue   % missing marker -> all-NaN slice
                end
                t_start(i)      = trials(i).Start - pre;
                t_end(i)        = trials(i).End   + post;
                rawstarttime(i) = trials(i).Start;   % abs time of the Start marker (s)
                sel = spikeTimes >= t_start(i) & spikeTimes < t_end(i);
                if any(sel)
                    maxSpk = max(maxSpk, max(accumarray(spikeRow(sel), 1, [nChan 1])));
                end
            end

            % --- allocate (warn first if the dense array is large) ---
            if nChan*nTrials*maxSpk*nSamp*8 > 2e9
                warning(['segmentSpikeWaveforms: waveform array is %.1f GB ' ...
                    '(%d units x %d trials x %d spikes x %d samples). ' ...
                    'Consider narrowing the data (fewer/sorted units or trials).'], ...
                    nChan*nTrials*maxSpk*nSamp*8/1e9, nChan, nTrials, maxSpk, nSamp);
            end
            wf      = nan(nChan, nTrials, maxSpk, nSamp);   % uV, NaN-padded
            wf_time = nan(nChan, nTrials, maxSpk);          % s, relative to Start

            % --- second pass: each in-window spike -> position 1..k per (row, trial) ---
            for i = 1:nTrials
                if isnan(t_start(i))
                    continue
                end
                sel = spikeTimes >= t_start(i) & spikeTimes < t_end(i);
                if ~any(sel)
                    continue
                end
                selIdx = find(sel);            % original spike indices, in time order
                rws    = spikeRow(selIdx);
                cnt    = zeros(nChan, 1);       % running per-row position within this trial
                for j = 1:numel(selIdx)
                    r = rws(j);
                    cnt(r) = cnt(r) + 1;
                    wf(r, i, cnt(r), :)   = spikeWaveform(:, selIdx(j));
                    wf_time(r, i, cnt(r)) = spikeTimes(selIdx(j)) - rawstarttime(i);
                end
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
