path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data/Monkey test/in_lab/raw_data/2026-06-24';
hub_file  = 'Hub1-06242026_test_for_timingissue.nev';
ns2_file = 'NSP-06242026_test_for_timingissue.ns2';
% Load the .nev and .ns2 files
hubData = openNEV(fullfile(path, hub_file),'report','nosave');
ns2Data =  openNSx(fullfile(path, ns2_file),'read','report', 'uv');

EventData_timestamp = hubData.Data.Comments.TimeStamp;
EventData_timetransform = ts2sec(EventData_timestamp);
EventData_timestampSec = hubData.Data.Comments.TimeStampSec;

SpikeData_timestamp = hubData.Data.Spikes.TimeStamp;
SpikeData_timestampSec = ts2sec(SpikeData_timestamp);
EyeData = ns2Data.MetaTags.Timestamp;
EyeDataSec = ts2sec(EyeData);
keyboard

