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
        dmd.Target = adaptive_optopatch.blank_dmd_pattern(dmd);
        if options.WriteDmdImmediately
            dmd.Write_Static();
            result = record_static_execution_state(result, dmd);
            % A blank is a programmed state like any other: an autoloaded
            % generic stack over the top of it would be stimulating light
            % during a trial that asked for none.
            result.owned_pattern_fingerprint = ...
                adaptive_optopatch.record_owned_dmd_pattern(dmd);
        end
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
    % Before anything reaches the mirrors: the transform this mask is about
    % to be warped through has to be the one measured for this DMD against
    % the camera the plan's reference image came from, not merely a
    % transform that exists and is the right shape.
    result.calibration_identity = ...
        adaptive_optopatch.validate_dmd_calibration_identity( ...
        dmd,targetBundle.reference_camera,options.DmdName);
    result.dmd_reference_mask= ...
        adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
        result.camera_mask,targetBundle.reference_camera,dmd,options.DmdName);
    dmd.setPatterningROI(result.dmd_reference_mask, ...
        "write_when_complete", options.WriteDmdImmediately);
    if options.WriteDmdImmediately
        % setPatterningROI returns 1 rather than the mask once it has
        % written, so the device-space pattern that actually reached
        % Device_Pattern is read back from Target, not from its return value.
        result = record_static_execution_state(result, dmd);
        result.owned_pattern_fingerprint = ...
            adaptive_optopatch.record_owned_dmd_pattern(dmd);
    end
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

function result = record_static_execution_state(result, dmd)
% Archive what the device is playing immediately after a static write, and
% refuse to go on if it positively reports something other than a single
% static pattern.
%
% A successful static write is expected to be self-sufficient:
% ALP_DMD::Project halts the device, frees whatever sequence was loaded -
% FLUT playlist included - allocates a one-picture sequence, restores master
% mode with stepping disabled and starts continuous projection. So no stop
% or reset is issued here. What is checked is the result rather than the
% intention, because a static write that threw leaves Target updated in
% MATLAB with the hardware still playing the previous sequence.
result.dmd_device_mask_summary= ...
    adaptive_optopatch.summarize_dmd_device_pattern(dmd);
result.dmd_state_after_programming= ...
    adaptive_optopatch.read_dmd_execution_state(dmd);
state = result.dmd_state_after_programming;
if state.contradicts_static_mode
    error("adaptive_optopatch:DmdNotInStaticMode", ...
        ['The Blue DMD was programmed with a static target but reports ' ...
         'projection mode "%s" with %s picture(s) in the loaded sequence, ' ...
         'not a single static pattern. A stale sequence is still loaded, ' ...
         'so the displayed pattern is not the one just written. Blank the ' ...
         'DMD and reload before stimulating.'], ...
        state.projection_mode_name, num2str(state.sequence_pictures));
end
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
