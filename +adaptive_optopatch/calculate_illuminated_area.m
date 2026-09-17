function area=calculate_illuminated_area(pixel_to_sample_um,mask)
%CALCULATE_ILLUMINATED_AREA Physical area of a footprint on a calibrated snap.
%   The determinant of the saved 2x2 is the area scale factor of the linear
%   pixel -> sample map, so
%
%       pixel_area_um2 = abs(det(J))
%       area_um2       = nnz(mask) * pixel_area_um2
%
%   handles unequal X/Y scale, camera rotation and moderate shear with no
%   special cases. J is never collapsed to a scalar um/pixel: that would give
%   s^2 where the truth is s_x*s_y, and on an anisotropic rig the area error is
%   first order.
%
%   The bounding-box edge lengths are a SANITY CHECK only - useful for seeing
%   that a nominal 100 x 100 um patch came back about 100 um across. Their
%   product is not the area and must not be used as one, because the footprint
%   is not a rectangle and the box is axis-aligned in pixels, not in the sample
%   plane.
arguments
    pixel_to_sample_um (2,2) double {mustBeFinite}
    mask {mustBeNumericOrLogical,mustBeNonempty}
end

J=double(pixel_to_sample_um);
if abs(det(J))<=0
    error("adaptive_optopatch:SingularPhysicalCalibration", ...
        "pixel_to_sample_um is singular, so the footprint would have zero area.");
end

mask=logical(mask);
pixel_area_um2=abs(det(J));
illuminated_pixels=nnz(mask);
area_um2=illuminated_pixels*pixel_area_um2;

% Pixel steps are [dcolumn; drow], matching the snap transform's convention.
[rows,columns]=find(mask);
if isempty(rows)
    width_px=0;
    height_px=0;
else
    width_px=max(columns)-min(columns)+1;
    height_px=max(rows)-min(rows)+1;
end

area=struct( ...
    "pixel_to_sample_um",J, ...
    "pixel_area_um2",pixel_area_um2, ...
    "illuminated_pixels",illuminated_pixels, ...
    "area_um2",area_um2, ...
    "area_mm2",area_um2/1e6, ...
    "equivalent_square_side_um",sqrt(area_um2), ...
    "bounding_width_px",width_px, ...
    "bounding_height_px",height_px, ...
    "bounding_width_um",norm(J*[width_px;0]), ...
    "bounding_height_um",norm(J*[0;height_px]));
end
