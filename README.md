# Data loader and analyzer for JLab

### Keeps updating by Xuefei Yu, from Mar 6th, 2026

MATLAB-based data analysis toolkit for both cage trainer and data recorded using BlackRock hardware.

## Prerequisites

### 1. Add All Files to MATLAB Path

Before running any scripts, add the entire JLab folder (including subfolders) to your MATLAB path:

```matlab
addpath(genpath('/path/to/JLab'))
savepath
```

Or manually in MATLAB:
**Home → Set Path → Add with Subfolders** → select the JLab folder → Save.

> ⚠️ Failing to add all subfolders to the path will cause function-not-found errors.

### 2. Install BlackRock NPMK Toolkit

This repository requires the **BlackRock Neurotech NPMK (Neural Processing MATLAB Kit)** toolkit to load `.ns5`, `.nev`, and other BlackRock file formats.

Download it from the official GitHub repository:
👉 https://github.com/BlackrockNeurotech/NPMK

**Installation steps:**
1. Download or clone the NPMK repository
2. Add the NPMK folder to your MATLAB path (recommended in ToolsAndFunctions):
```matlab
addpath(genpath('/path/to/JLab/ToolsAndFunctions/NPMK'))
savepath
```

> ⚠️ Without NPMK, BlackRock data files cannot be loaded and the scripts will not run.

## File Structure

```
JLab/
├── BackRockFileLoader.m        # Loads BlackRock raw data files
├── BlackRockFileAnalyzer.m     # Analyzes BlackRock behaviors and recordings
├── CageTrainingDataAnalyzer.m  # Analyzes cage training behavioral data
├── CageTrianingDataLoading.m   # Loads cage training data
└── ToolsAndFunctions/          # Helper functions and utilities
```

## Usage

1. Complete all steps in **Prerequisites**
2. Open MATLAB and navigate to the JLab folder
3. Open the desired script, e.g.:
first the loader: ```BackRockFileLoader``` to parse the raw data
then the analyzer: ```BlackRockFileAnalyzer``` for further analysis

### Setting up the data path

The loaders find your data by assembling a folder path from a few editable
variables at the top of the script. Set these to point at your own data, then
run the script — the `.nev`/`.ns2` files inside the folder are auto-detected.

**BlackRock data** (`BackRockFileLoader.m`): edit the per-run inputs near the top:
```matlab
Basic_Path   = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data'; % root of all data
Monkey       = 'Porthos';      % bare monkey name; folder on disk is "Monkey <name>"
Location     = 'in_lab';       % editable constant
DataType     = 'raw_data';     % editable constant
OutputFolder = 'export_data';  % where parsed data is written
```
The loader builds the input and export roots as:
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

The loader processes one or more `YYYY-MM-DD` session folders in a single run.
Set the `Folder` variable to choose which ones:
```matlab
Folder = '2026-06-17';                    % a single session folder
Folder = {'2026-06-17','2026-06-18'};     % several folders, loaded in order
Folder = {};                              % every YYYY-MM-DD folder under DataTypePath
```
For each folder the script **loads → parses → adds features → exports** in turn,
writing the per-session output files
(`Blackrock_<date>_expmeta_matlab.txt` and `Blackrock_<date>_trials_matlab.csv`)
into the matching `export_data/<date>/` subfolder.

If one folder fails (e.g. a missing `.nev` file), it is caught and reported, and
the batch continues with the remaining folders. A **batch summary** listing the
`ok`/`failed` status of every folder is printed at the end.

> Note: a single `.nev` recording may contain several experiment sessions
> (the task started/stopped multiple times). These are tracked per session
> within each file via the `Session` column, independent of the batch-folder loop.

**Cage trainer data** (`CageTrianingDataLoading.m`): set the corresponding path
variables at the top of that script the same way.

You are welcome to change these into your own paths.

## Feel free to push me request, report errors or bugs.

