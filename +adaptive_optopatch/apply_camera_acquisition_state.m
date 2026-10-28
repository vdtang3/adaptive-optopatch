function [camera,plan]=apply_camera_acquisition_state(camera,profile,durationS)
%APPLY_CAMERA_ACQUISITION_STATE Impose AO's frame cadence on the voltage camera.
%   [camera,plan]=APPLY_CAMERA_ACQUISITION_STATE(camera,profile,durationS)
%   sets the four camera properties adaptive_optopatch owns during an
%   acquisition, from the rig profile's declared cadence and the protocol's
%   duration, and returns what it set.
%
%   AO used to READ these and refuse to proceed if the Camera tab happened
%   to be wrong - or worse, not refuse at all: a free-running camera fell
%   through to Camera.AutoN and recorded an untriggered movie whose frame
%   rate the archive could only guess at. The cadence is a property of the
%   experiment, so the experiment states it.
%
%   WHAT IS SET
%     frametrigger_source       "DAQ" - which IS the synchronous-readout
%                               switch: Camera.set.frametrigger_source calls
%                               Set_Readout_Mode(1), one frame per external
%                               trigger. Nothing else selects readout mode,
%                               and polarity, overlap, readout speed and
%                               acquisition mode have no MATLAB property.
%     daqtrig_period_ms         the frame period. Setup_Camera_Trigger_Waveforms
%                               turns it into the DO pulse train on the
%                               camera's trigger line.
%     acquisition_exposuretime  the same period in seconds. In synchronous
%                               readout a frame ends when the next trigger
%                               arrives, and Camera.calculate_framerate reads
%                               the exposure AS the period between triggers,
%                               so the two have to agree or the archived
%                               frame rate is a different number from the
%                               real one. Applied by Luminos's Prepare_Sync_Aq
%                               and restored by Luminos to the stream
%                               exposure afterwards; AO restores the setpoint.
%     frames_requested          ceil(duration x rate), the established
%                               semantics of set_camera_frames_for_duration.
%
%   WHAT IS NOT SET. ROI, binning and field of view stay the Camera tab's.
%
%   See also CAPTURE_CAMERA_ACQUISITION_STATE, RESTORE_CAMERA_ACQUISITION_STATE.
arguments
    camera
    profile (1,1) struct
    durationS (1,1) double {mustBePositive,mustBeFinite}
end
cadence=adaptive_optopatch.camera_cadence_for_profile(profile);
if ~cadence.declared
    error("adaptive_optopatch:ProfileDeclaresNoCameraCadence", ...
        "The rig profile declares no camera frame cadence, so AO cannot " + ...
        "take ownership of the camera timing.");
end
frameRateHz=1000/cadence.frame_period_ms;
frames=ceil(durationS*frameRateHz);

camera.frametrigger_source=cadence.frame_trigger_source;
camera.daqtrig_period_ms=cadence.frame_period_ms;
camera.acquisition_exposuretime=cadence.acquisition_exposure_s;
camera.frames_requested=frames;

plan=struct("schema_version","1.0.0", ...
    "applied_at",string(datetime("now","TimeZone","local")), ...
    "owner","adaptive_optopatch", ...
    "camera_name",camera_name(camera), ...
    "frame_trigger_source",cadence.frame_trigger_source, ...
    "frame_period_ms",cadence.frame_period_ms, ...
    "frame_rate_hz",frameRateHz, ...
    "acquisition_exposure_s",cadence.acquisition_exposure_s, ...
    "frames_requested",frames, ...
    "acquisition_duration_s",double(durationS), ...
    "readout_mode_expected",1, ...
    "readout_mode_note","frametrigger_source=DAQ selects Hamamatsu " + ...
        "synchronous-readout triggering through Camera.Set_Readout_Mode(1).", ...
    "inherited_from_camera_tab",["ROI","binning","field of view"]);
end

function value=camera_name(camera)
value="";
try
    value=string(camera.name);
catch
end
end
