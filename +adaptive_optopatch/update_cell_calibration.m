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
end
ids=string({fovState.cells.cell_id}); index=find(ids==cellId,1);
if isempty(index), error("adaptive_optopatch:UnknownCellId","Unknown cell ID: %s",cellId); end
if options.StimulationEnabled && (options.Status~="good" || ...
        ~isfinite(options.CommandVoltageV) || options.CommandVoltageV<=0)
    error("adaptive_optopatch:InvalidCellCalibration", ...
        "Enabled stimulation requires status good and a positive command voltage.");
end
fovState.cells(index).recording_enabled=options.RecordingEnabled;
fovState.cells(index).stimulation_enabled=options.StimulationEnabled;
fovState.cells(index).selected_blue_voltage_v=options.CommandVoltageV;
fovState.cells(index).calibration_status=options.Status;
fovState.cells(index).calibration_notes=options.Notes;
fovState.cells(index).calibration_acquisition=options.Acquisition;
fovState.reference.cells=fovState.cells;
fovState.updated_at=string(datetime("now","TimeZone","local"));
end
