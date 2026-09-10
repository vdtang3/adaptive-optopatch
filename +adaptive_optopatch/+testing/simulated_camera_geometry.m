function options=simulated_camera_geometry(bundleFolder)
%SIMULATED_CAMERA_GEOMETRY Camera options matching a bundle's frozen grid.
%   A simulated rig has no real sensor, so a simulated runner adopts the
%   acquisition grid the bundle it is replaying was planned on. The runners
%   then apply the same camera-geometry invariant they apply on hardware.
arguments
    bundleFolder (1,1) string
end
options={};
path=fullfile(bundleFolder,"pattern_bundle.mat");
if ~isfile(path), return; end
saved=load(path,"targets");
if ~isfield(saved,"targets") || ~isfield(saved.targets,"reference_camera")
    return
end
geometry=saved.targets.reference_camera;
options={"CameraRoi",double(geometry.roi),"CameraBin",double(geometry.bin)};
end
