function footprint=get_footprint_mask(image,options)
%GET_FOOTPRINT_MASK The illuminated footprint, by whichever method was asked for.
%   One place decides how the footprint is obtained, so everything downstream -
%   the physical area, the power conversion, the AOTF grouping - is written
%   against a mask and does not care where it came from.
%
%   Modes:
%     "manual-polygon"    (default) the operator clicks vertices. States any
%                         footprint, including the ones a rectangle can only
%                         over-count.
%     "manual-rectangle"  the operator drags a rectangle. Quicker, and exact
%                         when the patch really is a box.
%     "auto-threshold"    the half-contrast contour. No operator needed, but it
%                         follows whatever the target and the exposure do to the
%                         edge.
%
%   Both manual modes are robust to halos, uneven fluorescence and a fuzzy edge
%   for the same reason: they never consult intensity.
%
%   Every mode returns the same shape:
%     footprint.mask     logical, in the snap's own image coordinates
%     footprint.mode     which mode produced it
%     footprint.details  mode-specific provenance, enough to say what was done
arguments
    image {mustBeNumeric,mustBeNonempty}
    options.SegmentationMode (1,1) string {mustBeMember( ...
        options.SegmentationMode, ...
        ["manual-rectangle","manual-polygon","auto-threshold"])} ...
        = "manual-polygon"

    % Auto-threshold only. See segment_illumination_patch.
    options.ThresholdFraction (1,1) double = 0.5
    options.BackgroundPercentile (1,1) double = 20
    options.PlateauPercentile (1,1) double = 99

    % Manual modes only: supply the geometry instead of drawing it.
    options.RectanglePosition double = []
    options.PolygonVertices double = []

    options.Visible (1,1) string ...
        {mustBeMember(options.Visible,["on","off"])} = "on"
end

switch options.SegmentationMode
    case "manual-rectangle"
        note_unused(options,"ThresholdFraction","BackgroundPercentile", ...
            "PlateauPercentile","PolygonVertices");
        footprint=adaptive_optopatch.manual_rectangle_mask(image, ...
            Position=options.RectanglePosition, ...
            Visible=options.Visible);

    case "manual-polygon"
        note_unused(options,"ThresholdFraction","BackgroundPercentile", ...
            "PlateauPercentile","RectanglePosition");
        footprint=adaptive_optopatch.manual_polygon_mask(image, ...
            Vertices=options.PolygonVertices, ...
            Visible=options.Visible);

    case "auto-threshold"
        note_unused(options,"RectanglePosition","PolygonVertices");
        segmentation=adaptive_optopatch.segment_illumination_patch(image, ...
            ThresholdFraction=options.ThresholdFraction, ...
            BackgroundPercentile=options.BackgroundPercentile, ...
            PlateauPercentile=options.PlateauPercentile);
        footprint=struct( ...
            "mask",segmentation.mask, ...
            "mode","auto-threshold", ...
            "details",rmfield(segmentation,"mask"));
end
end


% A warning rather than an error: a setting left over from a previous call in
% another mode is harmless, and failing on it would make switching modes
% tedious. A warning rather than a printed note because someone who passed a
% footprint or a threshold probably believes it is being used, and a warning is
% something they can catch, suppress or see in a log. Detected by comparing
% against the defaults, so passing a default explicitly stays quiet.
function note_unused(options,varargin)
defaults=struct( ...
    "ThresholdFraction",0.5, ...
    "BackgroundPercentile",20, ...
    "PlateauPercentile",99, ...
    "RectanglePosition",[], ...
    "PolygonVertices",[]);

candidates=string(varargin);
differs=false(size(candidates));
for k=1:numel(candidates)
    differs(k)=~isequal(options.(candidates(k)),defaults.(candidates(k)));
end
unused=candidates(differs);
if isempty(unused)
    return
end

if isscalar(unused)
    verb="is";
else
    verb="are";
end
warning("adaptive_optopatch:UnusedSegmentationOptions", ...
    "%s %s unused in %s mode.", ...
    strjoin(unused,", "),verb,options.SegmentationMode);
end
