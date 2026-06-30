# Data loader and analyzer for JLab

### Keeps updating by Xuefei Yu, from Mar 6th, 2026

MATLAB-based data analysis toolkit for both cage trainer and data recorded using BlackRock hardware.

## Prerequisites

### 1. MATLAB Path (handled automatically)

`BackRockFileLoader.m` sets up its own path on startup, in two steps:

1. **JLab code** — adds the repo root (for the top-level scripts) and the
   `ToolsAndFunctions` tree (the `BlackrockLoader` class + analyze tools). The
   repo root is *not* added recursively, so dot-folders at the root (`.git`,
   `.claude`, …) are never placed on the MATLAB path.
2. **NPMK** — if `openNEV` is already found (e.g. NPMK lives under
   `ToolsAndFunctions/NPMK`), nothing more happens. Otherwise the script prompts
   you to select your NPMK folder and adds it; cancelling aborts with an
   install hint.

So no manual `addpath` is needed on a fresh clone, wherever you put the repo.

If you prefer to set the path yourself (or run the other scripts directly), you
can still add the folder manually in MATLAB:
**Home → Set Path → Add with Subfolders** → select the JLab folder → Save.

### 2. Install BlackRock NPMK Toolkit

This repository requires the **BlackRock Neurotech NPMK (Neural Processing MATLAB Kit)** toolkit to load `.ns2`, `.nev`, and other BlackRock file formats.

Download it from the official GitHub repository:
👉 https://github.com/BlackrockNeurotech/NPMK

**Installation steps:**
1. Download or clone the NPMK repository.
2. Move the downloaded NPMK folder into this repo's **`ToolsAndFunctions`** folder, so
   it lives at `JLab/ToolsAndFunctions/NPMK`. The loader's auto-path step (above)
   then picks it up automatically — no manual `addpath` is needed.

If you would rather keep NPMK somewhere else, add it to the path yourself instead:
```matlab
addpath(genpath('/path/to/NPMK'))
savepath
```

> ⚠️ Without NPMK, BlackRock data files cannot be loaded and the scripts will not run.
> NPMK is third-party and **gitignored** — it is not shipped with this repo. The
> loader depends on its `openNEV`, `openNSx`, and `ts2sec` functions.

## File Structure

```
JLab/
├── BackRockFileLoader.m         # driver: sets config, runs the batch loop, exports CSV/txt
├── BlackRockFileAnalyzer.m      # reads trials CSV, fits/plots the psychometric curve
├── CageTrianingDataLoading.m    # concatenates cage-trainer .json trials into one CSV
├── CageTrainingDataAnalyzer.m   # reads that CSV, plots the psychometric curve
└── ToolsAndFunctions/
    ├── LoadingTools/
    │   └── BlackrockLoader.m         # class: schema-checked load + comment parsing
    ├── AnalyzeTools/
    │   └── VisPsychometricFunction.m # shared logistic-regression psychometric fit
    └── NPMK/                         # BlackRock NPMK toolkit (third-party, gitignored)
```

> Note the filename typo `BackRockFileLoader` (vs. "BlackRock" everywhere else)
> — run it exactly as named.

## Usage

1. Complete all steps in **Prerequisites**
2. Open MATLAB and navigate to the JLab folder
3. Run the loader, then the analyzer:
   - first the loader: ```BackRockFileLoader``` to parse the raw data into CSV/txt
   - then the analyzer: ```BlackRockFileAnalyzer``` for the psychometric curve

`BackRockFileLoader.m` is a thin **driver script**: it sets the run config,
constructs a `BlackrockLoader`, and loops over date folders. All loading and
parsing logic lives in the class (`ToolsAndFunctions/LoadingTools/BlackrockLoader.m`).

## How the BlackRock loader works

Loading and parsing are handled by the **`BlackrockLoader`** class. It is a
config-property class: its public properties hold the file schema, the load
flags, and the parsing schema (templates + event maps). Construct it with
name/value overrides, then drive it once per date folder:

```matlab
loader = BlackrockLoader('LoadAnalogData', true, ...        % override any property
                         'LoadOnlineSpikeData', true, ...
                         'LoadOnlineSpikeWaveform', false, ...  % opt-in spike waveforms (default off)
                         'IncludeUnsorted', false);         % keep unit 0/255 spikes (default off)
S                    = loader.loadSession(DataFolder);     % resolve + load files
[trials, experiment] = loader.parseEvents(S.Events, S.EventTime);  % comments -> records
```

### Input file schema (role-aware resolution)

A single recording is split across files **by filename prefix**, and each data
product is verified present before use:

| File                | Role                                              |
|---------------------|---------------------------------------------------|
| `NSP-*.nev`         | experiment comments + comment timing              |
| `HUB-*.nev`         | online spike timing (+ per-spike waveforms)       |
| `NSP-*.ns2`         | analog / eye data                                 |

- **Comments are required.** If `NSP-*.nev` is missing, comments **fall back to
  `HUB-*.nev`** (legacy recordings wrote comments there). If neither has them,
  that folder errors and is reported as `failed`.
- **Spikes and analog are soft.** A missing or unreadable spike/analog file is
  recorded in a status string and that product is skipped — the folder still
  succeeds. The prefixes (`NSP`/`HUB`), the `.ns2` identifier, and the
  `LoadAnalogData` / `LoadOnlineSpikeData` / `LoadOnlineSpikeWaveform` /
  `IncludeUnsorted` flags are all constructor-overridable properties.
- **Online spikes** come from `HUB-*.nev` when `LoadOnlineSpikeData` is on:
  `loadSession` reads each spike's time (s), electrode, and unit. By default
  unit `0` (unsorted) and unit `255` (noise) spikes are **dropped** after load
  (with their channel/unit/waveform columns), so downstream segmentation only
  sees sorted units; set `IncludeUnsorted` (default off) true to keep them. The
  flag is source-agnostic — the same drop applies to a future offline spike
  source feeding the same pipeline.
- **Spike waveforms** are an **opt-in extra** (`LoadOnlineSpikeWaveform`,
  default off). They live in the same `HUB-*.nev`, so they only load when
  `LoadOnlineSpikeData` is also on; if waveforms are requested without spikes,
  `loadSession` warns and skips them. Each waveform is converted to **µV**
  per-electrode (mirroring openNEV's `'uv'`). The naming distinguishes these
  *online* (Central-sorted, recorded live) waveforms from offline-sorted
  waveforms added later.

`loadSession` returns a struct `S` with:
- comments: `Events`, `EventTime`, `comments_source`;
- spikes (`LoadOnlineSpikeData`): `S.online_spike`, a generic **source-agnostic
  container** (from `BlackrockLoader.spikeContainer()`) with `TimeSec`,
  `Channel`, `Unit`, `Waveform` (`[nSamp × nSpikes]` µV, or `[]`; populated only
  when `LoadOnlineSpikeWaveform` is on), `WaveformUnit`, and `source`
  (`'online'`). All per-spike arrays are aligned 1:1. Plus `spike_status`;
- analog (`LoadAnalogData`): `nsxdata`, `nsx_samplingrate`, `nsx_abs_time`,
  `analog_status`.

The same container shape is what a future **offline** spike source will fill, so
both feed the one segmentation entrypoint:

```matlab
% online now; offline later builds offline_spike_raw the same way
[online_spike, online_spike_waveform] = ...
    BlackrockLoader.parseSpikes(S.online_spike, trials, preMs, postMs, binMs);
```

`parseSpikes` (the source-agnostic spike parser) returns the raster product and,
when the container carries waveforms, a separate waveform product (`[]`
otherwise). Both products tag their origin in `info.source`.

### Output file schema (what the driver exports)

Each date folder is written into its own `export_data/<date>/` subfolder, with
filenames prefixed `Blackrock_<date>_`. Up to **five** files are produced; the
three `.mat` files are written only when the matching load flag is on:

| File                                | When        | Contents                                              |
|-------------------------------------|-------------|-------------------------------------------------------|
| `Blackrock_<date>_expmeta_matlab.txt`  | always   | experiment-level metadata, one block per session      |
| `Blackrock_<date>_trials_matlab.csv`   | always   | one row per trial (the parsed `trials` records)       |
| `Blackrock_<date>_analog_matlab.mat`   | `LoadAnalogData`      | analog/eye stream cut into per-trial slices  |
| `Blackrock_<date>_spikes_matlab.mat`   | `LoadOnlineSpikeData` | online spikes rasterized per trial           |
| `Blackrock_<date>_spikes_waveform_matlab.mat` | `LoadOnlineSpikeWaveform` | per-spike waveforms (µV) per trial (`-v7.3`) |

**`*_expmeta_matlab.txt`** — plain text. A single `.nev` may hold several
experiment sessions, so the file has one `Session N:` header per session
followed by its `field: value` lines and a blank line. Numeric values are
written with `mat2str`, everything else as a string.

**`*_trials_matlab.csv`** — the `trials` struct flattened with `struct2table`,
one row per trial. Key column conventions:
- `index` — a 0-based sequential row counter prepended for pandas
  (`read_csv(index_col='index')`). This is **not** the trial number.
- `Trial_number` — the real, task-reported trial number, which **resets** across
  sessions; use `Session` + `Trial_number` together to identify a trial.
- `Session` — which experiment session within the recording the trial belongs to.
- 2-element vector fields (e.g. target positions) are split into `<field>_x` /
  `<field>_y` columns; the original combined column is dropped.
- The `undefined` and `duplicates` bookkeeping fields are dropped before export.
- Derived features from parsing are included (polar target angle/eccentricity,
  `Stimulus_direction`, `Choose_target`, `Choose_leftright`).

**`*_analog_matlab.mat`** — one variable `analog`, a struct that lines up 1:1
with the CSV rows (trial dimension is index-aligned with `trials`):
- `analog.data` — `nChan × nTrials × maxSamples`, each trial's window
  `[Start − PreBuffer, End + PostBuffer]`, left-aligned and **NaN-padded** to the
  longest trial (missing-marker trials are all-NaN).
- `analog.timeseq` — `alignedrawtime` (abs time of each Start marker, s),
  `aligned_marker` (`'Start'`, where `relative_time = 0`), and `relative_time`
  (`1 × maxSamples`, seconds from the marker; negative through the pre-buffer).
- `analog.info` — `samplingrate`, plus `Session` and `Trial_number` per trial.

**`*_spikes_matlab.mat`** — one variable `online_spike`, same layout as `analog`
but a binary raster:
- `online_spike.data` — `NtotalUnit × nTrials × maxBins`, `0/1` (1 if any spike
  of that row falls in the bin), NaN-padded. Each row is one `(electrode, unit)`
  pair, so `NtotalUnit` sums isolated units across channels.
- `online_spike.timeseq` — same fields as the analog `timeseq` (`relative_time`
  is `1 × maxBins`).
- `online_spike.info` — `samplingrate` (bin rate, e.g. 1000 Hz for 1 ms bins),
  `Session`, `Trial_number`, `Channel_Number` and `Unit_No` per raster row, plus
  `source` (`'online'`; `'offline'` for a future offline-sorted source).

**`*_spikes_waveform_matlab.mat`** — written only when `LoadOnlineSpikeWaveform` is on
(opt-in; off by default, and requires `LoadOnlineSpikeData`). One variable
`online_spike_waveform` holding the raw waveform of every in-window spike, with
the **same row order** as the raster (`info.Channel_Number` / `info.Unit_No`).
Saved as `-v7.3` (HDF5) because the dense array can exceed the default MAT
format's 2 GB per-variable cap.
- `online_spike_waveform.waveform` — `NtotalUnit × nTrials × maxSpk × nSamp`, in
  **µV**, NaN-padded. The spike dimension `maxSpk` is the largest per-`(unit,
  trial)` in-window spike count, shared across all rows/trials (so the busiest
  unit drives the array size — `segmentSpikeWaveforms` warns when it would exceed
  ~2 GB).
- `online_spike_waveform.waveform_time` — `NtotalUnit × nTrials × maxSpk`, each
  spike's time in seconds **relative to the Start marker**, NaN-padded.
- `online_spike_waveform.waveform_nsamp` — samples per waveform;
  `.waveform_unit` is `'microVolts'`; `.timeseq` has `alignedrawtime` /
  `aligned_marker`; `.info` has `Session`, `Trial_number`, `Channel_Number`,
  `Unit_No`, `maxSpikes`, and `source`.

The per-trial window buffers and the spike bin width are set by
`Segment_PreBuffer` / `Segment_PostBuffer` / `Segment_BinWidth` (ms) near the top
of `BackRockFileLoader.m`.

### Comment parsing schema

`parseEvents` turns BlackRock's free-text comment strings into structured
`trials` and `experiment` records using the field maps from
`BlackrockLoader.defaultEventMaps()`. A single `.nev` may contain several
experiment **sessions** (the task started/stopped repeatedly); each
`Experiment start: git commit ...` line begins a new session, and trials are
keyed by position so a reset trial counter starts a new trial rather than
merging. Derived features (polar target angle/eccentricity,
`Stimulus_direction`, `Choose_target`, `Choose_leftright`) are added at the end.

### Inspecting the raw comments

When the task's comment-string format changes, parsed events can silently land
in `trials.undefined` instead of the expected fields. The static helper
`BlackrockLoader.commentsWithTime` pairs each raw, **unparsed** comment with its
timestamp so you can eyeball exactly what the recording contains:

```matlab
S = loader.loadSession(DataFolder);
T = BlackrockLoader.commentsWithTime(S.Events, S.EventTime);  % N-row table
disp(T)   % columns: TimeStampSec, Comment  (in recording order)
```

Use this to spot a new or renamed comment prefix, then add the matching key in
`BlackrockLoader.defaultEventMaps()` (and, if it is a new field, in
`defaultTrialTemplate()` / `defaultExpTemplate()`).

### Setting up the data path

The driver finds your data by assembling a folder path from a few editable
variables at the top of `BackRockFileLoader.m`. Set these to point at your own
data, then run the script — the loader resolves the `.nev`/`.ns2` files inside
each folder by the prefix schema above.

```matlab
Basic_Path   = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data'; % root of all data
Monkey       = 'Porthos';      % bare monkey name; folder on disk is "Monkey <name>"
Location     = 'in_lab';       % editable constant
DataType     = 'raw_data';     % editable constant
OutputFolder = 'export_data';  % where parsed data is written
```

The driver builds the input and export roots as:
```matlab
DataTypePath = fullfile(Basic_Path, ['Monkey ' Monkey], Location, DataType);
ExportPath   = fullfile(Basic_Path, ['Monkey ' Monkey], Location, OutputFolder);
```
so the expected folder layout on disk is:
```
<Basic_Path>/Monkey <Monkey>/<Location>/<DataType>/<YYYY-MM-DD>/    ← contains the .nev/.ns2 files
<Basic_Path>/Monkey <Monkey>/<Location>/export_data/<YYYY-MM-DD>/   ← parsed .txt/.csv output is written here
```
If your data already lives under a different layout, just overwrite `DataTypePath`
and `ExportPath` directly with your own absolute paths.

### Batch loading multiple sessions

The driver processes one or more `YYYY-MM-DD` session folders in a single run.
Set the `Folder` variable to choose which ones:
```matlab
Folder = '2026-06-17';                    % a single session folder
Folder = {'2026-06-17','2026-06-18'};     % several folders, loaded in order
Folder = {};                              % every YYYY-MM-DD folder under DataTypePath
```
For each folder the driver **loads → parses → adds features → exports** in turn,
writing the per-session output files
(`Blackrock_<date>_expmeta_matlab.txt` and `Blackrock_<date>_trials_matlab.csv`)
into the matching `export_data/<date>/` subfolder.

If one folder fails (e.g. a missing `.nev` file), it is caught and reported, and
the batch continues with the remaining folders. A **batch summary** listing the
`ok`/`failed` status of every folder is printed at the end.

> Note: a single `.nev` recording may contain several experiment sessions
> (the task started/stopped multiple times). These are tracked per session
> within each file via the `Session` column, independent of the batch-folder loop.

### Cage trainer data

`CageTrianingDataLoading.m` concatenates the per-trial `.json` files into one
`all_trials_<date>.csv`; `CageTrainingDataAnalyzer.m` reads that CSV and plots
the psychometric curve. Set the corresponding path variables at the top of those
scripts the same way as the BlackRock loader.

You are welcome to change these into your own paths.

## Feel free to push me request, report errors or bugs.
