function report=validate_2p_planning_bundle(targets)
%VALIDATE_2P_PLANNING_BUNDLE Reject pre-full-sensor-coordinate bundles.
arguments
    targets (1,1) struct
end
issues=strings(0,1);
if ~isfield(targets,"schema_version") || ...
        ~ismember(string(targets.schema_version),["0.2.0","1.0.0"])
    issues(end+1)=["This bundle predates the full-sensor camera-coordinate " + ...
        "fix (required target schema 0.2.0 or newer)."];
end
if ~isfield(targets,"coordinate_space") || ...
        string(targets.coordinate_space)~="voltage_camera_full_sensor_pixels"
    issues(end+1)=["Target coordinates are not labeled as full Camera 1 " + ...
        "sensor pixels."];
end
if ~isfield(targets,"targets") || isempty(targets.targets)
    issues(end+1)="The bundle contains no targets.";
else
    required=["spiral_center_xy","spiral_radius_pixels", ...
        "parking_point_xy","spiral_preview_center_xy", ...
        "parking_preview_point_xy"];
    for name=required
        if ~isfield(targets.targets,name)
            issues(end+1)="Targets are missing field "+name+".";
        end
    end
end
report=struct("schema_version","0.1.0","passed",isempty(issues), ...
    "issues",issues);
end
