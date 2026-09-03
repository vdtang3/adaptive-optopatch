function advisories=collect_calibration_advisories(reference,targets,protocol,options)
%COLLECT_CALIBRATION_ADVISORIES Describe nonblocking calibration drift.
arguments
    reference (1,1) struct
    targets (1,1) struct
    protocol (1,1) struct
    options.CurrentObisPowerW (1,1) double = NaN
end
protocol=adaptive_optopatch.normalize_protocol(protocol);
advisories=empty_advisories();
ids=string({targets.targets.cell_id});
used=unique(protocol.events.target_cell_id(~protocol.events.is_null),"stable");
for cellId=reshape(used,1,[])
    index=find(ids==cellId,1);
    if isempty(index), continue; end
    target=targets.targets(index);
    calibration=struct([]);
    if isfield(target,"blue_calibration"), calibration=target.blue_calibration; end
    if isempty(calibration)
        advisories(end+1)=item("incomplete_calibration_metadata", ...
            cellId+": calibration conditions were not recorded; current settings will be archived.", ...
            cellId,[],[]); %#ok<AGROW>
        continue
    end
    snapshotFields=["selected_voltage_v","pulse_duration_ms", ...
        "blue_mask_adjustment_pixels","blue_mask_area_pixels", ...
        "roi_polygon","obis_power_w","calibration_acquisition", ...
        "selected_at","notes"];
    missing=snapshotFields(~isfield(calibration,snapshotFields));
    if ~isempty(missing)
        advisories(end+1)=item("incomplete_calibration_metadata", ...
            cellId+": calibration metadata is incomplete (missing "+ ...
            strjoin(missing,", ")+").",cellId,missing,[]); %#ok<AGROW>
    end
    if isfield(calibration,"selected_at") && strlength(string(calibration.selected_at))>0
        try
            ageDays=days(datetime("now","TimeZone","local")-datetime(calibration.selected_at));
            if ageDays>30
                advisories(end+1)=item("calibration_old", ...
                    sprintf('%s: calibration is %.0f days old.',cellId,ageDays), ...
                    cellId,calibration.selected_at,ageDays); %#ok<AGROW>
            end
        catch
        end
    end
    currentAdjustment=field_or(targets.parameters,"blue_mask_adjustment_pixels",NaN);
    advisories=compare_number(advisories,calibration, ...
        "blue_mask_adjustment_pixels",currentAdjustment,0, ...
        "blue_mask_adjustment_changed",cellId, ...
        "Blue mask adjustment"," px");
    currentMaskArea=nnz(targets.blue_camera_masks(:,:,index));
    advisories=compare_number(advisories,calibration, ...
        "blue_mask_area_pixels",currentMaskArea,0, ...
        "blue_mask_area_changed",cellId,"Blue mask area"," pixels");
    pulseDurationMs=representative_duration_ms(protocol,cellId);
    advisories=compare_number(advisories,calibration,"pulse_duration_ms", ...
        pulseDurationMs,max(1e-6,1e-6*abs(pulseDurationMs)), ...
        "pulse_duration_changed",cellId,"pulse duration"," ms");
    advisories=compare_number(advisories,calibration,"obis_power_w", ...
        options.CurrentObisPowerW,max(1e-9,1e-6*abs(options.CurrentObisPowerW)), ...
        "obis_setpoint_changed",cellId,"OBIS setpoint"," W");
    selected=field_or(target,"selected_blue_voltage_v",NaN);
    advisories=compare_number(advisories,calibration,"selected_voltage_v", ...
        selected,max(1e-9,1e-6*abs(selected)), ...
        "selected_voltage_changed",cellId,"selected Blue voltage"," V");
    protocolVoltages=unique(protocol.events.command_voltage_v( ...
        ~protocol.events.is_null & protocol.events.target_cell_id==cellId));
    if isfinite(selected) && any(isfinite(protocolVoltages)) && ...
            any(abs(protocolVoltages(isfinite(protocolVoltages))-selected)> ...
            max(1e-9,1e-6*abs(selected)))
        advisories(end+1)=item("frozen_protocol_voltage_differs", ...
            sprintf('%s: protocol voltage differs from the current FOV voltage; the frozen protocol value will be used.',cellId), ...
            cellId,selected,protocolVoltages); %#ok<AGROW>
    end
    polygon=current_polygon(reference,index);
    if isfield(calibration,"roi_polygon") && ~isempty(calibration.roi_polygon) && ...
            ~same_polygon(double(calibration.roi_polygon),polygon,1e-6)
        advisories(end+1)=item("roi_geometry_changed", ...
            cellId+": ROI geometry has changed since calibration.", ...
            cellId,calibration.roi_polygon,polygon); %#ok<AGROW>
    end
end
end

function advisories=compare_number(advisories,record,name,current,tolerance,code,cellId,label,unit)
if ~isfield(record,name), return; end
previous=double(record.(name));
if ~isscalar(previous) || ~isfinite(previous) || ~isfinite(current), return; end
if abs(previous-current)<=tolerance, return; end
message=sprintf('%s: %s changed from %.6g%s to %.6g%s since calibration.', ...
    cellId,label,previous,unit,current,unit);
advisories(end+1)=item(code,message,cellId,previous,current);
end

function value=representative_duration_ms(protocol,cellId)
selected=~protocol.events.is_null & protocol.events.target_cell_id==cellId;
durations=1000*protocol.events.duration_s(selected);
if isempty(durations), value=NaN; else, value=durations(1); end
end

function polygon=current_polygon(reference,index)
polygon=zeros(0,2);
if isfield(reference.cells,"canonical_roi_polygon")
    polygon=double(reference.cells(index).canonical_roi_polygon);
end
end

function tf=same_polygon(a,b,tolerance)
tf=false;
if ~isequal(size(a),size(b)), return; end
if isempty(a), tf=true; return; end
n=size(a,1);
for shift=0:n-1
    candidate=circshift(b,shift,1);
    if max(abs(a-candidate),[],"all")<=tolerance, tf=true; return; end
    candidate=circshift(flipud(b),shift,1);
    if max(abs(a-candidate),[],"all")<=tolerance, tf=true; return; end
end
end

function value=field_or(record,name,fallback)
if isfield(record,name), value=double(record.(name)); else, value=fallback; end
end

function value=item(code,message,cellId,previous,current)
value=struct("code",string(code),"message",string(message), ...
    "cell_id",string(cellId),"previous_value",previous,"current_value",current);
end

function values=empty_advisories()
values=struct("code",{},"message",{},"cell_id",{}, ...
    "previous_value",{},"current_value",{});
end
