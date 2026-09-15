function geometry=delete_soma_polygon(geometry,cellId)
%DELETE_SOMA_POLYGON Remove one soma without renumbering the others.
%   next_cell_index is deliberately left alone: a deleted ID is retired
%   rather than recycled, so surviving cells keep their identities and a
%   later soma cannot inherit a deleted cell's calibration history.
arguments
    geometry (1,1) struct
    cellId (1,1) string
end
index=adaptive_optopatch.soma_cell_index(geometry,cellId);
geometry.polygons(index)=[];
geometry.cell_ids(index)=[];
end
