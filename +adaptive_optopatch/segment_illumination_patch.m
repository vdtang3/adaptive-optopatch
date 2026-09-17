function segmentation=segment_illumination_patch(image,options)
%SEGMENT_ILLUMINATION_PATCH Half-contrast footprint of one DMD illumination patch.
%   Intended for a snap of an isolated patch projected onto a reasonably
%   uniform fluorescent target. Deliberately simple and transparent: the
%   50%-contrast contour is an operational definition of a blurred DMD edge, so
%   the number it produces is reproducible between operators and rigs rather
%   than optimal.
%
%   The background level is the median of the bottom quintile and the plateau
%   level the median of the top percentile, which is robust to dark speckle and
%   the occasional hot pixel without fitting anything.
%
%   WHY THE PLATEAU PERCENTILE IS HIGH. signal is the MEDIAN of the pixels
%   above PlateauPercentile, so more than half of that set has to be patch
%   pixels. The top (100-P)% of the frame clears that bar once the patch covers
%   more than about half of (100-P)%:
%
%       P = 80     needs coverage above ~10%
%       P = 99     needs coverage above ~0.5%
%       P = 99.5   needs coverage above ~0.25%
%
%   Measured on a 512 x 512 synthetic frame, P = 99 recovers the footprint
%   exactly from 0.6% coverage upward and P = 99.5 from 0.3% upward.
%
%   A nominal 100 um patch at 0.4 um/pixel is 250 x 250 px - 6% of a 1024 x
%   1024 sensor. At P = 80 the top quintile of that frame is still background,
%   so signal came back AS background and the contrast check below fired on a
%   perfectly good snap. Hence the default of 99, which handles any compact
%   patch and still works for one filling half the field.
%
%   Going higher costs a little accuracy rather than nothing: the fewer pixels
%   the median is taken over, the further up the noise distribution it sits, so
%   P = 99.9 overestimates a noisy plateau by several percent and biases the
%   threshold with it. 99.5 is the setting to reach for below the floor.
%
%   BELOW THE FLOOR THE FAILURE IS QUIET, which is the one thing worth knowing
%   here. The plateau estimate becomes a blend of patch and background, which
%   puts the threshold just above background and leaves the mask too large -
%   by 2% at 0.5% coverage, ~11% at 0.2%, and ~21% at 0.1% - rather than
%   tripping the contrast error below. Nothing detects that, because detecting it means
%   guessing the coverage, and the percentile is deliberately never adjusted
%   from the image: a calibration number that came out of a hidden heuristic
%   cannot be accounted for afterwards. For a patch that small, raise
%   PlateauPercentile or crop the snap.
%
%   Cleanup is conservative on purpose. Keeping the largest component and
%   filling holes removes stray bright dust and interior dropouts; erosion or
%   dilation would move the very edge whose position is being measured.
arguments
    image {mustBeNumeric,mustBeNonempty}
    % 0 < fraction < 1. See the note in measure_illumination_irradiance on
    % why this is not mustBeInRange or mustBeBetween.
    options.ThresholdFraction (1,1) double ...
        {mustBeGreaterThan(options.ThresholdFraction,0), ...
         mustBeLessThan(options.ThresholdFraction,1)} = 0.5
    % Percentiles defining "definitely background" and "definitely
    % illuminated". See the note above before changing the plateau default.
    options.BackgroundPercentile (1,1) double ...
        {mustBeGreaterThan(options.BackgroundPercentile,0), ...
         mustBeLessThan(options.BackgroundPercentile,100)} = 20
    options.PlateauPercentile (1,1) double ...
        {mustBeGreaterThan(options.PlateauPercentile,0), ...
         mustBeLessThan(options.PlateauPercentile,100)} = 99
end

if options.BackgroundPercentile>=options.PlateauPercentile
    error("adaptive_optopatch:PercentileOrder", ...
        "BackgroundPercentile (%g) must be below PlateauPercentile (%g).", ...
        options.BackgroundPercentile,options.PlateauPercentile);
end

% A calibration snap is one frame; take the first plane the way Luminos's own
% snap_plane does rather than refusing a trailing singleton dimension.
im=double(image(:,:,1));

lowCut=prctile(im(:),options.BackgroundPercentile);
highCut=prctile(im(:),options.PlateauPercentile);
background=median(im(im<=lowCut));
signal=median(im(im>=highCut));

if ~isfinite(background) || ~isfinite(signal) || signal<=background
    error("adaptive_optopatch:NoIlluminationContrast", ...
        "The snap shows no illuminated/background contrast (background %.4g, " + ...
        "plateau %.4g at the %g'th percentile). Either the patch was not " + ...
        "projected onto a fluorescent target, or it covers less than about " + ...
        "%.2g%% of the frame, which is too little for that percentile to " + ...
        "sit inside it - try PlateauPercentile=99.5, or crop the snap.", ...
        background,signal,options.PlateauPercentile, ...
        (100-options.PlateauPercentile)/2);
end

threshold=background+options.ThresholdFraction*(signal-background);
mask=im>threshold;

if ~any(mask,"all")
    error("adaptive_optopatch:EmptyIlluminationFootprint", ...
        "Nothing exceeded the %.0f%% contrast threshold of %.4g.", ...
        100*options.ThresholdFraction,threshold);
end

mask=bwareafilt(mask,1);
mask=imfill(mask,"holes");

segmentation=struct( ...
    "mask",mask, ...
    "threshold_fraction",options.ThresholdFraction, ...
    "threshold_value",threshold, ...
    "background_level",background, ...
    "plateau_level",signal, ...
    "background_percentile",options.BackgroundPercentile, ...
    "plateau_percentile",options.PlateauPercentile);
end
