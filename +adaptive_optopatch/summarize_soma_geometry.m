function summary=summarize_soma_geometry(geometry)
%SUMMARIZE_SOMA_GEOMETRY Per-cell area, centroid, edge distance, and QC.
%   This is the QC arithmetic the cell table used to perform on
%   drawpolygon positions. It is canonical, so the table and any future
%   frontend read the same numbers.
arguments
    geometry (1,1) struct
end
masks=adaptive_optopatch.soma_polygon_masks(geometry);
n=numel(geometry.polygons);
summary=repmat(struct("cell_id","","area_pixels",0, ...
    "centroid_xy",[NaN NaN],"edge_distance_pixels",-1, ...
    "qc_status","CHECK"),n,1);
if n==0, return; end
overlap=sum(masks,3)>1;
for k=1:n
    mask=masks(:,:,k);
    [y,x]=find(mask);
    summary(k).cell_id=geometry.cell_ids(k);
    if isempty(x), continue; end
    summary(k).area_pixels=numel(x);
    summary(k).centroid_xy=[mean(x) mean(y)];
    summary(k).edge_distance_pixels=min([min(x)-1,size(mask,2)-max(x), ...
        min(y)-1,size(mask,1)-max(y)]);
    if summary(k).edge_distance_pixels>=2 && ~any(overlap & mask,"all")
        summary(k).qc_status="PASS";
    end
end
end
