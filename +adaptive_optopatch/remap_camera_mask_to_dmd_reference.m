function [mapped,geometry]=remap_camera_mask_to_dmd_reference( ...
        mask,currentCamera,dmd,dmdName)
%REMAP_CAMERA_MASK_TO_DMD_REFERENCE Embed an ROI-local mask on a DMD camera grid.
arguments
    mask (:,:) {mustBeNumericOrLogical}
    currentCamera (1,1) struct
    dmd
    dmdName (1,1) string
end
expectedSize=double(currentCamera.image_size(1:2));
if ~isequal(double(size(mask,1:2)),expectedSize)
    error("adaptive_optopatch:CameraMaskSizeMismatch", ...
        "The %s camera mask is %gx%g but its current camera grid is %gx%g.", ...
        dmdName,size(mask,1),size(mask,2),expectedSize(1),expectedSize(2));
end
geometry=adaptive_optopatch.validate_dmd_reference_geometry( ...
    dmd,currentCamera,dmdName);
offset=geometry.offset_pixels_xy;
rows=offset(2)+(1:size(mask,1));
columns=offset(1)+(1:size(mask,2));
if rows(1)<1 || columns(1)<1 || ...
        rows(end)>geometry.reference_image_size(1) || ...
        columns(end)>geometry.reference_image_size(2)
    error("adaptive_optopatch:DmdReferenceDoesNotCoverCameraRoi", ...
        "Current camera mask cannot be represented without clipping on %s.",dmdName);
end
mapped=false(geometry.reference_image_size);
mapped(rows,columns)=logical(mask);
if nnz(mapped)~=nnz(mask)
    error("adaptive_optopatch:DmdMaskRemappingLostPixels", ...
        "%s camera-mask remapping changed the illuminated pixel count.",dmdName);
end
end
