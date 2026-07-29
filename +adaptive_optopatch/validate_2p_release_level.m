function report=validate_2p_release_level(manifest,level,options)
%VALIDATE_2P_RELEASE_LEVEL Enforce staged live-run restrictions.
arguments
    manifest (1,1) struct
    level (1,1) string {mustBeMember(level,["blocked_test","attenuated_test","experimental"])}
    options.ConfirmTrajectoryTest (1,1) logical = false
    options.ConfirmLiveOutput (1,1) logical = false
    options.ModulatorVoltageOverride (1,1) double = NaN
    options.HardwareValidationRecord (1,1) string = ""
end
issues=strings(0,1);
if ~isfield(manifest,"trials") || isempty(manifest.trials)
    issues(end+1)="Manifest has no trials.";
else
    trials=manifest.trials;
    if any(string(trials.stimulation_mode)~="2p_spiral")
        issues(end+1)="The staged 2P runner accepts only 2p_spiral trials.";
    end
end
if ~options.ConfirmTrajectoryTest
    issues(end+1)="Blocked trajectory review has not been confirmed.";
end
if level=="attenuated_test"
    if ~options.ConfirmLiveOutput
        issues(end+1)="Attenuated light output has not been explicitly armed.";
    end
    if ~isfinite(options.ModulatorVoltageOverride) || ...
            options.ModulatorVoltageOverride<=0
        issues(end+1)="Attenuated mode requires an explicit positive Pockels voltage.";
    end
    if ~isempty(manifest.trials)
        p=adaptive_optopatch.flatten_pulse_schedule(manifest.trials.pulse_schedule{1});
        if height(p)>10
            issues(end+1)="Attenuated test mode is limited to 10 pulses.";
        end
    end
elseif level=="experimental"
    if ~options.ConfirmLiveOutput
        issues(end+1)="Experimental light output has not been explicitly armed.";
    end
    if strlength(options.HardwareValidationRecord)==0 || ...
            ~isfile(options.HardwareValidationRecord)
        issues(end+1)="A galvo hardware-validation record is required.";
    end
end
if level=="experimental", maximumTrials=Inf; else, maximumTrials=1; end
report=struct("schema_version","0.1.0","release_level",level, ...
    "passed",isempty(issues),"issues",issues, ...
    "maximum_trials_this_call",maximumTrials);
end
