function report=validate_2p_calibration_coverage(target,artifact)
%VALIDATE_2P_CALIBRATION_COVERAGE Prevent unsafe affine extrapolation.
arguments
    target (1,1) struct
    artifact (1,1) struct
end
issues=strings(0,1);
calibration=artifact;
if isfield(artifact,"calibration"), calibration=artifact.calibration; end
sampled=zeros(0,2); query=zeros(0,2); inside=false(0,1); hull=[];
if ~isfield(calibration,"camera_pixels") || ...
        size(calibration.camera_pixels,1)<3
    issues(end+1)="Calibration artifact does not contain its sampled camera points.";
    report=finish(); return
end
sampled=double(calibration.camera_pixels);
theta=linspace(0,2*pi,33)'; theta(end)=[];
center=double(target.spiral_center_xy);
radius=double(target.spiral_radius_pixels);
spiralBoundary=center+radius*[cos(theta) sin(theta)];
parking=double(target.parking_point_xy);
query=[center;spiralBoundary;parking];
try
    hull=convhull(sampled(:,1),sampled(:,2));
    inside=inpolygon(query(:,1),query(:,2),sampled(hull,1),sampled(hull,2));
catch exception
    issues(end+1)="Could not construct calibration coverage: "+string(exception.message);
    inside=false(size(query,1),1); hull=[];
end
if ~inside(1)
    issues(end+1)="Target center is outside the region sampled by the galvo calibration.";
end
if any(~inside(2:end-1))
    issues(end+1)="Part of the requested spiral is outside the calibrated region.";
end
if ~inside(end)
    issues(end+1)="The dark parking point is outside the calibrated region.";
end
report=finish();

    function value=finish()
        value=struct("schema_version","0.1.0","passed",isempty(issues), ...
            "issues",issues,"sampled_camera_pixels",sampled, ...
            "query_camera_pixels",query,"query_inside",inside, ...
            "hull_indices",hull);
    end
end
