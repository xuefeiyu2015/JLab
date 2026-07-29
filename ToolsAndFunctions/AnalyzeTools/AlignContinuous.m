function aligned = AlignContinuous(analog, alignMarker, timeWindow)
% Re-align a per-trial continuous/analog signal (photodiode, LFP, eye trace,
% ...) to a per-trial marker, EITHER ONE SHARED MARKER FOR EVERY CHANNEL OR A
% DIFFERENT MARKER PER CHANNEL. Resamples every trial onto one shared time
% axis with 0 at the marker.
%
% Uses nearest-sample re-indexing, the same approach AlignSpikeSequence uses
% for spike rasters, not linear interpolation (AlignEyeTrace's approach):
% these signals are already sampled on one shared, evenly-spaced time axis
% per trial (timeseq.relative_time), so re-aligning to a marker is a pure
% index shift, vectorized across every trial at once (no per-trial loop) via
% one round() + one fancy-index gather over the whole trial dimension.
% Several alternatives were benchmarked against a real session's full
% photodiode-timing run (per-call, isolated microbenchmark) before landing
% here:
%   1. interp1 called once per trial (matching AlignEyeTrace's style):
%      ~120 ms/call, ~9x SLOWER than a per-trial nearest-sample loop --
%      interp1's per-call overhead dominates when called this many times
%      (thousands of trials).
%   2. Linear-interpolation math vectorized across every trial (no loop),
%      needing two bracketing samples + a blend weight per output sample:
%      ~21 ms/call on a tight (0.5 s) window, SLOWER than the per-trial
%      nearest-sample loop's ~13 ms -- the ~10 intermediate arrays it needs
%      (bracket indices x2, weights, linear indices x2, gathered values x2;
%      each sized nTrials x newSamples) cost more to allocate than the loop
%      overhead they remove, since each loop iteration's actual work was
%      already cheap.
%   3. THIS: nearest-sample math (one bracket, no blend weight) vectorized
%      across every trial (no loop): about tied with the per-trial loop on
%      a tight (0.5 s) window (~13 ms either way), but more than 2x FASTER
%      on the wide window GetPhotodiodeTiming's Band-1 plot pull actually
%      uses (PlotWindow ~2.3 s: ~45 ms here vs ~94 ms looped) -- half the
%      intermediate arrays of the linear-interpolation attempt (one gather,
%      not two), so it wins once newSamples is large enough that a
%      whole-trial-dimension vectorized op beats per-trial loop overhead.
% Also avoids smearing a sharp transition (e.g. a photodiode step) the way
% linear interpolation would, at the cost of at most half a sample of
% alignment error on genuinely smooth signals (eye position, LFP) --
% negligible at the sampling rates these signals are recorded at. Reusable
% across any export product sharing the .data / .timeseq.relative_time /
% .timeseq.alignedrawtime / .info.samplingrate contract (eye/lfp/photodiode).
%
% alignMarker accepts a per-channel marker (nTrials x nChan) as well as one
% shared marker for every channel (scalar or nTrials x 1), fully vectorized
% across trial, channel AND sample with no loop at all, not even over
% channels -- added because GetPhotodiodeTiming's fixation/target1/target2
% channels each need a DIFFERENT marker (Fixation_point_on /
% Target_1_presented / Target_2_presented), which used to mean 3 separate
% calls (looping externally, one channel each). One combined call with a
% 3-column marker matrix measured ~34% faster than that external loop on a
% real session's full photodiode-timing run (134 ms vs 203 ms, same
% wide-window case as the benchmark above), with bitwise-identical output --
% worth it once nChan > 1 with genuinely different markers; for the common
% single-marker case (e.g. aligning multi-channel LFP or eye X/Y to one
% shared go-cue) this is unchanged from before.
%
% Input:
%   analog      - continuous export product (eye/lfp/photodiode-style struct):
%                   .data                    nChan x nTrials x nSamples
%                   .timeseq.relative_time   1 x nSamples, s from Start
%                   .timeseq.alignedrawtime  nTrials x 1, abs Start time (s)
%                   .info.samplingrate       sample rate (Hz)
%   alignMarker - marker times in ABSOLUTE recording-clock seconds (the same
%                 clock as the trials-table markers), one of:
%                   scalar        - same time, broadcast to every trial and channel
%                   nTrials x 1   - one marker per trial, shared by every channel
%                   nTrials x nChan - one marker per (trial, channel) pair
%                 NaN -> that trial (or that trial/channel pair) is all-NaN
%                 in the output.
%   timeWindow  - [tPre tPost] in seconds relative to the marker. Omitted or
%                 [] spans the full aligned range across all trials
%                 (NaN-padded).
%
% Output:
%   aligned     - struct:
%                   .data        nChan x nTrials x newSamples (NaN-padded)
%                   .time        1 x newSamples, seconds from the marker
%                   .alignMarker the markers used, normalized to nTrials x nChan
%
% Xuefei Yu Jul 2026

    if nargin < 3;  timeWindow = [];  end

    data     = analog.data;
    relTime  = analog.timeseq.relative_time(:).';        % 1 x nSamples, s from Start
    rawStart = analog.timeseq.alignedrawtime(:);          % nTrials x 1, abs Start (s)
    dt       = 1 / analog.info.samplingrate;

    [nChan, nTr, nSamp] = size(data);

    % Normalize alignMarker to nTr x nChan regardless of which of the three
    % accepted shapes it came in as.
    if isscalar(alignMarker)
        alignMarker = repmat(alignMarker, nTr, nChan);
    elseif isvector(alignMarker)
        alignMarker = repmat(alignMarker(:), 1, nChan);       % nTr x 1 -> nTr x nChan, shared across channels
    elseif ~isequal(size(alignMarker), [nTr, nChan])
        error('AlignContinuous:BadMarkerSize', ...
            'alignMarker must be scalar, nTrials x 1, or nTrials x nChan (got %s for nTrials=%d, nChan=%d).', ...
            mat2str(size(alignMarker)), nTr, nChan);
    end

    % Marker in the signal's Start frame (s from Start), per (trial, channel).
    mRel  = alignMarker - rawStart;                       % nTr x nChan (broadcast)
    valid = ~isnan(mRel);

    % --- output time grid (integer samples from the marker) ---------------
    if ~isempty(timeWindow)
        kmin = round(timeWindow(1) / dt);
        kmax = round(timeWindow(2) / dt);
    elseif any(valid(:))
        % Full span: earliest and latest source time re-expressed from the marker.
        kmin = floor((relTime(1)   - max(mRel(valid))) / dt);
        kmax = ceil( (relTime(end) - min(mRel(valid))) / dt);
    else
        kmin = 0;  kmax = 0;
    end
    kgrid   = kmin:kmax;
    newTime = kgrid * dt;                                 % 1 x newSamples, s from marker
    newSamp = numel(newTime);

    % Nearest source-sample index for every (trial, channel, output-sample)
    % triple at once, via broadcasting: mRel is nTr x nChan x 1, newTime is
    % 1 x 1 x newSamp.
    t0       = relTime(1);
    mRel3    = reshape(mRel, nTr, nChan, 1);
    newTime3 = reshape(newTime, 1, 1, newSamp);
    srcIdx   = round((mRel3 + newTime3 - t0) / dt) + 1;               % nTr x nChan x newSamp
    ok       = srcIdx >= 1 & srcIdx <= nSamp & reshape(valid, nTr, nChan, 1);
    srcIdxC  = min(max(srcIdx, 1), nSamp);                            % clamped only so the linear index below
                                                                       % stays in-bounds; `ok` gates what's actually used

    % Linear index into `data` (nChan x nTr x nSamp, column-major): for
    % (trial j, channel c, output sample k), element (c, j, srcIdxC(j,c,k))
    % is at c + (j-1)*nChan + (srcIdxC-1)*nChan*nTr.
    chIdx = reshape(1:nChan, 1, nChan, 1);
    jIdx  = reshape(1:nTr, nTr, 1, 1);
    lin   = chIdx + (jIdx - 1) * nChan + (srcIdxC - 1) * nChan * nTr;  % nTr x nChan x newSamp, broadcast

    outTJC = nan(nTr, nChan, newSamp);
    outTJC(ok) = data(lin(ok));                % NaN source (padding) stays NaN via `ok`'s own bounds check
    out = permute(outTJC, [2 1 3]);            % -> nChan x nTr x newSamp, matching .data's usual layout

    aligned = struct('data', out, 'time', newTime, 'alignMarker', alignMarker);
end
