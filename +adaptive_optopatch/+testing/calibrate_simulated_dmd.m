function calibrate_simulated_dmd(dmd,referenceCamera,transform)
%CALIBRATE_SIMULATED_DMD Give a simulated DMD a calibration AO will accept.
%   AO requires the transform a mask is projected through to be the one
%   stored for this DMD against the camera the plan's reference image came
%   from, so a fixture cannot simply assign tform: a transform with no
%   camera recorded is exactly the state validate_dmd_calibration_identity
%   refuses, and a fixture that could skip the pair store would be testing a
%   rig AO will not run on.
%
%   The transform value itself is arbitrary here. The simulated device's
%   setPatterningROI copies the mask rather than warping it - transform
%   arithmetic is tested against the real Patterning_Device, not against
%   this - so what these fixtures need from a calibration is its identity,
%   not its numbers.
arguments
    dmd
    referenceCamera (1,1) struct
    transform = affinetform2d([1.01 0 0;0 1.01 0;0 0 1])
end
cameraName=string(reference_camera_name(referenceCamera));
if strlength(cameraName)==0
    error("adaptive_optopatch:ReferenceCameraNotIdentified", ...
        "The fixture's reference_camera has no name, so there is no " + ...
        "camera to store a calibration against.");
end
metadata=struct("mode","fixture");
if isfield(referenceCamera,"bin"), metadata.bin=double(referenceCamera.bin); end
if isfield(referenceCamera,"roi"), metadata.roi=double(referenceCamera.roi); end
dmd.set_calibration_entry(cameraName,transform,metadata);
dmd.use_calibration_camera(cameraName);
end

function name=reference_camera_name(referenceCamera)
name="";
if isfield(referenceCamera,"name"), name=string(referenceCamera.name); end
end
