function [globalProps,provenance]=build_luminos_global_props(profile,durationS,options)
%BUILD_LUMINOS_GLOBAL_PROPS The DAQ timing Adaptive Optopatch imposes on a run.
%   [globalProps,provenance]=BUILD_LUMINOS_GLOBAL_PROPS(profile,durationS)
%   returns the complete DAQ.global_props struct for one acquisition, built
%   from the rig profile and the protocol duration alone.
%
%   WHY THIS EXISTS. AO used to copy the struct the Waveforms tab had left
%   on the live DAQ and overwrite total_time in it, which made the sample
%   rate, the clock master, the start trigger and the self-trigger flag all
%   properties of whatever protocol somebody had loaded in another tab. The
%   rate is not a cosmetic inheritance: every 1P pulse boundary, the blanket
%   state table and the 2P galvo waveforms are sampled at it, so a tab left
%   on a different rate silently changed the experiment. AO now owns the
%   acquisition, so AO states the timing.
%
%   THE SIX FIELDS ARE THE WHOLE CONTRACT. Luminos reads exactly these from
%   global_props and nothing else - DAQ.Build_Waveforms takes total_time,
%   rate, clock_source, trigger_source and daq_master;
%   Setup_Camera_Trigger_Waveforms re-reads rate and total_time;
%   Waveform_Camera_Sync_Acquisition reads total_time; completion_trigger is
%   read by the standalone and cam-acquisition scripts. Adding a seventh
%   field here would configure nothing.
%
%   completion_trigger is "None", which DAQ.set_completion_trigger maps to
%   an empty terminal. AO does not emit an end-of-acquisition pulse.
%
%   See also RESOLVE_LUMINOS_1P_HARDWARE, VIRTUAL_UPRIGHT_1P_PROFILE.
arguments
    profile (1,1) struct
    durationS (1,1) double {mustBePositive,mustBeFinite}
    % The live DAQ, when one is available. Used ONLY to report what the
    % acquisition is replacing, never to take a value from: a run's timing
    % must not depend on what the last one left behind.
    options.PreviousGlobalProps = struct([])
end
if ~isfield(profile,"daq")
    error("adaptive_optopatch:ProfileDeclaresNoDaq", ...
        "The rig profile declares no DAQ, so AO cannot build its timing.");
end
daq=profile.daq;
rate=declared_rate(daq);
globalProps=struct( ...
    "total_time",double(durationS), ...
    "rate",rate, ...
    "clock_source",char(string(daq.default_clock)), ...
    "daq_master",double(logical(daq.requires_self_trigger)), ...
    "completion_trigger","None");
% Assigned rather than passed to struct(), which would read a multi-element
% trigger list as a request for a struct ARRAY. DAQ.Normalize_Trigger_Input
% accepts a string array directly, and capture_luminos_daq_sync reads it
% back through the same spelling the profile declares.
globalProps.trigger_source=reshape(string(daq.default_trigger),1,[]);

% What AO decided and what it displaced, archived with the run. A later
% reader asking "what rate was this recorded at, and did somebody's tab
% change it" should not have to infer the answer from sample counts.
provenance=struct("schema_version","1.0.0", ...
    "source","adaptive_optopatch.build_luminos_global_props", ...
    "profile_id",string(profile.profile_id), ...
    "rig_name",string(profile.rig_name), ...
    "sample_rate_hz",rate, ...
    "sample_rate_source",string(profile.profile_id)+".daq.sample_rate_hz", ...
    "duration_s",double(durationS), ...
    "sample_count",round(rate*double(durationS)), ...
    "clock_source",string(daq.default_clock), ...
    "start_triggers",reshape(string(daq.default_trigger),1,[]), ...
    "clock_bridge",reshape(string(daq.clock_bridge),1,[]), ...
    "daq_master",logical(daq.requires_self_trigger), ...
    "supported_internal_masters", ...
        reshape(string(daq.supported_internal_masters),1,[]), ...
    "synchronization_branch",string(daq.synchronization_branch), ...
    "replaced_active_waveform_settings",false, ...
    "previous",struct([]));
previous=options.PreviousGlobalProps;
if isstruct(previous) && ~isempty(fieldnames(previous))
    provenance.replaced_active_waveform_settings=true;
    provenance.previous=describe_previous(previous);
end
end

function rate=declared_rate(daq)
%DECLARED_RATE The profile's acquisition sample rate, refused if unusable.
%   A rig profile written before AO owned its own timing has no
%   sample_rate_hz, and there is no honest default for it: 1e5 is Luminos's
%   fallback for an empty Waveforms field, not a statement about any rig.
if ~isfield(daq,"sample_rate_hz")
    error("adaptive_optopatch:ProfileDeclaresNoSampleRate", ...
        "The rig profile declares no daq.sample_rate_hz, so AO cannot " + ...
        "build the acquisition timing itself. Add the rate the rig runs " + ...
        "at to the profile.");
end
rate=double(daq.sample_rate_hz);
if ~isscalar(rate) || ~isfinite(rate) || rate<=0
    error("adaptive_optopatch:InvalidProfileSampleRate", ...
        "The rig profile's daq.sample_rate_hz must be a positive rate.");
end
end

function value=describe_previous(previous)
%DESCRIBE_PREVIOUS The displaced settings, named rather than carried.
%   Only the five fields that would have decided the run. The rest of a
%   Waveforms struct is the operator's business and is not AO's to archive.
value=struct("total_time",field_or(previous,"total_time",NaN), ...
    "rate",field_or(previous,"rate",NaN), ...
    "clock_source",text_or(previous,"clock_source"), ...
    "trigger_source",text_or(previous,"trigger_source"), ...
    "daq_master",field_or(previous,"daq_master",NaN));
end

function value=field_or(record,name,fallback)
value=fallback;
if isfield(record,name) && ~isempty(record.(name))
    candidate=double(record.(name));
    if isscalar(candidate), value=candidate; end
end
end

function value=text_or(record,name)
value=strings(1,0);
if isfield(record,name) && ~isempty(record.(name))
    value=reshape(string(record.(name)),1,[]);
end
end
