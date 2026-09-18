function report=neutralize_all_stimulation(app,options)
%NEUTRALIZE_ALL_STIMULATION Drive this modality's stimulation outputs safe.
%   report=NEUTRALIZE_ALL_STIMULATION(app,"Modality",m) puts each
%   stimulation system the rig manifest says adaptive_optopatch owns during
%   modality m into its declared neutral state. Defence in depth around the
%   buffered waveform, not a replacement for it: no pulse timing is decided
%   here, and nothing in this function is allowed to become the place an
%   experiment's light comes from.
%
%   MODALITY-AWARE, and deliberately not symmetric. Cleanup once neutralised
%   only the modality that had been selected, so a 1P run ended with the
%   Pockels cell and the galvos exactly as the last 2P run had left them.
%   The fix for that was to command everything every time, which was right
%   about the hazard and wrong about the remedy: it meant a 1P-only run
%   still issued explicit galvo and Pockels writes for hardware it had no
%   business touching. An output the manifest declares
%
%       owner.<modality> == "suppressed"
%
%   is not commanded at all - no device lookup, no setter, no explicit
%   galvo update - and is reported as suppressed rather than as a failure.
%   The 1P/2P asymmetry that started this is still closed, because what an
%   ACTIVE modality owns is unchanged: a 2P run still darkens mod488 and a
%   1P run still closes shutter488.
%
%   The declaration is the manifest's, read through MANIFEST_RUNTIME_OWNER,
%   so this function, the waveform builders and the accounting check all
%   answer "who drives this line" from one place. Nothing here decides for
%   itself that an output is inactive.
%
%   Modality "all" is the legacy scope and the default: every declared
%   output is commanded, which is what callers that have not stated a
%   modality still expect. It is not a rig modality and no manifest entry
%   can suppress under it.
%
%   Every step is attempted independently and its outcome recorded. A
%   device that is absent, or that throws, must not stop the next one from
%   being made safe - this runs during cleanup, often while an exception is
%   already propagating, and the report is how a caller finds out what
%   could not be done rather than an error that would replace the original.
%
%   Neutral values come from the manifest and the rig profiles. Nothing
%   here infers that zero is safe.
%
%   See also MANIFEST_RUNTIME_OWNER, VIRTUAL_UPRIGHT_STIMULATION_MANIFEST.
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
    % Which acquisition this is being made safe for. "all" keeps the
    % previous command-everything behaviour for callers that have not been
    % migrated; a real modality lets the manifest suppress what that
    % modality does not use.
    options.Modality (1,1) string {mustBeMember(options.Modality, ...
        ["1p_dmd","2p_spiral","mixed","all"])} = "all"
    options.Context (1,1) string = ""
end
oneP=options.OnePhotonProfile;
twoP=options.TwoPhotonProfile;
scope=struct("manifest",options.Manifest,"modality",options.Modality);

actions=struct("role",{},"action",{},"target",{},"value",{}, ...
    "succeeded",{},"message",{},"disposition",{});

% Beam shutters first. They are the only outputs here that remove light
% mechanically rather than by commanding an amplitude to zero, so they are
% worth having closed before anything else is attempted.
actions(end+1)=step(scope,"blue_shutter","blue_shutter","shutter closed", ...
    oneP.shutter.port,double(oneP.shutter.closed_state), ...
    @()set_property(app,"NI_DAQ_Shutter",oneP.shutter.name,"State", ...
        oneP.shutter.closed_state));

% Both modulators, each under its own declaration. A 2P run darkens mod488
% and a 1P run darkens the Pockels cell only if the manifest still says
% that modality drives it - which for 1P it no longer does.
actions(end+1)=step(scope,"blue_modulator","blue_modulator","modulator dark", ...
    oneP.modulator.port,double(oneP.modulator.dark_v), ...
    @()set_property(app,"NI_DAQ_Modulator",oneP.modulator.name,"level", ...
        oneP.modulator.dark_v));
actions(end+1)=step(scope,"two_photon_modulator","two_photon_modulator", ...
    "modulator dark",twoP.modulator.port,double(twoP.modulator.dark_v), ...
    @()set_property(app,"NI_DAQ_Modulator",twoP.modulator.name,"level", ...
        twoP.modulator.dark_v));

% The Blue DMD advance line, held at its declared safe state so no pattern
% can step while nothing is driving the buffered train.
actions(end+1)=step(scope,"blue_dmd_advance_trigger","blue_dmd_advance_trigger", ...
    "trigger safe state",oneP.dmd.trigger_port, ...
    double(twoP.inactive_one_photon.dmd.trigger_safe_state), ...
    @()set_property(app,"NI_DAQ_Shutter",oneP.dmd.trigger_alias,"State", ...
        logical(twoP.inactive_one_photon.dmd.trigger_safe_state)));

% A blank static pattern makes the Blue DMD non-stimulating even if light
% does reach it, which the trigger state alone cannot guarantee: the device
% holds whatever picture was last written. The pattern is not a terminal
% and has no declaration of its own, so it follows the advance line that
% steps it - the same Blue DMD subsystem, one ownership answer.
if options.BlankBlueDmd
    actions(end+1)=step(scope,"blue_dmd_advance_trigger","blue_dmd_pattern", ...
        "blank static write",oneP.dmd.name,NaN, ...
        @()blank_dmd(app,oneP.dmd.name));
end

% The galvos are parked at the stationary command the rig declares rather
% than left wherever a trajectory ended. Driven through the scanner's own
% explicit-update API; there is no separate "park" call on the device. One
% call drives both axes, so it is governed by both declarations and is only
% skipped when neither axis is commanded by this modality.
stationary=double(oneP.inactive_two_photon.scanner.stationary_v);
actions(end+1)=step(scope,["galvo_x","galvo_y"],"galvo_xy", ...
    "stationary command", ...
    twoP.scanner.x_port+", "+twoP.scanner.y_port,stationary(1), ...
    @()park_galvos(app,twoP.scanner.name,stationary));

suppressed=reshape(string({actions(is_suppressed_entry(actions)).role}),[],1);
report=struct("schema_version","1.1.0", ...
    "context",options.Context, ...
    "modality",options.Modality, ...
    "performed_at",string(datetime("now","TimeZone","local")), ...
    "rig_name",options.Manifest.rig_name, ...
    "actions",struct2table(actions,"AsArray",true), ...
    "all_succeeded",all([actions.succeeded]), ...
    "failures",reshape(string({actions(~[actions.succeeded]).role}),[],1), ...
    "suppressed",suppressed);
end

% -------------------------------------------------------------------------

function entry=step(scope,governingRoles,role,action,target,value,operation)
%STEP One neutralization action, performed only if this modality owns it.
%   The suppression test happens BEFORE anything touches the app, so a
%   suppressed output costs no device lookup - which is what makes
%   "suppressed" mean "not touched" rather than "resolved, then skipped",
%   and is why a rig with no 2P hardware at all can run 1P cleanly.
if suppressed_here(scope,governingRoles)
    entry=struct("role",string(role),"action",string(action), ...
        "target",string(target),"value",NaN, ...
        "succeeded",true,"message", ...
        "Not commanded: declared suppressed for modality "+scope.modality+".", ...
        "disposition","suppressed");
    return
end
entry=act(role,action,target,value,operation);
end

function tf=suppressed_here(scope,roles)
%SUPPRESSED_HERE Does this modality's declaration say to leave these alone?
tf=false;
% "all" is the legacy scope: not a rig modality, and nothing suppresses
% under it. Callers that have not stated which acquisition they are making
% safe keep the behaviour they had.
if scope.modality=="all", return; end
roles=reshape(string(roles),1,[]);
owners=strings(1,numel(roles));
for k=1:numel(roles)
    owners(k)=adaptive_optopatch.manifest_runtime_owner( ...
        declared_owner(scope.manifest,roles(k)),scope.modality);
end
% An action that drives more than one declared output at once is skipped
% only when every one of them is suppressed. If any is still this
% modality's, the action has work to do and runs.
tf=~isempty(owners) && all(owners=="suppressed");
end

function owner=declared_owner(manifest,role)
%DECLARED_OWNER The manifest's ownership struct for one AO-owned output.
%   An undeclared role is "unknown" rather than suppressed: this function
%   decides what NOT to make safe, so anything it cannot look up has to
%   fall through to being commanded.
owner=struct("one_photon","unknown","two_photon","unknown","mixed","unknown");
match=string({manifest.outputs.role})==string(role);
if any(match)
    owner=manifest.outputs(find(match,1)).owner;
end
end

function mask=is_suppressed_entry(actions)
mask=false(size(actions));
for k=1:numel(actions), mask(k)=actions(k).disposition=="suppressed"; end
end

function entry=act(role,action,target,value,operation)
entry=struct("role",string(role),"action",string(action), ...
    "target",string(target),"value",double(value), ...
    "succeeded",true,"message","","disposition","neutralized");
try
    operation();
catch exception
    entry.succeeded=false;
    entry.message=string(exception.message);
    entry.disposition="failed";
end
end

function set_property(app,deviceType,deviceName,property,value)
device=one_device(app,deviceType,deviceName);
device.(property)=value;
end

function blank_dmd(app,deviceName)
device=one_device(app,"DMD",deviceName);
device.Target=adaptive_optopatch.blank_dmd_pattern(device);
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
