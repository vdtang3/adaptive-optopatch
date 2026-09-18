function release_dmd_pattern_ownership(record)
%RELEASE_DMD_PATTERN_OWNERSHIP Give the DMDs back with their settings intact.
%   Restores each device's auto_write_stack to the value the claim replaced,
%   so a rig that was autoloading its DMD-tab stack before an AO run is
%   autoloading it again afterwards. Called from cleanup, which runs after a
%   failure and after a Ctrl-C as well as after success, so every step is
%   guarded: one device that will not release must not stop the next one.
arguments
    record (1,1) struct
end
if ~isfield(record,"devices"), return; end
for k=1:numel(record.devices)
    entry=record.devices(k);
    if ~entry.claimed, continue; end
    try
        entry.handle.Release_Pattern_Ownership(record.owner);
    catch exception
        warning("adaptive_optopatch:DmdOwnershipReleaseFailed", ...
            "Could not release %s back to Luminos (%s). Its Write Stack " + ...
            "setting may still be suppressed; reopen the DMD tab to check.", ...
            entry.name,exception.message);
    end
end
end
