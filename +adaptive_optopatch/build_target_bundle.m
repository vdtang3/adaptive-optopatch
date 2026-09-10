function targets = build_target_bundle(reference, options)
%BUILD_TARGET_BUNDLE Derive 1P soma masks and 2P spiral specifications.
arguments
    reference (1,1) struct
    options.SpiralRadiusUm (1,1) double {mustBePositive} = 6
    options.SpiralDensityPointsPerVolt (1,1) double {mustBePositive} = 10
    options.OrangeExpansionPixels (1,1) double {mustBeNonnegative,mustBeInteger} = 2
    options.BlueMaskAdjustmentPixels (1,1) double {mustBeInteger} = -1
    options.EdgeMarginPixels (1,1) double {mustBeNonnegative} = 2
    options.ParkingClearancePixels (1,1) double {mustBeNonnegative} = 3
    options.ParkingMaximumDistanceSpiralDiameters (1,1) double {mustBePositive} = 2
    options.ParkingIntensityAveragingRadiusPixels (1,1) double {mustBeNonnegative,mustBeInteger} = 2
    options.PulseDurationMs (1,1) double {mustBePositive} = 5
    options.ScannerSampleRateHz (1,1) double {mustBePositive} = 200000
end

nCells = numel(reference.cells);
blueMasks = false([reference.image_size, nCells]);
orangeMasks = false([reference.image_size, nCells]);
targetRows = struct([]);
spiralRadiusPixels=options.SpiralRadiusUm/reference.microns_per_pixel;
if isfield(reference.cells,"image_centroid_xy")
    centers=reshape([reference.cells.image_centroid_xy],2,[])';
else
    centers=reshape([reference.cells.camera_centroid_xy],2,[])';
end
parking=adaptive_optopatch.select_local_parking_points( ...
    reference.reference_image,reference.roi_masks,centers,spiralRadiusPixels, ...
    "ClearancePixels",options.ParkingClearancePixels, ...
    "MaximumDistanceSpiralDiameters",options.ParkingMaximumDistanceSpiralDiameters, ...
    "EdgeMarginPixels",options.EdgeMarginPixels, ...
    "IntensityAveragingRadiusPixels",options.ParkingIntensityAveragingRadiusPixels);
scannerTransform=[];
if isfield(reference,"scanner") && isfield(reference.scanner,"tform")
    scannerTransform=reference.scanner.tform;
end
cameraCenters=image_to_camera_coordinates(reference,centers);
cameraParking=image_to_camera_coordinates(reference, ...
    reshape([parking.parking_point_xy],2,[])');
cameraPixelScale=camera_pixel_scale(reference);
scannerRadiusPixels=spiralRadiusPixels*max(cameraPixelScale);

for i = 1:nCells
    canonicalMask=reference.roi_masks(:,:,i);
    orangeMask=canonicalMask;
    if options.OrangeExpansionPixels>0
        orangeMask=imdilate(orangeMask,strel("disk",options.OrangeExpansionPixels,0));
    end
    % The bundle-level Blue mask is a convenience default for static
    % display only; it does not gate schema-3 event executability (that is
    % evaluated per resolved event against the canonical ROI). An erosion
    % that empties the ROI at this default adjustment is therefore not a
    % bundle construction failure.
    try
        mask=adaptive_optopatch.apply_blue_mask_adjustment(canonicalMask, ...
            options.BlueMaskAdjustmentPixels,"Context", ...
            sprintf("cell %s",reference.cells(i).cell_id));
    catch exception
        if exception.identifier=="adaptive_optopatch:EmptyBlueMaskAdjustment"
            mask=false(reference.image_size);
        else
            rethrow(exception);
        end
    end
    edgeFlag = reference.cells(i).edge_distance_pixels < options.EdgeMarginPixels;
    blueMasks(:,:,i) = mask;
    orangeMasks(:,:,i)=orangeMask;
    targetRecord = struct( ...
        "cell_id", reference.cells(i).cell_id, ...
        "recording_enabled",cell_flag(reference.cells(i),"recording_enabled",true), ...
        "stimulation_enabled",cell_flag(reference.cells(i),"stimulation_enabled",true), ...
        "selected_blue_voltage_v",cell_number(reference.cells(i),"selected_blue_voltage_v",NaN), ...
        "blue_calibration",cell_struct(reference.cells(i),"blue_calibration"), ...
        "camera_centroid_xy",cameraCenters(i,:), ...
        "image_centroid_xy",centers(i,:), ...
        "dmd_mask_index", i, ...
        "spiral_center_xy",cameraCenters(i,:), ...
        "spiral_radius_pixels",scannerRadiusPixels, ...
        "spiral_preview_center_xy",centers(i,:), ...
        "spiral_preview_radius_pixels",spiralRadiusPixels, ...
        "spiral_radius_um", options.SpiralRadiusUm, ...
        "spiral_density_points_per_volt", options.SpiralDensityPointsPerVolt, ...
        "parking_point_xy",cameraParking(i,:), ...
        "parking_preview_point_xy",parking(i).parking_point_xy, ...
        "parking_distance_pixels", parking(i).parking_distance_pixels, ...
        "parking_clearance_pixels", parking(i).parking_clearance_pixels, ...
        "parking_mean_reference_intensity",parking(i).parking_mean_reference_intensity, ...
        "parking_search_maximum_distance_pixels", ...
            parking(i).parking_search_maximum_distance_pixels, ...
        "parking_selection_method", parking(i).parking_selection_method, ...
        "parking_qc_pass", parking(i).parking_qc_pass, ...
        "spiral_cycle_metrics", adaptive_optopatch.calculate_spiral_cycles( ...
            scannerTransform,cameraCenters(i,:), ...
            scannerRadiusPixels,options.SpiralDensityPointsPerVolt, ...
            options.PulseDurationMs,"ScannerSampleRateHz",options.ScannerSampleRateHz), ...
        "edge_flag", edgeFlag, ...
        "spiral_qc_pass",~edgeFlag && parking(i).parking_qc_pass, ...
        "qc_pass", ~edgeFlag && parking(i).parking_qc_pass);
    if i == 1
        targetRows = targetRecord;
    else
        targetRows(i,1) = targetRecord;
    end
end

targets = struct;
targets.schema_version = "2.0.0";
targets.fov_id = reference.fov_id;
targets.coordinate_space = "voltage_camera_full_sensor_pixels";
targets.preview_coordinate_space="snapshot_intrinsic_pixels";
targets.reference_camera = reference_camera_geometry(reference);
targets.blank_dmd_mask = false(reference.image_size);
targets.canonical_roi_masks=logical(reference.roi_masks);
targets.blue_camera_masks = blueMasks;
targets.dmd_camera_masks = blueMasks;
targets.orange_camera_masks=orangeMasks;
recordingEnabled=arrayfun(@(cell)cell_flag(cell,"recording_enabled",true),reference.cells);
targets.orange_combined_mask=any(orangeMasks(:,:,recordingEnabled),3);
targets.targets = targetRows;
targets.parameters = struct( ...
    "spiral_radius_um", options.SpiralRadiusUm, ...
    "spiral_density_points_per_volt", options.SpiralDensityPointsPerVolt, ...
    "pulse_duration_ms",options.PulseDurationMs, ...
    "scanner_sample_rate_hz",options.ScannerSampleRateHz, ...
    "parking_clearance_pixels",options.ParkingClearancePixels, ...
    "parking_maximum_distance_spiral_diameters", ...
        options.ParkingMaximumDistanceSpiralDiameters, ...
    "parking_intensity_averaging_radius_pixels", ...
        options.ParkingIntensityAveragingRadiusPixels, ...
    "orange_expansion_pixels",options.OrangeExpansionPixels, ...
    "blue_mask_adjustment_pixels",options.BlueMaskAdjustmentPixels, ...
    "edge_margin_pixels", options.EdgeMarginPixels);
end

function geometry=reference_camera_geometry(reference)
%REFERENCE_CAMERA_GEOMETRY Freeze the grid every camera coordinate lives on.
%   Every mask and camera-pixel target below is expressed on the reference
%   snapshot's pixel grid, so the runners must be able to confirm that the
%   live camera still acquires on that grid.
camera=reference.voltage_camera;
imageSize=double(reference.image_size(1:2));
origin=[0 0];
if isfield(camera,"x_world_limits") && numel(camera.x_world_limits)==2
    origin(1)=double(camera.x_world_limits(1));
end
if isfield(camera,"y_world_limits") && numel(camera.y_world_limits)==2
    origin(2)=double(camera.y_world_limits(1));
end
bin=1;
if isfield(camera,"bin") && isscalar(camera.bin) && isfinite(double(camera.bin)) && ...
        double(camera.bin)>0
    bin=double(camera.bin);
end
geometry=struct("schema_version","1.0.0", ...
    "name",string(field_or(camera,"name","")), ...
    "image_size",imageSize,"origin_xy",origin,"bin",bin, ...
    "roi",[origin(1) imageSize(2)*bin origin(2) imageSize(1)*bin], ...
    "x_world_limits",double(field_or(camera,"x_world_limits",[0 imageSize(2)])), ...
    "y_world_limits",double(field_or(camera,"y_world_limits",[0 imageSize(1)])));
end

function value=field_or(record,name,default)
if isfield(record,name) && ~isempty(record.(name)), value=record.(name);
else, value=default; end
end

function value=cell_flag(cellRecord,name,default)
if isfield(cellRecord,name), value=logical(cellRecord.(name)); else, value=default; end
end

function value=cell_number(cellRecord,name,default)
if isfield(cellRecord,name), value=double(cellRecord.(name)); else, value=default; end
end

function value=cell_string(cellRecord,name,default)
if isfield(cellRecord,name), value=string(cellRecord.(name)); else, value=string(default); end
end

function value=cell_struct(cellRecord,name)
if isfield(cellRecord,name), value=cellRecord.(name); else, value=struct([]); end
end

function cameraXY=image_to_camera_coordinates(reference,imageXY)
cameraXY=double(imageXY);
scale=camera_pixel_scale(reference);
camera=reference.voltage_camera;
if isfield(camera,"x_world_limits") && numel(camera.x_world_limits)==2
    cameraXY(:,1)=double(camera.x_world_limits(1))+ ...
        (cameraXY(:,1)-0.5)*scale(1);
end
if isfield(camera,"y_world_limits") && numel(camera.y_world_limits)==2
    cameraXY(:,2)=double(camera.y_world_limits(1))+ ...
        (cameraXY(:,2)-0.5)*scale(2);
end
end

function scale=camera_pixel_scale(reference)
scale=[1 1]; camera=reference.voltage_camera;
if isfield(camera,"x_world_limits") && numel(camera.x_world_limits)==2
    scale(1)=diff(double(camera.x_world_limits))/reference.image_size(2);
end
if isfield(camera,"y_world_limits") && numel(camera.y_world_limits)==2
    scale(2)=diff(double(camera.y_world_limits))/reference.image_size(1);
end
end
