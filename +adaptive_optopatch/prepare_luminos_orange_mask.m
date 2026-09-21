function configuration=prepare_luminos_orange_mask(app,targets,options)
%PREPARE_LUMINOS_ORANGE_MASK Program the explicit VU recording DMD.
arguments
    app
    targets (1,1) struct
    options.DryRun (1,1) logical = true
    options.Profile (1,1) struct = adaptive_optopatch.virtual_upright_1p_profile()
end
if ~isfield(targets,"orange_combined_mask") || ...
        ~isfield(targets,"orange_camera_masks")
    error("adaptive_optopatch:MissingOrangeMask", ...
        "The target bundle does not contain derived Orange recording masks.");
end
profile=options.Profile;
if isempty(app)
    error("adaptive_optopatch:MissingLuminosApp", ...
        "A live Luminos app object is required to send the Orange mask.");
end
if ~isfield(profile,"orange_dmd") || strlength(string(profile.orange_dmd.name))==0
    error("adaptive_optopatch:OrangeDmdNotDeclared", ...
        "The active rig profile does not declare an Orange DMD.");
end
dmd=app.getDevice("DMD","name",profile.orange_dmd.name,"displayWarning",false);
if isempty(dmd)
    error("adaptive_optopatch:RequiredDeviceMissing", ...
        "Required Luminos device '%s' (DMD) was not found.",profile.orange_dmd.name);
end
if numel(dmd)~=1
    error("adaptive_optopatch:AmbiguousDevice", ...
        "Expected one Luminos DMD named '%s', found %d.",profile.orange_dmd.name,numel(dmd));
end
if isempty(dmd.refimage)
    error("adaptive_optopatch:UncalibratedOrangeDmd", ...
        "DMD_Orange requires a calibration reference image.");
end
enabled=arrayfun(@(target)logical(target.recording_enabled),targets.targets);
configuration=struct("schema_version","1.0.0", ...
    "dmd_name",string(profile.orange_dmd.name),"loaded",false, ...
    "recording_cell_ids",string({targets.targets(enabled).cell_id}), ...
    "recording_cell_count",sum(enabled), ...
    "orange_expansion_pixels",targets.parameters.orange_expansion_pixels, ...
    "camera_mask",logical(targets.orange_combined_mask));
if options.DryRun, return; end
% Validated independently of the Blue DMD: they are separate devices with
% separate per-camera calibration stores, and a recording mask projected
% through the wrong camera's transform mislabels which cells were recorded
% just as surely as a wrong stimulation mask mistargets them.
configuration.calibration_identity= ...
    adaptive_optopatch.validate_dmd_calibration_identity( ...
    dmd,targets.reference_camera,string(profile.orange_dmd.name));
configuration.dmd_reference_mask= ...
    adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
    configuration.camera_mask,targets.reference_camera,dmd,profile.orange_dmd.name);
dmd.setPatterningROI(configuration.dmd_reference_mask, ...
    "write_when_complete",true);
% device_mask is what ORANGE WAS ACTUALLY PROGRAMMED WITH, read back from the
% device rather than taken from the call that programmed it.
%
% setPatterningROI returns the warped mask only when it is asked NOT to write.
% With write_when_complete true it puts the mask in Target, calls
% Write_Static, and returns the scalar 1 - so the return value was being
% archived as `device_mask = true`, and the one field whose job is to say what
% Orange received could not say anything at all. Nothing about the
% illumination was wrong; the provenance of it was missing, which is worse to
% discover later than a value that is visibly absent.
%
% Target is the canonical programmed mask - the same property Blue's
% summarize_dmd_device_pattern reads, at the same >.5 threshold, so the two
% devices' provenance means the same thing. Read after the write rather than
% before it, so a write that threw cannot leave a mask archived as programmed.
%
% This is archival state and nothing else. It does NOT check that the pattern
% survives to the trigger: that is owned_pattern_fingerprint below, together
% with Luminos's acquisition-time verification, and the two are kept apart on
% purpose - one says what was sent, the other says what is still there.
configuration.device_mask=logical(dmd.Target>.5);
configuration.device_mask_summary= ...
    adaptive_optopatch.summarize_dmd_device_pattern(dmd);
configuration.owned_pattern_fingerprint= ...
    adaptive_optopatch.record_owned_dmd_pattern(dmd);
configuration.loaded=true;
configuration.programmed_at=string(datetime("now","TimeZone","local"));
end
