function staging=plan_staged_2p_execution(manifest,level,options)
%PLAN_STAGED_2P_EXECUTION Describe which subset of a frozen 2P manifest runs now.
%   The frozen manifest is immutable acquisition truth. Commissioning release
%   levels deliberately exercise only part of it, at a command voltage the
%   operator states explicitly. That choice is execution state, so it is
%   returned here as staging metadata and applied to a working copy of the
%   frozen schedule at execution time; the manifest itself is never rewritten.
arguments
    manifest (1,1) struct
    level (1,1) string {mustBeMember(level,["blocked_test","attenuated_test", ...
        "pilot_single","pilot_mixed_trains","experimental","standard"])}
    options.TestPulseCount (1,1) double {mustBePositive,mustBeInteger} = 1
    options.ModulatorVoltageOverride (1,1) double = NaN
end
if ~isfield(manifest,"trials") || isempty(manifest.trials)
    error("adaptive_optopatch:EmptyManifest","The manifest has no trials.");
end
trials=manifest.trials;
staging=struct("schema_version","1.0.0","release_level",level, ...
    "staged",false,"source_trial_index",1, ...
    "source_trial_id",trials.trial_id(1), ...
    "executed_event_count",NaN, ...
    "output_tag_suffix","", ...
    "command_voltage_policy","frozen", ...
    "command_voltage_v",NaN);

if ismember(level,["experimental","standard"])
    return
end

index=find(~trials.is_null,1);
if isempty(index)
    error("adaptive_optopatch:NoStimulatedTrial","No non-null 2P trial was found.");
end
staging.staged=true;
staging.source_trial_index=index;
staging.source_trial_id=trials.trial_id(index);
staging.output_tag_suffix="_"+level;

protocol=adaptive_optopatch.normalize_protocol(trials.pulse_schedule{index});
if ismember(level,["blocked_test","attenuated_test"])
    if ~isfield(protocol,"protocol_type") || ...
            string(protocol.protocol_type)~="connectivity_screen"
        error("adaptive_optopatch:StagedScreenProtocolRequired", ...
            "Blocked and attenuated tests currently require a connectivity-screen protocol.");
    end
    if options.TestPulseCount>height(protocol.events)
        error("adaptive_optopatch:TestPulseCountExceedsFrozenSchedule", ...
            "The staged test requests %d pulses, but the frozen acquisition contains only %d.", ...
            options.TestPulseCount,height(protocol.events));
    end
    staging.executed_event_count=options.TestPulseCount;
end

% blocked_test physically blocks the beam by commanding 0 V. Every other
% staged level is a light-on commissioning acquisition whose command is the
% explicitly confirmed Pockels voltage, not the frozen experimental value;
% validate_2p_release_level requires that voltage to be present.
if level=="blocked_test"
    staging.command_voltage_policy="blocked";
    staging.command_voltage_v=0;
else
    staging.command_voltage_policy="explicit_test_command";
    staging.command_voltage_v=options.ModulatorVoltageOverride;
end
end
