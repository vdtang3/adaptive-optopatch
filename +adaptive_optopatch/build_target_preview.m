function preview=build_target_preview(targets,mode,options)
%BUILD_TARGET_PREVIEW Geometry the operator preview should draw.
%   The operator must see the experiment that will actually run. When
%   resolved acquisitions are supplied, every value here is derived from
%   them through the same canonical primitives execution uses
%   (apply_blue_mask_adjustment for Blue masks, apply_acquisition_parameters
%   for Orange expansion and 2P spiral geometry), so preview and acquisition
%   cannot disagree. Without them the preview falls back to the bundle's
%   default values, which is all a bundle on its own can describe.
arguments
    targets (1,1) struct
    mode (1,1) string {mustBeMember(mode,["1p_dmd","2p_spiral"])}
    options.ResolvedProtocols cell = {}
    options.ScannerTransform = []
    options.ScannerSampleRateHz (1,1) double {mustBePositive} = 200000
end
preview=struct("schema_version","1.0.0","mode",mode, ...
    "source","bundle_default", ...
    "blue",blue_entry([],"",NaN), ...
    "orange",orange_entry([],"",NaN), ...
    "spiral",spiral_entry("",[NaN NaN],NaN,NaN,[NaN NaN],NaN,struct));
preview.blue(:)=[]; preview.orange(:)=[]; preview.spiral(:)=[];
transform=options.ScannerTransform;
if isempty(transform) && isfield(targets,"scanner_transform")
    transform=targets.scanner_transform;
end

if isempty(options.ResolvedProtocols)
    for k=1:numel(targets.targets)
        cellId=string(targets.targets(k).cell_id);
        if mode=="1p_dmd"
            preview.blue(end+1)=blue_entry(targets.blue_camera_masks(:,:,k), ...
                cellId,targets.parameters.blue_mask_adjustment_pixels); %#ok<AGROW>
        end
        preview.orange(end+1)=orange_entry(targets.orange_camera_masks(:,:,k), ...
            cellId,targets.parameters.orange_expansion_pixels); %#ok<AGROW>
        if mode=="2p_spiral"
            preview.spiral(end+1)=spiral_from_target(targets.targets(k), ...
                targets.parameters.pulse_duration_ms,transform, ...
                options.ScannerSampleRateHz); %#ok<AGROW>
        end
    end
    return
end

preview.source="resolved_plan";
seenBlue=strings(0,1); seenOrange=strings(0,1); seenSpiral=strings(0,1);
for index=1:numel(options.ResolvedProtocols)
    protocol=adaptive_optopatch.normalize_protocol(options.ResolvedProtocols{index});
    resolved=adaptive_optopatch.apply_acquisition_parameters(targets,protocol);
    events=protocol.events;
    used=unique(double(events.target_index(~events.is_null)),"stable");
    for targetIndex=reshape(used,1,[])
        cellId=string(resolved.targets(targetIndex).cell_id);
        key=cellId+"_"+string(protocol.parameters.orange_expansion_pixels);
        if ~any(seenOrange==key)
            seenOrange(end+1,1)=key; %#ok<AGROW>
            preview.orange(end+1)=orange_entry( ...
                resolved.orange_camera_masks(:,:,targetIndex),cellId, ...
                protocol.parameters.orange_expansion_pixels); %#ok<AGROW>
        end
    end
    if mode=="1p_dmd"
        for k=reshape(find(~events.is_null),1,[])
            targetIndex=double(events.target_index(k));
            adjustment=double(events.blue_mask_adjustment_pixels(k));
            cellId=string(events.target_cell_id(k));
            key=cellId+"_"+string(adjustment);
            if any(seenBlue==key), continue; end
            seenBlue(end+1,1)=key; %#ok<AGROW>
            mask=adaptive_optopatch.apply_blue_mask_adjustment( ...
                targets.canonical_roi_masks(:,:,targetIndex),adjustment, ...
                "Context",sprintf("cell %s preview",cellId));
            preview.blue(end+1)=blue_entry(mask,cellId,adjustment); %#ok<AGROW>
        end
    else
        durations=events.duration_s(~events.is_null);
        pulseDurationMs=1000*min(durations,[],"omitmissing");
        for targetIndex=reshape(used,1,[])
            target=resolved.targets(targetIndex);
            cellId=string(target.cell_id);
            key=cellId+"_"+string(target.spiral_radius_um)+"_"+ ...
                string(target.spiral_density_points_per_volt)+"_"+ ...
                string(pulseDurationMs);
            if any(seenSpiral==key), continue; end
            seenSpiral(end+1,1)=key; %#ok<AGROW>
            preview.spiral(end+1)=spiral_from_target(target,pulseDurationMs, ...
                transform,options.ScannerSampleRateHz); %#ok<AGROW>
        end
    end
end
end

function entry=blue_entry(mask,cellId,adjustment)
entry=struct("mask",logical(mask),"cell_id",string(cellId), ...
    "adjustment_pixels",double(adjustment));
end

function entry=orange_entry(mask,cellId,expansion)
entry=struct("mask",logical(mask),"cell_id",string(cellId), ...
    "expansion_pixels",double(expansion));
end

function entry=spiral_entry(cellId,center,radius,density,parking,pulseMs,metrics)
entry=struct("cell_id",string(cellId),"center_xy",double(center), ...
    "radius_pixels",double(radius),"density_points_per_volt",double(density), ...
    "parking_xy",double(parking),"pulse_duration_ms",double(pulseMs), ...
    "cycle_metrics",metrics);
end

function entry=spiral_from_target(target,pulseDurationMs,transform,sampleRateHz)
metrics=struct("calibrated",false);
if isfinite(pulseDurationMs) && pulseDurationMs>0
    metrics=adaptive_optopatch.calculate_spiral_cycles(transform, ...
        target.spiral_center_xy,target.spiral_radius_pixels, ...
        target.spiral_density_points_per_volt,pulseDurationMs, ...
        "ScannerSampleRateHz",sampleRateHz);
end
entry=spiral_entry(target.cell_id,target.spiral_preview_center_xy, ...
    target.spiral_preview_radius_pixels, ...
    target.spiral_density_points_per_volt, ...
    target.parking_preview_point_xy,pulseDurationMs,metrics);
end
