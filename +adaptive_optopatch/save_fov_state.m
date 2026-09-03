function save_fov_state(path,fovState)
%SAVE_FOV_STATE Persist canonical cells and calibration without renumbering.
arguments
    path (1,1) string
    fovState (1,1) struct
end
required=["fov_id","reference","canonical_roi_masks","cells", ...
    "orange_expansion_pixels","blue_mask_adjustment_pixels"];
if ~all(isfield(fovState,required))
    error("adaptive_optopatch:InvalidFovState","FOV state is missing required fields.");
end
if numel(unique(string({fovState.cells.cell_id})))~=numel(fovState.cells)
    error("adaptive_optopatch:DuplicateCellIds","FOV cell IDs must be unique.");
end
fov_state=fovState; %#ok<NASGU>
fov_state.updated_at=string(datetime("now","TimeZone","local"));
folder=fileparts(path); if strlength(folder)>0 && ~isfolder(folder), mkdir(folder); end
save(path,"fov_state","-v7.3");
end
