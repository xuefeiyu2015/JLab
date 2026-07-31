function status = describeBlockPlan(cfgBlock, savePath, name, ext, opts)
% One line saying what a preprocessing block is about to do, and why.
%
% REPORTING ONLY. This informs no load decision -- needFullFile owns that rule
% and stays the single place it lives. The consequence matters: if this function
% ever drifts from needFullFile, the result is a wrong MESSAGE, never a wrong
% read. It is written to mirror that function's branches so the two read as a
% pair, and it reuses hasCachedProduct rather than rebuilding any cache path.
%
% The four states it distinguishes are the ones the analyze functions actually
% take internally (getCachedPayload for the plot path, the .csv for the
% return-only path):
%
%   ReCompute                        -> rebuild the product from the export
%   no cache                         -> compute now (and write the cache)
%   cache hit, plotting              -> load the payload and redraw from it
%   cache hit, not plotting          -> read the small .csv; no compute, no plot
%
%   cfgBlock - that block's config struct (cfg.RT, cfg.Photodiode, ...).
%   savePath - the session export folder. '' means no cache.
%   name     - the cached product's base name, e.g. 'RT', 'SpikeSummary'.
%   ext      - the cached product's extension, same convention as needFullFile:
%              a 2-element cellstr {'.mat','.csv'} means the plot path and the
%              return-only path reuse DIFFERENT files, and a plain char is used
%              as given.
%   opts     - (optional) struct, read with cfgField so an omitted or empty
%              field takes the default:
%                .PlotDefault - value assumed for cfg.Plot when the field is
%                               absent; use the wrapped function's own default
%                               so the message matches what will happen (true).
%                .PlotLabel   - what .Plot draws, for the wording: 'plots'
%                               (default) gives "plots on" / "no plots",
%                               'navigator' gives "navigator on" / etc.
%                .Notes       - char or cellstr of extra clauses appended at the
%                               end, for anything only the caller knows (e.g.
%                               whether its exported file was read).
%
% Returns the status char, e.g.
%   'cache hit -> loading RT.mat, no recompute; plots on'
%   'RECOMPUTE -> rebuilding PhotodiodeTiming.mat; plots on; export read'
%
% Xuefei Yu 2026

    if nargin < 4 || isempty(ext);  ext = '.mat';  end
    if nargin < 5;                  opts = [];     end

    plotDefault = cfgField(opts, 'PlotDefault', true);
    plotLabel   = cfgField(opts, 'PlotLabel',   'plots');
    extraNotes  = cfgField(opts, 'Notes',       {});

    reCompute = logical(cfgField(cfgBlock, 'ReCompute', true));
    doPlot    = logical(cfgField(cfgBlock, 'Plot', plotDefault));

    % Same branch as needFullFile.m: keep the 'Plot' fallback false here too, so
    % the extension this names is the one that function tested.
    if iscell(ext)
        ext = ext{2 - logical(cfgField(cfgBlock, 'Plot', false))};
    end

    product = [name ext];

    % The no-plot cache branch spells out "no plot" itself; the others still need
    % the clause.
    needPlotClause = true;
    if reCompute
        status = sprintf('RECOMPUTE -> rebuilding %s', product);
    elseif ~hasCachedProduct(savePath, name, ext)
        status = sprintf('no cache (%s missing) -> computing now', product);
    elseif doPlot
        status = sprintf('cache hit -> loading %s, no recompute', product);
    else
        status = sprintf('cache hit -> reading %s, no compute, no plot', product);
        needPlotClause = false;
    end

    notes = {};
    if needPlotClause
        if doPlot
            notes{end+1} = sprintf('%s on', plotLabel);
        else
            notes{end+1} = sprintf('no %s', plotLabel);
        end
    end
    if ~isempty(extraNotes)
        notes = [notes, reshape(cellstr(extraNotes), 1, [])];
    end

    if ~isempty(notes)
        status = [status '; ' strjoin(notes, '; ')];
    end
end
