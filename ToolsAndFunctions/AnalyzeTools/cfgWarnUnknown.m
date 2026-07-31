function cfgWarnUnknown(cfg, allowed, contextName)
% Warn about field names a preprocessing block does not recognise.
%
% The per-block config structs are written by hand in BlackRockFileAnalyzer.m,
% so a typo (cfg.Eye.RecCompute) would otherwise create a dead field and be
% silently ignored -- and "silently ignored" here means the block falls back to
% ReCompute = true and reads a 179 MB export for nothing. This turns that into a
% visible warning at the top of the block.
%
% A warning, not an error: an unknown field never changes what the block does,
% so a long batch run should not die on one.
%
%   cfg         - the block's config struct ([] is fine).
%   allowed     - cellstr of the field names this block understands.
%   contextName - what to call it in the message, e.g. 'cfg.Photodiode'.
%
% Xuefei Yu 2026

    if ~isstruct(cfg);  return;  end

    unknown = setdiff(fieldnames(cfg), allowed, 'stable');
    if isempty(unknown);  return;  end

    warning('cfgWarnUnknown:UnknownField', ...
        ['%s has unrecognised field(s): %s\n' ...
         'They are ignored. Recognised fields are: %s'], ...
        contextName, strjoin(unknown(:).', ', '), strjoin(allowed(:).', ', '));
end
