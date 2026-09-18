function record=claim_dmd_pattern_ownership(devices,options)
%CLAIM_DMD_PATTERN_OWNERSHIP Take exclusive DMD programming for an AO run.
%   AO programs the Blue DMD - a static target, or a bank of masks with a
%   FLUT playlist over it - and the Orange recording mask, and then hands
%   the acquisition to Luminos. Luminos's own startup reloads each DMD's
%   retained pattern_stack when auto_write_stack is set, and that happens
%   after AO has programmed and verified the device and before the first
%   trigger. That is how a correct plan, a correct preview and a
%   read-back-verified DMD write could all coexist with the wrong pattern
%   being projected, and why a standalone DMD or FLUT diagnostic passes
%   while a real acquisition does not: the diagnostic never goes through
%   acquisition startup.
%
%   The stale stack is not deleted. It is the operator's stack in the DMD
%   tab and it has to survive an AO run. What is suspended, for the length
%   of this run only, is the autoload.
%
%   Pass the returned record to release_dmd_pattern_ownership from a
%   guaranteed cleanup path. record.report is the same information without
%   device handles, for archiving with the run.
arguments
    devices
    options.Owner (1,1) string = "adaptive_optopatch"
end

record=struct("schema_version","1.0.0","owner",options.Owner, ...
    "claimed_at",string(datetime("now","TimeZone","local")), ...
    "devices",struct("name",{},"claimed",{},"handle",{}));
report=struct("name",{},"claimed",{},"supported",{}, ...
    "previous_auto_write_stack",{});

for k=1:numel(devices)
    device=devices(k);
    if isempty(device), continue; end
    name=string(read_member(device,"name",""));
    row=struct("name",name,"claimed",false,"supported",false, ...
        "previous_auto_write_stack",false);
    if ~ismethod(device,"Claim_Pattern_Ownership")
        % Recorded rather than passed over in silence: a run archives the
        % fact that this protection was not available on this device.
        warning("adaptive_optopatch:DmdOwnershipUnsupported", ...
            "%s does not support exclusive pattern ownership, so Luminos " + ...
            "acquisition startup could still reload its generic pattern " + ...
            "stack over the AO target.",name);
        report(end+1)=row; %#ok<AGROW>
        continue
    end
    try
        previous=device.Claim_Pattern_Ownership(options.Owner);
    catch exception
        % A partial claim is worse than none: the devices already taken
        % would keep their autoload suppressed with nobody left to give it
        % back. Unwind before letting the failure out.
        record.report=report;
        adaptive_optopatch.release_dmd_pattern_ownership(record);
        rethrow(exception)
    end
    row.supported=true;
    row.claimed=true;
    row.previous_auto_write_stack=logical(previous.auto_write_stack);
    record.devices(end+1)=struct("name",name,"claimed",true,"handle",device); %#ok<AGROW>
    report(end+1)=row; %#ok<AGROW>
end
record.report=report;
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
