function count=draw_soma_rois_until_empty(drawPolygon,commitPolygon,continueDrawing)
%DRAW_SOMA_ROIS_UNTIL_EMPTY Commit polygons until drawing returns empty.
arguments
    drawPolygon (1,1) function_handle
    commitPolygon (1,1) function_handle
    continueDrawing (1,1) function_handle = @()true
end
count=0;
while continueDrawing()
    position=drawPolygon();
    if ~is_nonempty_polygon(position), return; end
    commitPolygon(double(position));
    count=count+1;
end
end

function value=is_nonempty_polygon(position)
value=isnumeric(position) && size(position,2)==2 && ...
    size(position,1)>=3 && all(isfinite(position),"all") && ...
    abs(polyarea(double(position(:,1)),double(position(:,2))))>0;
end
