function fingerprint=record_owned_dmd_pattern(dmd,options)
%RECORD_OWNED_DMD_PATTERN Note what AO just programmed, for the final check.
%   Taken immediately after AO finishes programming a DMD. Luminos checks it
%   again at the last moment before the acquisition is triggered, once every
%   startup hook that could touch a DMD has run, and refuses to start if the
%   device is no longer projecting this. See
%   Verify_Owned_Dmd_Patterns in Luminos.
%
%   Returns "" and does nothing when AO does not own the device, which is the
%   case when a prepare_* function is called on its own rather than from a
%   runner. Programming outside a claimed acquisition is legitimate; acquiring
%   an expectation nothing will ever check is not.
arguments
    dmd
    options.Owner (1,1) string = "adaptive_optopatch"
end
fingerprint="";
if ~ismethod(dmd,"Record_Owned_Pattern"), return; end
if string(read_member(dmd,"pattern_owner",""))~=options.Owner, return; end
fingerprint=dmd.Record_Owned_Pattern(options.Owner);
end

function value=read_member(object,name,defaultValue)
value=defaultValue;
try
    if isstruct(object) && isfield(object,name)
        value=object.(name);
    elseif isobject(object) && isprop(object,name)
        value=object.(name);
    end
catch
end
if isempty(value), value=defaultValue; end
end
