function valid=is_blue_target_executable(targets,index)
%IS_BLUE_TARGET_EXECUTABLE Check hard 1P mask geometry requirements.
arguments
    targets (1,1) struct
    index (1,1) double {mustBePositive,mustBeInteger}
end
valid=isfield(targets,"dmd_camera_masks") && ...
    size(targets.dmd_camera_masks,3)>=index && ...
    any(targets.dmd_camera_masks(:,:,index),"all");
if valid && isfield(targets.targets,"dmd_mask_index")
    patternIndex=double(targets.targets(index).dmd_mask_index);
    valid=isscalar(patternIndex) && isfinite(patternIndex) && ...
        fix(patternIndex)==patternIndex && patternIndex==index;
end
end
