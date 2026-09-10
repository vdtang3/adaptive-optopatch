function report=validate_camera_geometry(camera,targets)
%VALIDATE_CAMERA_GEOMETRY Require the live frame grid to be the frozen one.
%   Canonical ROIs, Blue and Orange masks, and every camera-pixel target
%   coordinate are expressed on the reference snapshot's pixel grid. If the
%   voltage camera acquires on a different grid - a different sub-ROI origin,
%   a different frame size, or different binning - then pixel (r,c) of the
%   acquired movie is no longer the same sensor region as pixel (r,c) of the
%   reference, so the recorded traces cannot be attributed to the canonical
%   cells and the frozen geometry is invalid. That is a data-integrity
%   failure, so it is detected before any output rather than after the
%   acquisition (extract_roi_traces already refuses such a movie).
arguments
    camera
    targets (1,1) struct
end
if ~isfield(targets,"reference_camera")
    error("adaptive_optopatch:MissingReferenceCameraGeometry", ...
        ['This planning bundle predates frozen camera geometry, so the ' ...
         'acquired frames cannot be checked against the reference grid. ' ...
         'Regenerate the bundle from the Camera 1 Snap using the current ' ...
         'planning GUI.']);
end
frozen=targets.reference_camera;
roi=double(read_member(camera,"ROI",[]));
if numel(roi)~=4 || any(~isfinite(roi))
    error("adaptive_optopatch:LiveCameraGeometryUnavailable", ...
        ['The live voltage camera does not report a usable [left width top ' ...
         'height] ROI, so the frozen targeting grid cannot be confirmed.']);
end
bin=double(read_member(camera,"bin",NaN));
if ~isscalar(bin) || ~isfinite(bin) || bin<=0
    error("adaptive_optopatch:LiveCameraGeometryUnavailable", ...
        "The live voltage camera does not report a usable binning factor.");
end
liveFrameSize=[roi(4) roi(2)];
liveOrigin=[roi(1) roi(3)];
frozenFrameSize=double(frozen.image_size(1:2));
frozenOrigin=double(frozen.origin_xy);
frozenBin=double(frozen.bin);
issues=strings(0,1);
if ~isequal(round(liveFrameSize),round(frozenFrameSize))
    issues(end+1,1)=sprintf( ...
        "Live frames are %gx%g but the frozen reference grid is %gx%g.", ...
        liveFrameSize(1),liveFrameSize(2),frozenFrameSize(1),frozenFrameSize(2));
end
if any(abs(liveOrigin-frozenOrigin)>0.5)
    issues(end+1,1)=sprintf( ...
        "The live sensor ROI starts at [%g %g] but the reference starts at [%g %g].", ...
        liveOrigin(1),liveOrigin(2),frozenOrigin(1),frozenOrigin(2));
end
if abs(bin-frozenBin)>1e-9
    issues(end+1,1)=sprintf( ...
        "The live camera is binned %gx but the reference was captured at %gx.", ...
        bin,frozenBin);
end
if ~isempty(issues)
    error("adaptive_optopatch:CameraGeometryChangedSinceFreeze","%s", ...
        strjoin(["The voltage camera no longer matches the frozen targeting " + ...
        "geometry, so the frozen ROIs and masks do not describe the acquired " + ...
        "frames. Restore the reference camera configuration or plan a new " + ...
        "run from a current Snap.";issues],newline));
end
report=struct("schema_version","1.0.0","passed",true, ...
    "frame_size",liveFrameSize,"origin_xy",liveOrigin,"bin",bin, ...
    "reference_frame_size",frozenFrameSize, ...
    "reference_origin_xy",frozenOrigin,"reference_bin",frozenBin);
end

function value=read_member(object,name,defaultValue)
value=defaultValue;
try
    if isstruct(object) && isfield(object,name)
        value=object.(name);
    elseif isobject(object) && isprop(object,name)
        value=object.(name);
    end
catch
end
if isempty(value), value=defaultValue; end
end
