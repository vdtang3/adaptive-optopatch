function vertices=validate_soma_polygon(verticesXy)
%VALIDATE_SOMA_POLYGON Accept one finite canonical soma polygon.
%   Zero-area and out-of-bounds polygons are deliberately not rejected
%   here. They stay reachable by dragging an existing polygon, and QC
%   reports them as CHECK exactly as it did when the graphics object was
%   the only ROI store; rejecting them would abort an interactive drag.
arguments
    verticesXy (:,2) double
end
if size(verticesXy,1)<3 || ~all(isfinite(verticesXy),"all")
    error("adaptive_optopatch:InvalidCanonicalRoi", ...
        "A soma polygon needs at least three finite vertices.");
end
vertices=double(verticesXy);
end
