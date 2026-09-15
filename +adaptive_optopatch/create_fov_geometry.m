function geometry=create_fov_geometry(imageSize)
%CREATE_FOV_GEOMETRY Empty canonical soma geometry for one FOV.
%   Canonical soma geometry is the UI-independent source of truth for
%   polygon vertices and stable cell identity. Vertices are snapshot/FOV
%   intrinsic pixel coordinates (1-based, pixel centres at integers), the
%   convention poly2mask and the reference model already use.
arguments
    imageSize (1,2) double {mustBeNonnegative} = [0 0]
end
geometry=struct("image_size",double(imageSize), ...
    "polygons",{cell(0,1)},"cell_ids",strings(0,1),"next_cell_index",1);
end
