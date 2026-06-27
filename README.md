# Data loader and analyzer for JLab

### Keeps updating by Xuefei Yu, from Mar 6th, 2026

MATLAB-based data analysis toolkit for both cage trainer and data recorded using BlackRock hardware.

## Prerequisites

### 1. MATLAB Path (handled automatically)

`BackRockFileLoader.m` self-adds the entire JLab folder (its own location plus
all subfolders) to the MATLAB path on startup, so NPMK, the `BlackrockLoader`
class, and the analyze tools are all found **without any manual `addpath`** —
on any clone, wherever you put the repo.

If you prefer to set the path yourself (or run the other scripts directly), you
can still add the whole folder once:

```matlab
addpath(genpath('/path/to/JLab'))
savepath
```

Or manually in MATLAB:
**Home → Set Path → Add with Subfolders** → select the JLab folder → Save.

### 2. Install BlackRock NPMK Toolkit

This repository requires the **BlackRock Neurotech NPMK (Neural Processing MATLAB Kit)** toolkit to load `.ns2`, `.nev`, and other BlackRock file formats.

Download it from the official GitHub repository:
👉 https://github.com/BlackrockNeurotech/NPMK

**Installation steps:**
1. Download or clone the NPMK repository
2. Place it at `JLab/ToolsAndFunctions/NPMK` — the loader's auto-path step (above)
   then picks it up automatically, so no manual `addpath` is needed. If you keep
   it elsewhere, add it yourself:
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
loader = BlackrockLoader('LoadAnalogData', true, ...   % override any property
                         'LoadOnlineSpikeData', false);
S                    = loader.loadSession(DataFolder);     % resolve + load files
[trials, experiment] = loader.parseEvents(S.Events, S.EventTime);  % comments -> records
```

### Input file schema (role-aware resolution)

A single recording is split across files **by filename prefix**, and each data
product is verified present before use:

| File                | Role                                   |
|---------------------|----------------------------------------|
| `NSP-*.nev`         | experiment comments + comment timing   |
| `HUB-*.nev`         | online spike timing                    |
| `NSP-*.ns2`         | analog / eye data                      |

- **Comments are required.** If `NSP-*.nev` is missing, comments **fall back to
  `HUB-*.nev`** (legacy recordings wrote comments there). If neither has them,
  that folder errors and is reported as `failed`.
- **Spikes and analog are soft.** A missing or unreadable spike/analog file is
  recorded in a status string and that product is skipped — the folder still
  succeeds. The prefixes (`NSP`/`HUB`), the `.ns2` identifier, and the
  `LoadAnalogData` / `LoadOnlineSpikeData` flags are all constructor-overridable
  properties.

`loadSession` returns a struct `S` with `Events`, `EventTime`,
`comments_source`, the spike fields (`SpikeTime`, `spike_status`), and the
analog fields (`nsxdata`, `nsx_samplingrate`, `nsx_abs_time`, `analog_status`).

### Comment parsing schema

`parseEvents` turns BlackRock's free-text comment strings into structured
`trials` and `experiment` records using the field maps from
`BlackrockLoader.defaultEventMaps()`. A single `.nev` may contain several
experiment **sessions** (the task started/stopped repeatedly); each
`Experiment start: git commit ...` line begins a new session, and trials are
keyed by position so a reset trial counter starts a new trial rather than
merging. Derived features (polar target angle/eccentricity,
`Stimulus_direction`, `Choose_target`, `Choose_leftright`) are added at the end.

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
