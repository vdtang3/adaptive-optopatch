function result = prepare_luminos_target(app, targetBundle, trialRow, options)
%PREPARE_LUMINOS_TARGET Guarded adapter for a live Luminos app.
arguments
    app
    targetBundle (1,1) struct
    trialRow (1,:) table
    options.DryRun (1,1) logical = true
    options.DmdName (1,1) string = "DMD_Blue"
    options.ScannerName (1,1) string = "Chameleon (To friends: Ben)"
    options.AllowIdentityScannerTransform (1,1) logical = false
    options.WriteDmdImmediately (1,1) logical = false
    options.GalvoDriverVoltsPerDegree (1,1) double {mustBeMember(options.GalvoDriverVoltsPerDegree,[0.5 0.8 1.0])} = 0.5
end

if height(trialRow) ~= 1
    error("adaptive_optopatch:SingleTrialRequired", ...
        "trialRow must contain exactly one manifest row.");
end

result = struct("dry_run", options.DryRun, ...
    "mode", string(trialRow.stimulation_mode), ...
    "target_cell_id", string(trialRow.target_cell_id), ...
    "configured", false);

if trialRow.is_null
    result.action = "blank";
    if options.DryRun, return; end
    if result.mode == "1p_dmd"
        dmd = app.getDevice("DMD", "name", options.DmdName);
        dmd.Target = false(dmd.Dimensions);
        if options.WriteDmdImmediately, dmd.Write_Static(); end
    end
    result.configured = true;
    return
end

t = targetBundle.targets(trialRow.target_index);
if result.mode == "1p_dmd"
    result.action = "camera_mask_to_dmd";
    result.camera_mask = targetBundle.dmd_camera_masks(:,:,trialRow.target_index);
    if options.DryRun, return; end
    dmd = app.getDevice("DMD", "name", options.DmdName);
    dmd.setPatterningROI(result.camera_mask, ...
        "write_when_complete", options.WriteDmdImmediately);
elseif result.mode == "2p_spiral"
    result.action = "camera_center_to_spiral";
    result.center_xy = t.spiral_center_xy;
    result.radius_pixels = t.spiral_radius_pixels;
    result.density_points_per_volt = t.spiral_density_points_per_volt;
    result.parking_point_xy = t.parking_point_xy;
    result.parking_qc_pass = t.parking_qc_pass;
    if options.DryRun, return; end
    scanner = app.getDevice("Scanning_Device", "name", options.ScannerName);
    if isempty(scanner.tform)
        error("adaptive_optopatch:MissingScannerTransform", ...
            "The live scanner has no calibration transform.");
    end
    if ~options.AllowIdentityScannerTransform && is_identity_transform(scanner.tform)
        error("adaptive_optopatch:IdentityScannerTransform", ...
            "Refusing 2P targeting with an identity scanner transform.");
    end
    if scanner.fixed_rep_rate_flag
        error("adaptive_optopatch:DensityOverriddenByFixedRate", ...
            ["Luminos fixed_rep_rate_flag is enabled, so it will derive and " ...
             "override Points_Per_Volt. Disable fixed repetition rate before " ...
             "using the requested spiral density."]);
    end
    scanner.Points_Per_Volt = result.density_points_per_volt;
    spiral = struct("centerx",result.center_xy(1), ...
        "centery",result.center_xy(2),"radius",result.radius_pixels);
    scanner.Gen_Spiral_JS(spiral);
    [xContinuous,yContinuous] = adaptive_optopatch.append_continuous_spiral_return( ...
        scanner.galvox_wfm(:),scanner.galvoy_wfm(:),scanner.roi_meta.trans_center);
    result.galvo_preflight=adaptive_optopatch.evaluate_galvo_waveform( ...
        xContinuous,yContinuous,scanner.sample_rate, ...
        "CommandBoundsVolts",[scanner.vbounds(1) scanner.vbounds(3)], ...
        "DriverVoltsPerDegree",options.GalvoDriverVoltsPerDegree);
    if ~result.galvo_preflight.passed
        error("adaptive_optopatch:GalvoPreflightFailed","%s", ...
            strjoin(result.galvo_preflight.issues,newline));
    end
    scanner.Update_Galvos_Explicit(xContinuous,yContinuous);
    result.native_spiral_samples = (numel(xContinuous)+1)/2;
    result.continuous_spiral_samples = numel(xContinuous);
    result.spiral_repetition_rate_hz = scanner.sample_rate/numel(xContinuous);
else
    error("adaptive_optopatch:UnknownMode", ...
        "Unknown stimulation mode: %s", result.mode);
end
result.configured = true;
end

function tf = is_identity_transform(tform)
if isa(tform,"affinetform2d") || isa(tform,"projtform2d")
    A = tform.A;
elseif isa(tform,"affine2d") || isa(tform,"projective2d")
    A = tform.T';
else
    tf = false;
    return
end
tf = norm(A-eye(3),"fro") < 1e-9;
end
