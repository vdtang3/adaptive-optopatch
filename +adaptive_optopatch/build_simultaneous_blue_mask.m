function combined=build_simultaneous_blue_mask(protocol,targets)
%BUILD_SIMULTANEOUS_BLUE_MASK Adjust each frozen canonical ROI, then union.
if ~adaptive_optopatch.is_simultaneous_protocol(protocol)
    error("adaptive_optopatch:SimultaneousProtocolRequired","Expected simultaneous target policy.");
end
ids=string(protocol.simultaneous_target_cell_ids(:));
indices=double(protocol.simultaneous_target_indices(:));
if isempty(ids) || numel(ids)~=numel(indices) || numel(unique(ids))~=numel(ids) || ...
        numel(unique(indices))~=numel(indices) || any(~isfinite(indices) | indices<1 | fix(indices)~=indices) || ...
        ~isfield(targets,"canonical_roi_masks") || any(indices>size(targets.canonical_roi_masks,3)) || ...
        any(indices>numel(targets.targets))
    error("adaptive_optopatch:InvalidSimultaneousTargets","Frozen simultaneous target group or canonical geometry is invalid.");
end
if ~isfield(protocol,"simultaneous_target_stimulation_enabled") || ...
        numel(protocol.simultaneous_target_stimulation_enabled)~=numel(ids) || ...
        ~all(protocol.simultaneous_target_stimulation_enabled)
    error("adaptive_optopatch:InvalidSimultaneousTargets","Every frozen target must have been Stim-enabled at resolution.");
end
combined=false(size(targets.canonical_roi_masks,1),size(targets.canonical_roi_masks,2));
for k=1:numel(ids)
    if string(targets.targets(indices(k)).cell_id)~=ids(k)
        error("adaptive_optopatch:InvalidSimultaneousTargets","Frozen ID/index mismatch for %s.",ids(k));
    end
    adjusted=adaptive_optopatch.apply_blue_mask_adjustment( ...
        targets.canonical_roi_masks(:,:,indices(k)), ...
        protocol.parameters.blue_mask_adjustment_pixels,"Context","simultaneous cell "+ids(k));
    if ~any(adjusted,"all")
        error("adaptive_optopatch:EmptyBlueMask","Simultaneous cell %s has an empty Blue mask.",ids(k));
    end
    combined=combined | adjusted;
end
end
