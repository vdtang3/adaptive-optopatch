function level=orange_recording_voltage(profile)
%ORANGE_RECORDING_VOLTAGE The validated 594 nm command for an AO recording.
%   level=ORANGE_RECORDING_VOLTAGE(profile) returns the Orange recording
%   voltage the rig profile carries, refusing anything the declared
%   modulator cannot be commanded to.
%
%   THERE IS NO DEFAULT, and that is the point. This value used to arrive
%   as whatever constant the operator's Waveforms protocol had on mod594,
%   which meant it was chosen once, against a live view, by somebody looking
%   at the preparation. AO replacing it with a number of its own choosing
%   would change everybody's illumination and therefore everybody's
%   photobleaching and signal-to-noise, silently. Zero would be worse: a
%   recording in the dark is a wasted slice, and it would look like a
%   configuration that worked.
%
%   So the plan refuses to become runnable until somebody has set it. The
%   intended workflow is in the README: project the recording mask with
%   "Show recording mask", tune the ordinary Luminos orange control while
%   watching the live camera, and enter the value that looked right.
%
%   See also BUILD_LUMINOS_MIXED_WAVEFORM_CONFIG, PREPARE_LUMINOS_ORANGE_MASK.
arguments
    profile (1,1) struct
end
if ~isfield(profile,"orange_modulator")
    error("adaptive_optopatch:OrangeModulatorNotDeclared", ...
        "The active rig profile declares no orange recording modulator.");
end
modulator=profile.orange_modulator;
level=double(modulator.recording_v);
if ~isscalar(level) || ~isfinite(level)
    error("adaptive_optopatch:OrangeRecordingVoltageUnset", ...
        "Set the Orange recording voltage before running. Adaptive " + ...
        "Optopatch drives %s during its acquisitions and has no default " + ...
        "value for it: show the recording mask, tune the ordinary Luminos " + ...
        "orange control against the live camera, and enter the voltage " + ...
        "that looked right.",modulator.name);
end
minimum=double(modulator.minimum_v); maximum=double(modulator.maximum_v);
if level<minimum || level>maximum
    error("adaptive_optopatch:OrangeRecordingVoltageOutOfRange", ...
        "The Orange recording voltage %.4g V is outside the %.3g-%.3g V " + ...
        "range the rig declares for %s.",level,minimum,maximum,modulator.name);
end
end
