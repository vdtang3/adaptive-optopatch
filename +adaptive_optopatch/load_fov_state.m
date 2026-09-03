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
if ~isequal(size(fovState.canonical_roi_masks),size(fovState.reference.roi_masks)) || ...
        ~isequal(logical(fovState.canonical_roi_masks),logical(fovState.reference.roi_masks))
    error("adaptive_optopatch:CanonicalRoiMismatch", ...
        "Saved canonical ROI masks do not match the reference model.");
end
end
