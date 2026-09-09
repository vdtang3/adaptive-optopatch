function output=apply_acquisition_parameters(targets,protocol)
%APPLY_ACQUISITION_PARAMETERS Materialize frozen acquisition spatial values.
arguments
    targets (1,1) struct
    protocol (1,1) struct
end
protocol=adaptive_optopatch.normalize_protocol(protocol);
if protocol.artifact_type~="resolved_acquisition"
    error("adaptive_optopatch:ResolvedProtocolRequired", ...
        "Acquisition parameters can be applied only from a resolved schedule.");
end
output=targets; parameters=protocol.parameters;
if isfield(parameters,"orange_expansion_pixels")
    if ~isfield(targets,"canonical_roi_masks")
        error("adaptive_optopatch:CanonicalRoiMasksRequired", ...
            "Frozen Orange expansion requires canonical ROI masks.");
    end
    expansion=double(parameters.orange_expansion_pixels);
    masks=logical(targets.canonical_roi_masks);
    for k=1:size(masks,3)
        if expansion>0
            masks(:,:,k)=imdilate(masks(:,:,k),strel("disk",expansion,0));
        end
    end
    recordingEnabled=true(1,size(masks,3));
    if isfield(targets.targets,"recording_enabled")
        recordingEnabled=logical([targets.targets.recording_enabled]);
    end
    output.orange_camera_masks=masks;
    output.orange_combined_mask=any(masks(:,:,recordingEnabled),3);
    output.parameters.orange_expansion_pixels=expansion;
end
for k=1:numel(output.targets)
    if isfield(parameters,"spiral_radius_um") && ...
            isfield(output.targets,"spiral_radius_um") && ...
            isfield(output.targets,"spiral_radius_pixels") && ...
            isfield(output.targets,"spiral_preview_radius_pixels")
        pixelsPerUm=double(output.targets(k).spiral_radius_pixels)/ ...
            double(output.targets(k).spiral_radius_um);
        previewPixelsPerUm=double(output.targets(k).spiral_preview_radius_pixels)/ ...
            double(output.targets(k).spiral_radius_um);
        output.targets(k).spiral_radius_um=double(parameters.spiral_radius_um);
        output.targets(k).spiral_radius_pixels= ...
            output.targets(k).spiral_radius_um*pixelsPerUm;
        output.targets(k).spiral_preview_radius_pixels= ...
            output.targets(k).spiral_radius_um*previewPixelsPerUm;
    end
    if isfield(parameters,"spiral_density_points_per_volt")
        output.targets(k).spiral_density_points_per_volt= ...
            double(parameters.spiral_density_points_per_volt);
    end
end
end
