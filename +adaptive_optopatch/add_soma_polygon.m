function [geometry,cellId]=add_soma_polygon(geometry,verticesXy)
%ADD_SOMA_POLYGON Append one canonical soma polygon with a stable cell ID.
%   Cell IDs come from next_cell_index and are never reused, so an ID
%   stays attached to the same soma across edits, deletions, and reloads.
arguments
    geometry (1,1) struct
    verticesXy (:,2) double
end
vertices=adaptive_optopatch.validate_soma_polygon(verticesXy);
cellId=compose("cell_%03d",geometry.next_cell_index);
if any(geometry.cell_ids==cellId)
    error("adaptive_optopatch:DuplicateCellIds", ...
        "Cell ID %s is already present in this FOV.",cellId);
end
geometry.polygons{end+1,1}=vertices;
geometry.cell_ids(end+1,1)=cellId;
geometry.next_cell_index=geometry.next_cell_index+1;
end
