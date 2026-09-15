function geometry=update_soma_polygon(geometry,cellId,verticesXy)
%UPDATE_SOMA_POLYGON Replace one canonical soma polygon, keeping its cell ID.
arguments
    geometry (1,1) struct
    cellId (1,1) string
    verticesXy (:,2) double
end
index=adaptive_optopatch.soma_cell_index(geometry,cellId);
geometry.polygons{index}=adaptive_optopatch.validate_soma_polygon(verticesXy);
end
