function [display,limits]=reference_display_image(image)
%REFERENCE_DISPLAY_IMAGE Eight-bit grayscale view of a reference FOV.
%   The contrast stretch belongs in MATLAB, not in a browser: the planning
%   axes already apply reference_contrast_limits, and a second frontend that
%   invented its own mapping would show the operator a different picture of
%   the same FOV. This applies that one rule and returns the result a view
%   can paint directly.
%
%   The output is a DISPLAY artifact. It is never the canonical reference
%   image, is never written to a plan, and nothing measures anything from
%   it. Canonical intensities stay in controller.ReferenceImage.
%
%   Geometry is preserved exactly: the result is the same size as the input,
%   so a pixel of the display image is the same pixel of the reference image
%   and snapshot-intrinsic coordinates need no adjustment.
arguments
    image {mustBeNumeric}
end
if isempty(image)
    display=uint8([]); limits=zeros(1,0); return
end
values=double(image);
limits=adaptive_optopatch.reference_contrast_limits(values);
if isempty(limits)
    % Nothing to stretch between - a flat or all-NaN image. Mid grey says
    % "there is an image here and it has no contrast", which is true, and is
    % more use than a black rectangle that reads as a failed transfer.
    display=repmat(uint8(128),size(values));
    return
end
scaled=(values-limits(1))/(limits(2)-limits(1));
scaled(~isfinite(scaled))=0;
display=uint8(255*min(max(scaled,0),1));
end
