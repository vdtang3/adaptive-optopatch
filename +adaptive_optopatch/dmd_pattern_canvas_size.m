function canvasSize=dmd_pattern_canvas_size(dmd)
%DMD_PATTERN_CANVAS_SIZE Full DMD image size in MATLAB [rows columns] order.
%   Luminos stores Patterning_Device.Dimensions as [width height], while
%   Target is an ordinary MATLAB image. Pattern_Canvas_Size is the canonical
%   device API that translates between those conventions.
if ismethod(dmd,"Pattern_Canvas_Size")
    canvasSize=double(dmd.Pattern_Canvas_Size());
elseif isprop(dmd,"Dimensions") || (isstruct(dmd) && isfield(dmd,"Dimensions"))
    % Compatibility for small test doubles and older Luminos revisions.
    dimensions=double(dmd.Dimensions);
    canvasSize=dimensions([2 1]);
else
    error("adaptive_optopatch:DmdCanvasSizeUnavailable", ...
        "The DMD does not expose Pattern_Canvas_Size or Dimensions.");
end
canvasSize=reshape(canvasSize,1,[]);
if numel(canvasSize)~=2 || any(~isfinite(canvasSize)) || ...
        any(canvasSize<1) || any(fix(canvasSize)~=canvasSize)
    error("adaptive_optopatch:InvalidDmdCanvasSize", ...
        "The DMD pattern canvas size must contain two positive integers.");
end
end
