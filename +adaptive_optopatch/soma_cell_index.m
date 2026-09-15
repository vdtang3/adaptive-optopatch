function index=soma_cell_index(geometry,cellId)
%SOMA_CELL_INDEX Row of one stable cell ID within canonical FOV geometry.
arguments
    geometry (1,1) struct
    cellId (1,1) string
end
index=find(geometry.cell_ids==cellId,1);
if isempty(index)
    error("adaptive_optopatch:UnknownCellId","Unknown cell ID: %s",cellId);
end
end
