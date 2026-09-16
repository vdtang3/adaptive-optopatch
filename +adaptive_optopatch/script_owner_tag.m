function tag=script_owner_tag()
%SCRIPT_OWNER_TAG The owner adaptive_optopatch stamps on waveforms it adds.
%   Luminos already has an ownership convention for waveform records a
%   script - rather than the operator's Waveforms tab - put into
%   wfm_data: Append_Script_Waveform writes a script_owner field and
%   Drop_Script_Waveforms takes exactly those entries back out again. AO
%   reuses that field and that convention rather than inventing a parallel
%   one, so a record AO left behind is identifiable and removable by code
%   that has never heard of AO.
tag="adaptive_optopatch";
end
