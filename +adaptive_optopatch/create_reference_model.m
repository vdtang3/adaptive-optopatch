function reference = create_reference_model(referenceImage, roiMasks, metadata, options)
%CREATE_REFERENCE_MODEL Create stable cell identities in voltage-camera space.
arguments
    referenceImage (:,:) {mustBeNumeric}
    roiMasks (:,:,:) {mustBeNumericOrLogical}
    metadata (1,1) struct
    options.MicronsPerPixel (1,1) double {mustBePositive} = 0.35
    options.FovId (1,1) string = "fov"
    options.CellIds string = strings(0,1)
    options.SourceExperiment (1,1) string = ""
end

roiMasks = logical(roiMasks);
if any(size(referenceImage,1:2) ~= size(roiMasks,1:2))
    error("adaptive_optopatch:SizeMismatch", ...
        "Reference image and ROI masks must have identical height and width.");
end
nCells = size(roiMasks,3);
if nCells == 0
    error("adaptive_optopatch:NoCells", "At least one ROI is required.");
end
if isempty(options.CellIds)
    cellIds = compose("cell_%03d", (1:nCells)');
else
    cellIds = options.CellIds(:);
    if numel(cellIds) ~= nCells || numel(unique(cellIds)) ~= nCells
        error("adaptive_optopatch:InvalidCellIds", ...
            "CellIds must be unique and match the number of ROI masks.");
    end
end

cells = struct([]);
for i = 1:nCells
    mask = roiMasks(:,:,i);
    if ~any(mask, "all")
        error("adaptive_optopatch:EmptyRoi", "ROI %d is empty.", i);
    end
    stats = regionprops(mask, referenceImage, ...
        "Centroid", "Area", "MeanIntensity", "BoundingBox");
    if numel(stats) ~= 1
        error("adaptive_optopatch:DisconnectedRoi", ...
            "ROI %d must contain one connected component.", i);
    end
    [y,x] = find(mask);
    edgeDistance = min([min(x)-1, size(mask,2)-max(x), ...
        min(y)-1, size(mask,1)-max(y)]);
    equivRadiusPx = sqrt(stats.Area/pi);
    cellRecord = struct( ...
        "cell_id", cellIds(i), ...
        "camera_centroid_xy", stats.Centroid, ...
        "area_pixels", stats.Area, ...
        "equivalent_radius_pixels", equivRadiusPx, ...
        "mean_reference_intensity", stats.MeanIntensity, ...
        "bounding_box", stats.BoundingBox, ...
        "edge_distance_pixels", edgeDistance, ...
        "accepted", true, ...
        "qc_notes", "");
    if i == 1
        cells = cellRecord;
    else
        cells(i,1) = cellRecord;
    end
end

reference = struct;
reference.schema_version = "0.1.0";
reference.created_at = string(datetime("now", "TimeZone", "local"));
reference.fov_id = options.FovId;
reference.source_experiment = options.SourceExperiment;
reference.reference_image = single(referenceImage);
reference.roi_masks = roiMasks;
reference.image_size = size(referenceImage);
reference.microns_per_pixel = options.MicronsPerPixel;
reference.voltage_camera = metadata.voltage_camera;
if isfield(metadata,"stimulation_dmd"), reference.stimulation_dmd=metadata.stimulation_dmd; end
if isfield(metadata,"snapshot_path"), reference.source_snapshot=metadata.snapshot_path; end
if isfield(metadata,"scanner"), reference.scanner=metadata.scanner; end
reference.rig_name = metadata.rig_name;
reference.cells = cells;
end
