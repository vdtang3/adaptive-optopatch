function masks=soma_polygon_masks(geometry)
%SOMA_POLYGON_MASKS Rasterize canonical soma polygons into FOV pixel space.
%   poly2mask interprets the vertices in the same intrinsic pixel
%   convention the polygons are stored in, so no coordinate conversion
%   happens here and cropped-FOV geometry is preserved exactly.
arguments
    geometry (1,1) struct
end
rows=geometry.image_size(1); columns=geometry.image_size(2);
masks=false([rows columns numel(geometry.polygons)]);
for k=1:numel(geometry.polygons)
    p=geometry.polygons{k};
    if isempty(p), continue; end
    masks(:,:,k)=poly2mask(p(:,1),p(:,2),rows,columns);
end
end
