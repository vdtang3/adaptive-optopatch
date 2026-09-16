function limits=reference_contrast_limits(image)
%REFERENCE_CONTRAST_LIMITS Display intensity limits for a reference image.
%   One percentile rule, in one place, so the MATLAB planning axes and any
%   other frontend show the same picture of the same FOV. The limits are a
%   DISPLAY decision only: nothing downstream of the reference model reads
%   them, and the canonical image is never rescaled.
%
%   Returns [low high] with high>low, or an empty 1-by-0 when the image
%   holds no finite values to stretch between.
arguments
    image {mustBeNumeric}
end
values=double(image(:));
values=values(isfinite(values));
limits=zeros(1,0);
if isempty(values), return; end
candidate=prctile(values,[1 99.8]);
if candidate(2)<=candidate(1)
    % A flat or nearly flat image: percentile 1 and 99.8 coincide, and an
    % empty result says "there is nothing to stretch" rather than producing
    % a degenerate range that a caller would have to detect anyway.
    return
end
limits=candidate;
end
