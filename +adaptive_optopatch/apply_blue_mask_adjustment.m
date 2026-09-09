function mask=apply_blue_mask_adjustment(mask,adjustmentPixels,options)
%APPLY_BLUE_MASK_ADJUSTMENT Apply a signed integer pixel adjustment to a canonical ROI mask.
%   mask = APPLY_BLUE_MASK_ADJUSTMENT(mask,adjustmentPixels) erodes (negative),
%   leaves unchanged (zero), or dilates (positive) a canonical logical ROI
%   mask by abs(adjustmentPixels) pixels using a flat disk structuring
%   element. This is the single, authoritative Blue-DMD mask-adjustment
%   primitive: the requested adjustment is exact and non-negotiable. If the
%   requested erosion leaves no pixels, the requested physical mask does not
%   exist and this errors rather than silently substituting another mask.
arguments
    mask (:,:) logical
    adjustmentPixels (1,1) double {mustBeInteger}
    options.Context (1,1) string = ""
end
if adjustmentPixels<0
    candidate=imerode(mask,strel("disk",abs(adjustmentPixels),0));
    if ~any(candidate,"all")
        contextSuffix="";
        if options.Context~=""
            contextSuffix=sprintf(" (%s)",options.Context);
        end
        error("adaptive_optopatch:EmptyBlueMaskAdjustment", ...
            "Requested Blue-mask erosion of %d pixel(s) produces an empty mask%s.", ...
            abs(adjustmentPixels),contextSuffix);
    end
    mask=candidate;
elseif adjustmentPixels>0
    mask=imdilate(mask,strel("disk",adjustmentPixels,0));
end
end
