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
first the loader: ```CageTrianingDataLoading```
then the analyzer: ```BlackRockFileAnalyzer```
4. For the cage trainer data: the path structure in my laptop is:
```matlab
monkey = 'Monkey Porthos';
main_path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data/';
data_date = '2026-02-24'; % in yyyy-mm-dd
task_type = 'cage_training/timedelay';
local_label = 'raw';
folder_path = fullfile(main_path, monkey, task_type, local_label, data_date);
```
You are welcome to change into your own path

## Feel free to push me request, report errors or bugs.

