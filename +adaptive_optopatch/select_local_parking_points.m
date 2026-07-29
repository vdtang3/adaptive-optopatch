function parking = select_local_parking_points(referenceImage, roiMasks, centersXY, spiralRadiusPixels, options)
%SELECT_LOCAL_PARKING_POINTS Choose the darkest nearby cell-free locations.
arguments
    referenceImage (:,:) {mustBeNumeric}
    roiMasks (:,:,:) {mustBeNumericOrLogical}
    centersXY (:,2) double
    spiralRadiusPixels (1,1) double {mustBePositive}
    options.ClearancePixels (1,1) double {mustBeNonnegative} = 3
    options.MaximumDistanceSpiralDiameters (1,1) double {mustBePositive} = 2
    options.EdgeMarginPixels (1,1) double {mustBeNonnegative} = 3
    options.IntensityAveragingRadiusPixels (1,1) double {mustBeNonnegative,mustBeInteger} = 2
end
nCells=size(roiMasks,3);
if size(centersXY,1)~=nCells
    error("adaptive_optopatch:ParkingCellCountMismatch", ...
        "One center is required for every ROI.");
end
[nRows,nColumns,~]=size(roiMasks);
if any(size(referenceImage)~=[nRows nColumns])
    error("adaptive_optopatch:ParkingImageSizeMismatch", ...
        "Reference image and ROI masks must have identical dimensions.");
end
allSomata=any(logical(roiMasks),3);
distanceFromSomata=bwdist(allSomata);
minimumClearance=spiralRadiusPixels+options.ClearancePixels;
if options.IntensityAveragingRadiusPixels>0
    kernel=strel("disk",options.IntensityAveragingRadiusPixels,0).Neighborhood;
    kernel=double(kernel)/nnz(kernel);
    intensityMap=imfilter(double(referenceImage),kernel,"replicate");
else
    intensityMap=double(referenceImage);
end
intensityMap(~isfinite(intensityMap))=Inf;
baseAllowed=distanceFromSomata>=minimumClearance;
edge=ceil(options.EdgeMarginPixels);
if edge>0
    baseAllowed(1:min(edge,nRows),:)=false;
    baseAllowed(max(1,nRows-edge+1):nRows,:)=false;
    baseAllowed(:,1:min(edge,nColumns))=false;
    baseAllowed(:,max(1,nColumns-edge+1):nColumns)=false;
end
maximumDistance=2*spiralRadiusPixels*options.MaximumDistanceSpiralDiameters;
parking=repmat(struct("parking_point_xy",[NaN NaN], ...
    "parking_distance_pixels",NaN,"parking_clearance_pixels",NaN, ...
    "parking_mean_reference_intensity",NaN, ...
    "parking_search_maximum_distance_pixels",maximumDistance, ...
    "parking_selection_method","darkest_valid_local_region", ...
    "parking_qc_pass",false),nCells,1);
for k=1:nCells
    [gridX,gridY]=meshgrid(1:nColumns,1:nRows);
    distances=hypot(gridX-centersXY(k,1),gridY-centersXY(k,2));
    allowed=baseAllowed & distances<=maximumDistance;
    [allowedY,allowedX]=find(allowed);
    if isempty(allowedX), continue; end
    candidateIntensity=intensityMap(allowed);
    minimumIntensity=min(candidateIntensity);
    tolerance=max(eps(minimumIntensity),eps);
    darkest=find(candidateIntensity<=minimumIntensity+tolerance);
    [~,nearest]=min(distances(sub2ind([nRows nColumns], ...
        allowedY(darkest),allowedX(darkest))));
    idx=darkest(nearest);
    point=[allowedX(idx) allowedY(idx)];
    parking(k).parking_point_xy=point;
    parking(k).parking_distance_pixels=distances(point(2),point(1));
    parking(k).parking_clearance_pixels=distanceFromSomata(point(2),point(1));
    parking(k).parking_mean_reference_intensity=intensityMap(point(2),point(1));
    parking(k).parking_qc_pass=parking(k).parking_clearance_pixels>=minimumClearance && ...
        parking(k).parking_distance_pixels<=maximumDistance;
end
end
