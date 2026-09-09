function fovState=load_fov_state(path)
%LOAD_FOV_STATE Load a persistent FOV definition.
arguments
    path (1,1) string
end
saved=load(path,"fov_state");
if ~isfield(saved,"fov_state") || ~isscalar(saved.fov_state)
    error("adaptive_optopatch:InvalidFovState","File does not contain scalar fov_state.");
end
fovState=saved.fov_state;
if ~isfield(fovState,"schema_version") || string(fovState.schema_version)~="2.0.0"
    error("adaptive_optopatch:ObsoleteFovSchema", ...
        "This artifact uses an obsolete Adaptive Optopatch FOV schema. Regenerate it with the current package.");
end
required=["fov_id","reference","canonical_roi_masks","canonical_roi_polygons", ...
    "stimulation_mode","microns_per_pixel","spiral_radius_um", ...
    "spiral_density_points_per_volt","orange_expansion_pixels", ...
    "blue_mask_adjustment_pixels","next_cell_index","cells"];
if ~all(isfield(fovState,cellstr(required)))
    error("adaptive_optopatch:InvalidFovState", ...
        "Schema-2 FOV state is incomplete. Regenerate it with the current package.");
end
cellRequired=["recording_enabled","stimulation_enabled", ...
    "selected_blue_voltage_v","blue_calibration","blue_calibration_history"];
if ~all(isfield(fovState.cells,cellstr(cellRequired))) || ...
        isfield(fovState.cells,"calibration_status")
    error("adaptive_optopatch:InvalidFovState", ...
        "FOV cells do not match the current status-free calibration schema.");
end
if ~isequal(size(fovState.canonical_roi_masks),size(fovState.reference.roi_masks)) || ...
        ~isequal(logical(fovState.canonical_roi_masks),logical(fovState.reference.roi_masks))
    error("adaptive_optopatch:CanonicalRoiMismatch", ...
        "Saved canonical ROI masks do not match the reference model.");
end
end
