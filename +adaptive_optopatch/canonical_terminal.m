function canonical=canonical_terminal(terminal,aliasList)
%CANONICAL_TERMINAL Physical terminal identity, exactly as Luminos resolves it.
%   canonical=CANONICAL_TERMINAL(terminal) reduces one or more terminal
%   spellings to the string Luminos compares when it decides whether two
%   names denote the same physical output. Two spellings name the same
%   physical terminal if and only if their canonical forms are equal.
%
%   The rule is DAQ.Same_Terminal's, not a second one. Same_Terminal
%   canonicalizes with
%
%       lower(strrep(strtrim(remove_al(t)),'/',''))
%
%   so an alias is resolved first (case-insensitively, as DAQ.remove_al
%   does), then the name is trimmed, every slash is dropped, and what is
%   left is lowercased. That is what makes "DMD Trigger",
%   "Dev1/port0/line4" and "/DEV1/PORT0/LINE4" one terminal.
%
%   This is deliberately the ONLY physical-terminal matching rule in
%   adaptive_optopatch. Comparing terminals by exact or case-sensitive
%   string equality is what let a stale waveform stored under a rig alias
%   survive AO's filtering and then combine, inside Luminos, with the
%   waveform AO had just installed on the same line.
%
%   aliasList is an Nx2 cell array shaped like DAQ.alias_list: column 1 is
%   the actual terminal, column 2 the alias. It defaults to the rig
%   stimulation manifest's declared list, which is transcribed from the rig
%   file, so a caller holding no DAQ object still resolves aliases the way
%   the rig does.
arguments
    terminal
    aliasList cell = adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list
end
values=strip(string(terminal));
canonical=strings(size(values));
for k=1:numel(values)
    resolved=adaptive_optopatch.resolve_terminal_alias(values(k),aliasList);
    canonical(k)=lower(erase(resolved,"/"));
end
end
