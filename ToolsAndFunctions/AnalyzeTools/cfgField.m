function v = cfgField(cfg, name, default)
% Read one field out of a preprocessing block's config struct.
%
% The Prepare* wrappers pass [] as the default for every parameter they forward,
% so a field the driver left out (or set to []) falls straight through to the
% documented default of the function being wrapped. No block invents a default
% of its own -- the config struct in BlackRockFileAnalyzer.m and the wrapped
% function's own header stay the only two places a default is written down.
%
%   cfg     - a config struct (cfg.Eye, cfg.Photodiode, ...). [] is accepted and
%             behaves like a struct with no fields, so a block can be called with
%             no config at all.
%   name    - field name.
%   default - returned when the field is absent or empty.
%
% Xuefei Yu 2026

    if isstruct(cfg) && isfield(cfg, name) && ~isempty(cfg.(name))
        v = cfg.(name);
    else
        v = default;
    end
end
