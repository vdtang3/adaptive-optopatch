function report=validate_dmd_calibration_identity(dmd,referenceCamera,dmdName)
%VALIDATE_DMD_CALIBRATION_IDENTITY Require the active DMD calibration to be this pair's.
%   Luminos holds one camera-to-DMD calibration per patterning-device/camera
%   pair, but projection goes through a single active transform, dmd.tform.
%   Those come apart. Patterning_Device.use_calibration_camera changes the
%   selected camera and leaves dmd.tform alone when the newly selected pair
%   has no stored entry, so the transform the mirrors are driven through can
%   have been measured against a different camera entirely.
%
%   Nothing about the transform itself gives that away, which is why this
%   check exists and why it does not use any of the things that look like
%   evidence. A wrong-camera transform on the same microscope is nonidentity,
%   is a well-conditioned 3x3, and warps a reference-sized mask to a
%   device-sized one without complaint; the AO geometry checks pass because
%   dimensions, origin and binning still agree; and the camera-space preview
%   is drawn before the transform is applied, so it looks right. The only
%   record that ties a transform to a camera is the per-pair store, so that
%   is what is read.
%
%   Fails closed. AO cannot tell a missing calibration from a wrong one by
%   looking at the projection, and the experimenter can: the message says
%   which pair to calibrate.
arguments
    dmd
    referenceCamera (1,1) struct
    dmdName (1,1) string
end

cameraName=string(field_or(referenceCamera,"name",""));
if strlength(cameraName)==0
    error("adaptive_optopatch:ReferenceCameraNotIdentified", ...
        "The frozen reference does not record which camera it was taken " + ...
        "with, so the %s calibration cannot be attributed to a camera. " + ...
        "Plan a new run from a current Snap.",dmdName);
end

if ~ismethod(dmd,"calibration_identity")
    error("adaptive_optopatch:DmdCalibrationIdentityUnavailable", ...
        "%s cannot report which camera its active calibration belongs to " + ...
        "(no calibration_identity method). Update Luminos before " + ...
        "projecting an AO target through it.",dmdName);
end
identity=dmd.calibration_identity(cameraName);

report=struct("schema_version","1.0.0","passed",false, ...
    "dmd_name",dmdName,"camera",cameraName,"identity",identity);

if ~identity.has_pair_calibration
    error("adaptive_optopatch:MissingDmdCameraCalibration", ...
        "%s has no stored calibration against camera ""%s"", which is the " + ...
        "camera this plan's reference image was taken with. Luminos is " + ...
        "currently projecting %s through ""%s"". Calibrate %s against " + ...
        """%s"" in the patterning tab and plan again.", ...
        dmdName,cameraName,dmdName,describe_selected(identity),dmdName,cameraName);
end

if ~identity.active_transform_is_pair_transform
    error("adaptive_optopatch:DmdCalibrationCameraMismatch", ...
        "%s holds a calibration for camera ""%s"", but the transform it is " + ...
        "currently projecting through is not that one (the calibration " + ...
        "selector is on %s). Select ""%s"" in the %s calibration controls, " + ...
        "or recalibrate, before running. The pattern would otherwise land " + ...
        "somewhere other than where the preview shows it.", ...
        dmdName,cameraName,describe_selected(identity),cameraName,dmdName);
end

if is_identity_transform(identity.pair_transform)
    error("adaptive_optopatch:UncalibratedDmd", ...
        "The stored %s calibration for camera ""%s"" is the identity " + ...
        "transform, which is not a calibration. Calibrate %s against " + ...
        """%s"" before running.",dmdName,cameraName,dmdName,cameraName);
end

report.passed=true;
end

function text=describe_selected(identity)
selected=string(identity.selected_camera);
if strlength(selected)==0
    text="a transform with no camera recorded";
else
    text=""""+selected+"""";
end
end

function value=field_or(record,name,default)
value=default;
if isfield(record,name) && ~isempty(record.(name)), value=record.(name); end
end

function tf=is_identity_transform(tform)
if isa(tform,"affinetform2d") || isa(tform,"projtform2d")
    matrix=double(tform.A);
elseif isa(tform,"affine2d") || isa(tform,"projective2d")
    matrix=double(tform.T)';
elseif isnumeric(tform) && isequal(size(tform),[3 3])
    matrix=double(tform);
else
    tf=false; return
end
tf=norm(matrix/matrix(end,end)-eye(3),"fro")<1e-9;
end
