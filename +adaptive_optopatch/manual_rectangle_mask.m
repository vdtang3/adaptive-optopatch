function footprint=manual_rectangle_mask(image,options)
%MANUAL_RECTANGLE_MASK Draw the illuminated footprint by hand, as a rectangle.
%   The operator drags a rectangle over the patch and accepts it. That
%   rectangle IS the segmentation - nothing is refined against intensity
%   afterwards.
%
%   Why a drawn shape beats thresholding for power calibration. A projected DMD
%   patch is approximately rectangular, but a real snap of one has a halo, an
%   uneven fluorescent target and an edge several pixels wide. A contrast
%   contour tracks all three, so the area it returns moves with the target and
%   the exposure. A drawn shape is the operator's statement of the footprint
%   they intended to project, which is reproducible in a way a halo is not, and
%   takes a couple of seconds.
%
%   A rectangle is the fastest option and right for the usual patch. For a
%   footprint that is genuinely not a rectangle, use manual_polygon_mask; for no
%   operator at all, use segment_illumination_patch.
%
%   Position accepts a rectangle directly and skips the interaction, as
%   [x y width height] in image pixel coordinates. That is how a calibration
%   can be re-run later on the same footprint, and how this is tested.
arguments
    image {mustBeNumeric,mustBeNonempty}
    options.Position double = []
    options.Visible (1,1) string ...
        {mustBeMember(options.Visible,["on","off"])} = "on"
end

position=[];
if ~isempty(options.Position)
    position=validate_rectangle(options.Position,size(image(:,:,1)));
end

footprint=draw_manual_footprint(image, ...
    Mode="manual-rectangle", ...
    Instruction="Draw a rectangle around the intended illuminated footprint.", ...
    DrawNew=@(ax) drawrectangle(ax, ...
        "Color",[1 0 0],"LineWidth",1.5,"FaceAlpha",0.08), ...
    DrawAt=@(ax,pos) drawrectangle(ax,"Position",pos), ...
    GeometryField="rectangle_position", ...
    Position=position, ...
    Visible=options.Visible);
end


% A rectangle supplied programmatically still has to describe real pixels.
function position=validate_rectangle(position,imageSize)
position=double(position(:))';
if numel(position)~=4 || ~all(isfinite(position))
    error("adaptive_optopatch:BadRectanglePosition", ...
        "Position must be a finite [x y width height].");
end
if any(position(3:4)<=0)
    error("adaptive_optopatch:BadRectanglePosition", ...
        "Rectangle width and height must be positive; got %g x %g.", ...
        position(3),position(4));
end
if position(1)+position(3)<0.5 || position(2)+position(4)<0.5 || ...
        position(1)>imageSize(2)+0.5 || position(2)>imageSize(1)+0.5
    error("adaptive_optopatch:RectangleOutsideImage", ...
        "The rectangle [%g %g %g %g] lies outside a %dx%d image.", ...
        position(1),position(2),position(3),position(4), ...
        imageSize(1),imageSize(2));
end
end
