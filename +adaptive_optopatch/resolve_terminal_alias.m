function value=resolve_terminal_alias(terminal,aliasList)
%RESOLVE_TERMINAL_ALIAS DAQ.remove_al for a single terminal spelling.
%   Returns the actual terminal an alias stands for, or the input
%   unchanged when it is not an alias. Matching is case-insensitive, as
%   DAQ.remove_al's is, and the first hit wins and stops the search.
%
%   This is the alias half of terminal identity on its own, for the one
%   caller that needs the resolved terminal rather than the canonical
%   comparison key: COMPILE_OUTPUT_SAMPLES groups by the de-aliased port
%   string because that is what Luminos groups by.
arguments
    terminal
    aliasList cell = adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list
end
value=strip(string(terminal));
for j=1:size(aliasList,1)
    if strcmpi(value,strip(string(aliasList{j,2})))
        value=strip(string(aliasList{j,1}));
        return
    end
end
end
