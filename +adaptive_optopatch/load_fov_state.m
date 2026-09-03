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
if ~isfield(fovState,"next_cell_index")
    fovState.next_cell_index=infer_next_cell_index(fovState.cells);
end
fovState=ensure_calibration_fields(fovState);
if ~isequal(size(fovState.canonical_roi_masks),size(fovState.reference.roi_masks)) || ...
        ~isequal(logical(fovState.canonical_roi_masks),logical(fovState.reference.roi_masks))
    error("adaptive_optopatch:CanonicalRoiMismatch", ...
        "Saved canonical ROI masks do not match the reference model.");
end
end

function fovState=ensure_calibration_fields(fovState)
defaults=struct("blue_calibration",struct([]),"blue_calibration_history",struct([]));
for name=string(fieldnames(defaults))'
    if ~isfield(fovState.cells,name)
        [fovState.cells.(name)]=deal(defaults.(name));
    end
end
fovState.reference.cells=fovState.cells;
end

function value=infer_next_cell_index(cells)
numbers=zeros(numel(cells),1);
for k=1:numel(cells)
    token=regexp(char(string(cells(k).cell_id)),'^cell_(\d+)$','tokens','once');
    if ~isempty(token), numbers(k)=str2double(token{1}); end
end
value=max([numbers;0])+1;
end
