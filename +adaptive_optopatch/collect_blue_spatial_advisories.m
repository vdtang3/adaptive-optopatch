function advisories=collect_blue_spatial_advisories(targets,targetCellIds)
%COLLECT_BLUE_SPATIAL_ADVISORIES Report nonblocking 1P targeting concerns.
arguments
    targets (1,1) struct
    targetCellIds string
end
advisories=struct("code",{},"message",{},"cell_id",{}, ...
    "previous_value",{},"current_value",{});
ids=string({targets.targets.cell_id});
for cellId=reshape(unique(targetCellIds(strlength(targetCellIds)>0),"stable"),1,[])
    index=find(ids==cellId,1);
    if isempty(index), continue; end
    target=targets.targets(index);
    if field_flag(target,"edge_flag",false)
        advisories(end+1)=item("blue_mask_near_edge", ...
            cellId+": Blue stimulation mask/ROI is near the camera ROI edge.", ...
            cellId,true); %#ok<AGROW>
    end
end
end

function value=item(code,message,cellId,current)
value=struct("code",string(code),"message",string(message), ...
    "cell_id",string(cellId),"previous_value",[],"current_value",current);
end

function value=field_flag(record,name,fallback)
if isfield(record,name), value=logical(record.(name)); else, value=fallback; end
end
