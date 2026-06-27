# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MATLAB toolkit for loading and analyzing monkey behavioral data from two
sources: a **cage trainer** (JSON output) and **in-lab BlackRock** recordings
(`.nev` events + `.ns2` analog/eye traces). The end goal of both pipelines is a
psychometric function over a time-delay (target asynchrony) two-alternative
choice task.

## Running

There is no build/lint/test harness. Everything is a MATLAB script run
interactively from the MATLAB editor/desktop (the MATLAB MCP tools target a
live local MATLAB). To run a script, open it and press Run, or call it by name
once the path is set up.

**Path setup is mandatory** before anything works:
```matlab
addpath(genpath('/path/to/JLab'))   % includes all subfolders
```
`BackRockFileLoader.m` also self-adds `ToolsAndFunctions/NPMK` (if `openNEV` is
missing) and `ToolsAndFunctions/LoadingTools` (if `BlackrockLoader` is missing).

**NPMK is a required third-party dependency** (BlackRock Neural Processing
MATLAB Kit) living in `ToolsAndFunctions/NPMK`. It is gitignored and not part of
this repo — install it from https://github.com/BlackrockNeurotech/NPMK. The
loaders depend on its `openNEV`, `openNSx`, and `ts2sec` functions.

## Two pipelines (load → analyze)

**BlackRock / in-lab:**
1. `BackRockFileLoader.m` — thin **driver script**: sets run config (paths,
   monkey, folders), constructs a `BlackrockLoader`, loops over date folders
   calling `loadSession` + `parseEvents`, and writes `*_trials_matlab.csv` and
   `*_expmeta_matlab.txt`. All loading + parsing logic lives in the class
   (`ToolsAndFunctions/LoadingTools/BlackrockLoader.m`).
2. `BlackRockFileAnalyzer.m` — reads the trials CSV, filters, fits/plots the
   psychometric curve.

**Cage trainer:**
1. `CageTrianingDataLoading.m` — concatenates per-trial `.json` files into
   `all_trials_<date>.csv`.
2. `CageTrainingDataAnalyzer.m` — reads that CSV and plots the psychometric
   curve.

Both analyzers call the shared `ToolsAndFunctions/AnalyzeTools/VisPsychometricFunction.m`,
which fits a logistic regression (`fitglm`, binomial) and returns
`pse` (bias) and `threshold` (slope), expecting an N×3 matrix of
`[stimulus, direction (-1/+1), choice_response (0/1)]`.

## Data paths

Scripts are configured by editing constants near the top (e.g. `Basic_Path`,
`Monkey`, `Location`, `DataType`, `Folder`/`data_date`), not via arguments. The
expected on-disk layout for BlackRock data is:
```
<Basic_Path>/Monkey <name>/<Location>/<DataType>/<YYYY-MM-DD>/   # input .nev/.ns2
<Basic_Path>/Monkey <name>/<Location>/export_data/<YYYY-MM-DD>/  # parsed output
```
Hardcoded absolute paths point at the author's machine; expect to edit them.
`Folder` in the loader accepts a single date string, a cellstr of dates, or `{}`
to auto-discover every `YYYY-MM-DD` folder under the input root (batch mode —
each folder is loaded/parsed/exported independently, failures are caught and
reported in a final summary).

## How the BlackRock loader/parser works (the non-obvious core)

`ToolsAndFunctions/LoadingTools/BlackrockLoader.m` is the heaviest file — a
config-property `classdef`. Its properties hold the file schema, load flags, and
parsing schema; override any via the constructor
(`BlackrockLoader('LoadOnlineSpikeData', false)`). Two instance methods do the
work, called per date folder by the driver.

**`loadSession(DataFolder)` — schema-checked, role-aware file resolution.**
The recording is split across files by filename **prefix**, and each data
product is verified present before use:
- `NSP-*.nev` → comments + comment timing; **falls back to `HUB-*.nev`** (legacy
  recordings kept comments there).
- `HUB-*.nev` → online spike timing (`ts2sec`, loaded into the workspace only).
- `NSP-*.ns2` → analog/eye data.
Comments are required (missing → that folder errors and is marked `failed`);
spike/analog failures are **soft** (recorded in a status string, that product
skipped) and surfaced per-folder in the batch summary.

**`parseEvents(Events, EventTime)` — comment strings → `trials` + `experiment`.**
BlackRock stores experiment info as free-text comment strings; this single pass
turns them into structured records using the field maps from
`BlackrockLoader.defaultEventMaps()`:
- **Field maps** (`containers.Map`, in the `EventMaps` struct) translate each
  comment's event prefix to a struct field. Each handles a value shape:
  - `TimeEvents` — bare timestamp events (assign the event's time).
  - `InformationEvents` — events carrying a value: `(x, y) deg` coords,
    `(...ms)` reward, or a trailing duration/size number.
  - `SegmentEvents` — categorical value after the last space (colors, task,
    trial type, side).
  - `DashEvents` / `OutcomeEvents` — `End - <outcome>`, `Correct/Wrong choice`.
  - `ExpEvents` — experiment-level metadata (screen, FPS, eyetracker, etc.).
- **Session vs. trial.** A single `.nev` can contain multiple experiment
  sessions (task started/stopped repeatedly). A new session starts at each
  `Experiment start: git commit ...`; `experiment` is a struct array indexed by
  `session_index`. Trials are keyed by **position** (`trial_index`), not by the
  parsed trial number, so a reset counter (…,30,0,1,…) or a number reused across
  sessions starts a new trial rather than merging.
- **Duplicates / undefined.** Re-seen values for an already-filled field go into
  `trials.duplicates`; unrecognized comments go into `trials.undefined`. Both are
  dropped before CSV export.
- **Derived features** added at the end: Cartesian→polar target angle and
  eccentricity, `Stimulus_direction`, `Choose_target`, `Choose_leftright`.

**Export** stays in the driver script: flattens 2-element vector fields into
`_x`/`_y` columns and adds a 0-based `index` column (pandas-friendly), distinct
from the real, resetting `Trial_number`.

When the comment string format from the task changes, the fix is almost always
adding a key in `BlackrockLoader.defaultEventMaps()` and (if new) a field in
`defaultTrialTemplate()` / `defaultExpTemplate()`.

## Conventions

- `.asv` files are MATLAB editor autosaves — ignore them.
- `Test_for_Timingalignment.m` is a scratch script for `.nev`/`.ns2` clock
  alignment and is gitignored; not part of the pipeline.
- Note the filename typo `BackRockFileLoader` (vs. "BlackRock" everywhere else)
  — refer to it exactly as named when running.
- Several scripts end with `keyboard` inside commented calibration/debug blocks;
  these are intentional interactive breakpoints, not bugs.
