function records=remove_output_records(records,identifiers,aliasList)
%REMOVE_OUTPUT_RECORDS Drop every record that drives one of these terminals.
%   records=REMOVE_OUTPUT_RECORDS(records,identifiers,aliasList) removes
%   each wfm_data AO/DO record whose name or port resolves, through
%   CANONICAL_TERMINAL, to the same physical terminal as any identifier.
%
%   This is the one removal helper. It replaces three subtly different
%   ones that had grown up beside each other - one matching a name and a
%   port, one matching a list of identifiers, one doing the same with
%   whitespace stripped - all of them comparing raw strings, so every one
%   of them missed a terminal written under a rig alias or with a leading
%   slash. Terminal identity is CANONICAL_TERMINAL's answer and nothing
%   else's.
%
%   Both the record's name and its port are matched. Luminos resolves
%   outputs by port alone, so matching the name too only ever removes more
%   than Luminos would combine - which is the safe direction, and is what
%   catches a record whose port was left as the alias while its name
%   carried the terminal.
arguments
    records
    identifiers
    aliasList cell = adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list
end
if isempty(records), return; end
targets=adaptive_optopatch.canonical_terminal(identifiers(:),aliasList);
targets=targets(strlength(targets)>0);
if isempty(targets), return; end
keep=true(size(records));
for k=1:numel(records)
    spellings=strings(1,0);
    if isfield(records,"name"), spellings(end+1)=string(records(k).name); end %#ok<AGROW>
    if isfield(records,"port"), spellings(end+1)=string(records(k).port); end %#ok<AGROW>
    if isempty(spellings), continue; end
    canonical=adaptive_optopatch.canonical_terminal(spellings,aliasList);
    keep(k)=~any(ismember(canonical(strlength(canonical)>0),targets));
end
records=records(keep);
end
