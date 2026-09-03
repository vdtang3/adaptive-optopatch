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
if isempty(dmd.tform) || is_identity_transform(dmd.tform) || isempty(dmd.refimage)
    error("adaptive_optopatch:UncalibratedOrangeDmd", ...
        "DMD_Orange requires a nonidentity camera transform and calibration reference image.");
end
enabled=arrayfun(@(target)logical(target.recording_enabled),targets.targets);
configuration=struct("schema_version","1.0.0", ...
    "dmd_name",string(profile.orange_dmd.name),"loaded",false, ...
    "recording_cell_ids",string({targets.targets(enabled).cell_id}), ...
    "recording_cell_count",sum(enabled), ...
    "orange_expansion_pixels",targets.parameters.orange_expansion_pixels, ...
    "camera_mask",logical(targets.orange_combined_mask));
if options.DryRun, return; end
transformed=dmd.setPatterningROI(configuration.camera_mask, ...
    "write_when_complete",true);
configuration.device_mask=logical(transformed);
configuration.loaded=true;
configuration.programmed_at=string(datetime("now","TimeZone","local"));
end

function tf=is_identity_transform(tform)
if isa(tform,"affinetform2d") || isa(tform,"projtform2d")
    matrix=tform.A;
elseif isa(tform,"affine2d") || isa(tform,"projective2d")
    matrix=tform.T';
else
    tf=false; return
end
tf=norm(double(matrix)-eye(3),"fro")<1e-9;
end
