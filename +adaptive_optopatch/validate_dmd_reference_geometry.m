function report=validate_dmd_reference_geometry(dmd,referenceCamera,dmdName)
%VALIDATE_DMD_REFERENCE_GEOMETRY Confirm an AO grid fits a DMD reference.
% Different ROI sizes and origins are valid. The current AO grid must be an
% integer-aligned, fully contained crop of the active Luminos DMD refimage.
arguments
    dmd
    referenceCamera (1,1) struct
    dmdName (1,1) string
end
refimage=read_member(dmd,"refimage",[]);
image=read_member(refimage,"img",[]);
ref2d=read_member(refimage,"ref2d",[]);
refBin=double(read_member(refimage,"bin",NaN));
xLimits=double(read_member(ref2d,"XWorldLimits",[]));
yLimits=double(read_member(ref2d,"YWorldLimits",[]));
if isempty(image) || isempty(ref2d) || ~isscalar(refBin) || ...
        ~isfinite(refBin) || refBin<=0 || numel(xLimits)~=2 || numel(yLimits)~=2
    error("adaptive_optopatch:DmdReferenceGeometryUnavailable", ...
        "%s has no usable reference-image dimensions, origin, and binning.",dmdName);
end
refSize=double(size(image,1:2));
refOrigin=[xLimits(1) yLimits(1)];
refExtent=[diff(xLimits) diff(yLimits)];
if any(~isfinite([refSize refOrigin refExtent])) || ...
        any(refSize<=0) || any(abs(refExtent-refSize([2 1])*refBin)>0.5)
    error("adaptive_optopatch:DmdReferenceGeometryUnavailable", ...
        "%s reference-image world limits are inconsistent with its size and binning.", ...
        dmdName);
end

required=["image_size","origin_xy","bin"];
if ~all(isfield(referenceCamera,cellstr(required)))
    error("adaptive_optopatch:MissingReferenceCameraGeometry", ...
        "The frozen target bundle has incomplete camera geometry.");
end
currentSize=double(referenceCamera.image_size(1:2));
currentOrigin=double(referenceCamera.origin_xy);
currentBin=double(referenceCamera.bin);
if any(~isfinite([currentSize currentOrigin currentBin])) || ...
        any(currentSize<=0) || currentBin<=0
    error("adaptive_optopatch:MissingReferenceCameraGeometry", ...
        "The frozen target bundle has malformed camera geometry.");
end
currentRoi=[currentOrigin currentSize([2 1])*currentBin];
refRoi=[refOrigin refExtent];
detail=sprintf("Current ROI [%g %g %g %g], %gx bin; %s reference ROI [%g %g %g %g], %gx bin.", ...
    currentRoi,currentBin,dmdName,refRoi,refBin);
if abs(currentBin-refBin)>1e-9
    error("adaptive_optopatch:DmdReferenceBinningMismatch", ...
        "Current camera and %s reference binning cannot be mapped exactly. %s", ...
        dmdName,detail);
end
offset=(currentOrigin-refOrigin)/refBin;
if any(abs(offset-round(offset))>1e-9)
    error("adaptive_optopatch:DmdReferenceGridMisaligned", ...
        "Current camera pixels are not integer-aligned to the %s reference grid. %s", ...
        dmdName,detail);
end
currentEnd=currentOrigin+currentSize([2 1])*currentBin;
refEnd=refOrigin+refExtent;
if any(currentOrigin<refOrigin-0.5) || any(currentEnd>refEnd+0.5)
    error("adaptive_optopatch:DmdReferenceDoesNotCoverCameraRoi", ...
        "Current camera ROI is not fully covered by %s calibration reference. %s", ...
        dmdName,detail);
end
report=struct("schema_version","1.0.0","passed",true, ...
    "dmd_name",dmdName,"current_roi",currentRoi,"current_bin",currentBin, ...
    "reference_roi",refRoi,"reference_bin",refBin, ...
    "reference_image_size",refSize,"offset_pixels_xy",round(offset));
end

function value=read_member(object,name,defaultValue)
value=defaultValue;
if isempty(object), return; end
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
