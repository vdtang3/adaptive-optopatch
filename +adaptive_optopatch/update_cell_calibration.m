function fovState=update_cell_calibration(fovState,cellId,options)
%UPDATE_CELL_CALIBRATION Store the operator's calibration decision.
arguments
    fovState (1,1) struct
    cellId (1,1) string
    options.CommandVoltageV (1,1) double = NaN
    options.Status (1,1) string {mustBeMember(options.Status, ...
        ["uncalibrated","good","unreliable","multispike","off_target","excluded"])} = "good"
    options.StimulationEnabled (1,1) logical = true
    options.RecordingEnabled (1,1) logical = true
    options.Notes (1,1) string = ""
    options.Acquisition (1,1) string = ""
    options.PulseDurationMs (1,1) double = NaN
    options.ObisPowerW (1,1) double = NaN
    options.ReplaceCalibrationSnapshot (1,1) logical = true
end
ids=string({fovState.cells.cell_id}); index=find(ids==cellId,1);
if isempty(index), error("adaptive_optopatch:UnknownCellId","Unknown cell ID: %s",cellId); end
if options.StimulationEnabled && ...
        (~isfinite(options.CommandVoltageV) || options.CommandVoltageV<=0)
    error("adaptive_optopatch:InvalidCellCalibration", ...
        "Enabled stimulation requires a positive finite command voltage.");
end
oldCalibration=struct([]);
if isfield(fovState.cells,"blue_calibration")
    oldCalibration=fovState.cells(index).blue_calibration;
end
fovState.cells(index).recording_enabled=options.RecordingEnabled;
fovState.cells(index).stimulation_enabled=options.StimulationEnabled;
fovState.cells(index).selected_blue_voltage_v=options.CommandVoltageV;
fovState.cells(index).calibration_status=options.Status;
fovState.cells(index).calibration_notes=options.Notes;
fovState.cells(index).calibration_acquisition=options.Acquisition;
if options.ReplaceCalibrationSnapshot
    if ~isempty(oldCalibration)
        history=struct([]);
        if isfield(fovState.cells,"blue_calibration_history")
            history=fovState.cells(index).blue_calibration_history;
        end
        fovState.cells(index).blue_calibration_history=append_compatible(history,oldCalibration);
    end
    fovState.cells(index).blue_calibration=make_snapshot( ...
        fovState,index,options.CommandVoltageV,options.PulseDurationMs, ...
        options.ObisPowerW,options.Acquisition,options.Notes);
end
fovState.reference.cells=fovState.cells;
fovState.updated_at=string(datetime("now","TimeZone","local"));
end

function snapshot=make_snapshot(fovState,index,voltage,pulseDurationMs,obisPowerW,acquisition,notes)
polygon=zeros(0,2);
if isfield(fovState,"canonical_roi_polygons") && ...
        numel(fovState.canonical_roi_polygons)>=index
    polygon=double(fovState.canonical_roi_polygons{index});
elseif isfield(fovState.cells,"canonical_roi_polygon")
    polygon=double(fovState.cells(index).canonical_roi_polygon);
end
mask=fovState.canonical_roi_masks(:,:,index);
adjustment=NaN;
if isfield(fovState,"blue_mask_adjustment_pixels")
    adjustment=double(fovState.blue_mask_adjustment_pixels);
end
blueMask=mask;
if isfinite(adjustment) && adjustment<0
    candidate=imerode(mask,strel("disk",abs(adjustment),0));
    if any(candidate,"all"), blueMask=candidate; end
elseif isfinite(adjustment) && adjustment>0
    blueMask=imdilate(mask,strel("disk",adjustment,0));
end
snapshot=struct("selected_voltage_v",double(voltage), ...
    "pulse_duration_ms",double(pulseDurationMs), ...
    "blue_mask_adjustment_pixels",adjustment, ...
    "blue_mask_area_pixels",nnz(blueMask), ...
    "roi_polygon",polygon,"obis_power_w",double(obisPowerW), ...
    "calibration_acquisition",string(acquisition), ...
    "selected_at",string(datetime("now","TimeZone","local")), ...
    "notes",string(notes));
end

function values=append_compatible(values,value)
if isempty(values), values=value; return; end
names=union(fieldnames(values),fieldnames(value),'stable');
for k=1:numel(names)
    if ~isfield(values,names{k}), [values.(names{k})]=deal([]); end
    if ~isfield(value,names{k}), value.(names{k})=[]; end
end
values(end+1)=orderfields(value,values);
end
