function report=restore_camera_acquisition_state(camera,state)
%RESTORE_CAMERA_ACQUISITION_STATE Put the camera cadence back as it was found.
%   report=RESTORE_CAMERA_ACQUISITION_STATE(camera,state) writes back the
%   four properties CAPTURE_CAMERA_ACQUISITION_STATE recorded.
%
%   NOTHING HERE MAY THROW. This runs from the runner's onCleanup, which
%   means it runs on success, on error, on abort and on Ctrl-C - usually
%   while an exception is already on its way out - so a camera that refuses
%   one property must not stop the next one being restored and must not
%   replace the exception that says what actually went wrong. Each write is
%   attempted on its own and its outcome recorded.
%
%   A property the capture could not read is NOT written. There is nothing
%   to put back, and writing a default would be AO changing a camera setting
%   under the guise of restoring it.
%
%   Restoration order is trigger mode last. frametrigger_source is the
%   readout-mode switch, so moving the camera back out of synchronous
%   readout after its period and exposure are already back leaves the camera
%   in a state the operator would recognise at every intermediate step.
arguments
    camera
    state (1,1) struct
end
order=["daqtrig_period_ms","acquisition_exposuretime","frames_requested", ...
    "frametrigger_source"];
restored=strings(0,1);
skipped=strings(0,1);
failures=strings(0,1);
for name=order
    entry=state_entry(state,name);
    if ~entry.available
        skipped(end+1)=name; %#ok<AGROW>
        continue
    end
    try
        camera.(name)=entry.value;
        restored(end+1)=name; %#ok<AGROW>
    catch exception
        failures(end+1)=name+": "+string(exception.message); %#ok<AGROW>
    end
end
report=struct("schema_version","1.0.0", ...
    "restored_at",string(datetime("now","TimeZone","local")), ...
    "camera_name",field_or(state,"camera_name",""), ...
    "restored",restored, ...
    "not_captured",skipped, ...
    "failures",failures, ...
    "all_succeeded",isempty(failures));
end

function entry=state_entry(state,name)
entry=struct("available",false,"value",[]);
if ~isfield(state,name), return; end
candidate=state.(name);
if isstruct(candidate) && isfield(candidate,"available")
    entry=candidate;
end
end

function value=field_or(record,name,fallback)
value=fallback;
if isfield(record,name), value=record.(name); end
end
