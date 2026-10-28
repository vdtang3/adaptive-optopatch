function state=capture_camera_acquisition_state(camera)
%CAPTURE_CAMERA_ACQUISITION_STATE Read the camera cadence AO is about to take.
%   state=CAPTURE_CAMERA_ACQUISITION_STATE(camera) records the four camera
%   properties adaptive_optopatch sets for the length of an acquisition, so
%   that RESTORE_CAMERA_ACQUISITION_STATE can put the camera back exactly as
%   the operator left it.
%
%   FOUR PROPERTIES, and deliberately not the camera's whole state. ROI,
%   binning and field of view are the Camera tab's and AO never writes them,
%   so capturing them would imply a restore that could undo an operator's
%   deliberate change mid-run. What is captured is what is written.
%
%   Each property is read independently and a property the backend does not
%   expose is recorded as missing rather than as a value, because a restore
%   must never write a default over something it failed to read.
%
%   See also APPLY_CAMERA_ACQUISITION_STATE, RESTORE_CAMERA_ACQUISITION_STATE.
arguments
    camera
end
state=struct("schema_version","1.0.0", ...
    "captured_at",string(datetime("now","TimeZone","local")), ...
    "camera_name",read_text(camera,"name"), ...
    "frametrigger_source",read_member(camera,"frametrigger_source"), ...
    "daqtrig_period_ms",read_member(camera,"daqtrig_period_ms"), ...
    "acquisition_exposuretime",read_member(camera,"acquisition_exposuretime"), ...
    "frames_requested",read_member(camera,"frames_requested"));
end

function value=read_text(camera,name)
value="";
entry=read_member(camera,name);
if entry.available, value=string(entry.value); end
end

function entry=read_member(object,name)
%READ_MEMBER One property, with whether it could be read at all.
%   available=false is the restore's instruction to leave that property
%   alone. A camera that cannot report its exposure cannot be given one
%   back, and inventing one here would be a silent write.
entry=struct("available",false,"value",[]);
try
    if isstruct(object)
        if ~isfield(object,name), return; end
    elseif ~isprop(object,name)
        return
    end
    entry.value=object.(name);
    entry.available=true;
catch
end
end
