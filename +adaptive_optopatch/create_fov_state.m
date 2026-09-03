function fovState=create_fov_state(reference,roiPolygons,options)
%CREATE_FOV_STATE Create the persistent source of truth for one FOV.
arguments
    reference (1,1) struct
    roiPolygons cell = {}
    options.OrangeExpansionPixels (1,1) double {mustBeNonnegative,mustBeInteger} = 2
    options.BlueMaskAdjustmentPixels (1,1) double {mustBeInteger} = -1
end
if isempty(roiPolygons) && isfield(reference.cells,"canonical_roi_polygon")
    roiPolygons={reference.cells.canonical_roi_polygon}';
end
if ~isempty(roiPolygons) && numel(roiPolygons)~=numel(reference.cells)
    error("adaptive_optopatch:FovRoiCountMismatch", ...
        "Canonical ROI polygons must match the number of cells.");
end
reference=ensure_cell_state(reference,roiPolygons);
fovState=struct("schema_version","1.0.0", ...
    "fov_id",string(reference.fov_id), ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "updated_at",string(datetime("now","TimeZone","local")), ...
    "reference",reference, ...
    "canonical_roi_masks",logical(reference.roi_masks), ...
    "canonical_roi_polygons",{roiPolygons(:)}, ...
    "orange_expansion_pixels",options.OrangeExpansionPixels, ...
    "blue_mask_adjustment_pixels",options.BlueMaskAdjustmentPixels, ...
    "cells",reference.cells);
end

function reference=ensure_cell_state(reference,roiPolygons)
for k=1:numel(reference.cells)
    defaults=struct("recording_enabled",true,"stimulation_enabled",true, ...
        "selected_blue_voltage_v",NaN,"calibration_status","uncalibrated", ...
        "calibration_notes","","calibration_acquisition","");
    names=fieldnames(defaults);
    for j=1:numel(names)
        if ~isfield(reference.cells,names{j})
            [reference.cells.(names{j})]=deal(defaults.(names{j}));
        end
    end
    if ~isempty(roiPolygons)
        reference.cells(k).canonical_roi_polygon=double(roiPolygons{k});
    elseif ~isfield(reference.cells,"canonical_roi_polygon")
        reference.cells(k).canonical_roi_polygon=zeros(0,2);
    end
end
end
