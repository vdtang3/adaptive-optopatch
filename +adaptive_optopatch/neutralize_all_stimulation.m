function report=neutralize_all_stimulation(app,options)
%NEUTRALIZE_ALL_STIMULATION Drive every AO-owned stimulation output safe.
%   report=NEUTRALIZE_ALL_STIMULATION(app) puts each stimulation system the
%   rig manifest says adaptive_optopatch owns into its declared neutral
%   state, whichever modality happens to be running. Defence in depth
%   around the buffered waveform, not a replacement for it: no pulse timing
%   is decided here, and nothing in this function is allowed to become the
%   place an experiment's light comes from.
%
%   Symmetric on purpose. Cleanup used to neutralise only the modality that
%   had been selected, so a 1P run ended with the Pockels cell and the
%   galvos left exactly as the last 2P run had them, and a 2P run ended
%   with mod488 untouched. Neither is the modality's business: the rig has
%   one preparation under it and both beams reach it.
%
%   Every step is attempted independently and its outcome recorded. A
%   device that is absent, or that throws, must not stop the next one from
%   being made safe - this runs during cleanup, often while an exception is
%   already propagating, and the report is how a caller finds out what
%   could not be done rather than an error that would replace the original.
%
%   Neutral values come from the manifest and the rig profiles. Nothing
%   here infers that zero is safe.
arguments
    app
    options.Manifest (1,1) struct = ...
        adaptive_optopatch.virtual_upright_stimulation_manifest()
    options.OnePhotonProfile (1,1) struct = ...
        adaptive_optopatch.virtual_upright_1p_profile()
    options.TwoPhotonProfile (1,1) struct = ...
        adaptive_optopatch.virtual_upright_2p_profile()
    % Writing a blank pattern costs a DMD round trip. Cleanup wants it;
    % the per-trial reassertion before arming does not, because the trial
    % is about to write the pattern it needs.
    options.BlankBlueDmd (1,1) logical = true
    options.Context (1,1) string = ""
end
oneP=options.OnePhotonProfile;
twoP=options.TwoPhotonProfile;

actions=struct("role",{},"action",{},"target",{},"value",{}, ...
    "succeeded",{},"message",{});

% Beam shutters first. They are the only outputs here that remove light
% mechanically rather than by commanding an amplitude to zero, so they are
% worth having closed before anything else is attempted.
actions(end+1)=act("blue_shutter","shutter closed",oneP.shutter.port, ...
    double(oneP.shutter.closed_state), ...
    @()set_property(app,"NI_DAQ_Shutter",oneP.shutter.name,"State", ...
        oneP.shutter.closed_state));

% Modulators. Both of them, every time: this is the asymmetry that mattered.
actions(end+1)=act("blue_modulator","modulator dark",oneP.modulator.port, ...
    double(oneP.modulator.dark_v), ...
    @()set_property(app,"NI_DAQ_Modulator",oneP.modulator.name,"level", ...
        oneP.modulator.dark_v));
actions(end+1)=act("two_photon_modulator","modulator dark",twoP.modulator.port, ...
    double(twoP.modulator.dark_v), ...
    @()set_property(app,"NI_DAQ_Modulator",twoP.modulator.name,"level", ...
        twoP.modulator.dark_v));

% The Blue DMD advance line, held at its declared safe state so no pattern
% can step while nothing is driving the buffered train.
actions(end+1)=act("blue_dmd_advance_trigger","trigger safe state", ...
    oneP.dmd.trigger_port, ...
    double(twoP.inactive_one_photon.dmd.trigger_safe_state), ...
    @()set_property(app,"NI_DAQ_Shutter",oneP.dmd.trigger_alias,"State", ...
        logical(twoP.inactive_one_photon.dmd.trigger_safe_state)));

% A blank static pattern makes the Blue DMD non-stimulating even if light
% does reach it, which the trigger state alone cannot guarantee: the device
% holds whatever picture was last written.
if options.BlankBlueDmd
    actions(end+1)=act("blue_dmd_pattern","blank static write",oneP.dmd.name, ...
        NaN,@()blank_dmd(app,oneP.dmd.name));
end

% The galvos are parked at the stationary command the rig declares rather
% than left wherever a trajectory ended. Driven through the scanner's own
% explicit-update API; there is no separate "park" call on the device.
stationary=double(oneP.inactive_two_photon.scanner.stationary_v);
actions(end+1)=act("galvo_xy","stationary command", ...
    twoP.scanner.x_port+", "+twoP.scanner.y_port,stationary(1), ...
    @()park_galvos(app,twoP.scanner.name,stationary));

report=struct("schema_version","1.0.0", ...
    "context",options.Context, ...
    "performed_at",string(datetime("now","TimeZone","local")), ...
    "rig_name",options.Manifest.rig_name, ...
    "actions",struct2table(actions,"AsArray",true), ...
    "all_succeeded",all([actions.succeeded]), ...
    "failures",reshape(string({actions(~[actions.succeeded]).role}),[],1));
end

function entry=act(role,action,target,value,operation)
entry=struct("role",string(role),"action",string(action), ...
    "target",string(target),"value",double(value), ...
    "succeeded",true,"message","");
try
    operation();
catch exception
    entry.succeeded=false;
    entry.message=string(exception.message);
end
end

function set_property(app,deviceType,deviceName,property,value)
device=one_device(app,deviceType,deviceName);
device.(property)=value;
end

function blank_dmd(app,deviceName)
device=one_device(app,"DMD",deviceName);
device.Target=false(device.Dimensions);
device.Write_Static();
end

function park_galvos(app,deviceName,stationary)
device=one_device(app,"Scanning_Device",deviceName);
device.Update_Galvos_Explicit(stationary(1),stationary(2));
end

function device=one_device(app,deviceType,deviceName)
device=app.getDevice(deviceType,"name",deviceName,"displayWarning",false);
if numel(device)~=1
    error("adaptive_optopatch:NeutralizationDeviceNotUnique", ...
        "Expected one %s named '%s'; found %d.",deviceType,deviceName, ...
        numel(device));
end
end
