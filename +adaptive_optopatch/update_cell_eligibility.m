function fovState=update_cell_eligibility(fovState,cellId,options)
%UPDATE_CELL_ELIGIBILITY Update independent recording/stimulation flags.
arguments
    fovState (1,1) struct
    cellId (1,1) string
    options.RecordingEnabled = []
    options.StimulationEnabled = []
end
ids=string({fovState.cells.cell_id});
index=find(ids==cellId,1);
if isempty(index)
    error("adaptive_optopatch:UnknownCellId","Unknown cell ID: %s",cellId);
end
if ~isempty(options.RecordingEnabled)
    validate_flag(options.RecordingEnabled,"RecordingEnabled");
    fovState.cells(index).recording_enabled=logical(options.RecordingEnabled);
end
if ~isempty(options.StimulationEnabled)
    validate_flag(options.StimulationEnabled,"StimulationEnabled");
    fovState.cells(index).stimulation_enabled=logical(options.StimulationEnabled);
end
fovState.reference.cells=fovState.cells;
fovState.updated_at=string(datetime("now","TimeZone","local"));
end

function validate_flag(value,name)
if ~isscalar(value) || ~(islogical(value) || isnumeric(value)) || ...
        ~isfinite(double(value)) || ~ismember(double(value),[0 1])
    error("adaptive_optopatch:InvalidCellEligibility", ...
        "%s must be a scalar logical value.",name);
end
end
