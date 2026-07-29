function report=validate_galvo_calibration_artifact(artifact,app)
%VALIDATE_GALVO_CALIBRATION_ARTIFACT Check identity, QC, and live rig match.
arguments
    artifact (1,1) struct
    app = []
end
issues=strings(0,1);
required=["calibration_id","rig_name","camera_serial","scanner_name", ...
    "scanner_x_port","scanner_y_port","calibration"];
for name=required
    if ~isfield(artifact,name), issues(end+1)="Missing artifact field "+name+"."; end
end
if ~isempty(issues)
    report=struct("passed",false,"issues",issues); return
end
c=artifact.calibration;
if ~isfield(c,"passed") || ~logical(c.passed)
    issues(end+1)="Calibration did not pass its saved QC.";
end
if ~isfield(c,"transform_direction") || ...
        string(c.transform_direction)~="galvo_volts_to_camera_pixels"
    issues(end+1)="Unexpected scanner transform direction.";
end
if ~isfield(c,"held_out_rmse_pixels") || ~isfinite(c.held_out_rmse_pixels)
    issues(end+1)="Held-out calibration QC is missing.";
end
profile=adaptive_optopatch.virtual_upright_2p_profile();
if string(artifact.rig_name)~="Virtual_Upright" || ...
        string(artifact.camera_serial)~="001125"
    issues(end+1)="Calibration belongs to a different rig or camera.";
end
if string(artifact.scanner_name)~=profile.scanner.name || ...
        string(artifact.scanner_x_port)~=profile.scanner.x_port || ...
        string(artifact.scanner_y_port)~=profile.scanner.y_port
    issues(end+1)="Calibration scanner identity or ports do not match the VU profile.";
end
if isfield(c,"galvo_volts") && isfield(c,"camera_pixels")
    try
        recovered=adaptive_optopatch.camera_to_galvo_volts(c.tform,c.camera_pixels);
        if max(abs(recovered-c.galvo_volts),[],"all")>1e-6
            issues(end+1)="Saved transform fails inverse-coordinate validation.";
        end
    catch exception
        issues(end+1)="Transform validation failed: "+string(exception.message);
    end
end
if ~isempty(app)
    try
        cameras=app.getDevice("Camera");
        serials=arrayfun(@(camera)strip(erase(string(camera.cam_id),"S/N: ")),cameras);
        if ~any(serials==string(artifact.camera_serial))
            issues(end+1)="The calibrated Camera 1 serial is absent from the live rig.";
        end
        scanner=app.getDevice("Scanning_Device","name",artifact.scanner_name);
        if numel(scanner)~=1 || string(scanner.galvox_physport)~=artifact.scanner_x_port || ...
                string(scanner.galvoy_physport)~=artifact.scanner_y_port
            issues(end+1)="The live scanner does not match the calibration artifact.";
        end
    catch exception
        issues(end+1)="Live rig validation failed: "+string(exception.message);
    end
end
report=struct("schema_version","0.1.0","passed",isempty(issues), ...
    "issues",issues,"calibration_id",string(artifact.calibration_id));
end
