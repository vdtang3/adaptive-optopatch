function report=validate_2p_release_level(manifest,level,options)
%VALIDATE_2P_RELEASE_LEVEL Enforce staged live-run restrictions.
arguments
    manifest (1,1) struct
    level (1,1) string {mustBeMember(level,["blocked_test","attenuated_test", ...
        "pilot_single","pilot_mixed_trains","experimental","standard"])}
    options.ConfirmTrajectoryTest (1,1) logical = false
    options.ConfirmLiveOutput (1,1) logical = false
    options.ModulatorVoltageOverride (1,1) double = NaN
    options.HardwareValidationRecord (1,1) string = ""
    options.TrialIndex (1,1) double {mustBePositive,mustBeInteger} = 1
end
issues=strings(0,1);
trialIndex=options.TrialIndex;
if ~isfield(manifest,"trials") || isempty(manifest.trials)
    issues(end+1)="Manifest has no trials.";
else
    trials=manifest.trials;
    if any(string(trials.stimulation_mode)~="2p_spiral")
        issues(end+1)="The staged 2P runner accepts only 2p_spiral trials.";
    end
    if trialIndex>height(trials)
        issues(end+1)="The selected trial index is outside the manifest.";
        trialIndex=1;
    end
end
if level~="standard" && ~options.ConfirmTrajectoryTest
    issues(end+1)="Blocked trajectory review has not been confirmed.";
end
% The explicit Pockels voltage is the command these light-on commissioning
% acquisitions physically execute at (run_2p_manifest applies it verbatim), so
% it is required here and rejected where it would otherwise be discarded.
profile=adaptive_optopatch.virtual_upright_2p_profile();
if ismember(level,["attenuated_test","pilot_single","pilot_mixed_trains"])
    if ~options.ConfirmLiveOutput
        issues(end+1)="Live 2P output has not been explicitly armed.";
    end
    if ~isfinite(options.ModulatorVoltageOverride) || ...
            options.ModulatorVoltageOverride<=0
        issues(end+1)="This light-on mode requires an explicit positive Pockels voltage.";
    elseif options.ModulatorVoltageOverride>profile.modulator.maximum_v
        issues(end+1)=sprintf( ...
            "The requested %.4g V test command exceeds the %.4g V 2P modulator limit.", ...
            options.ModulatorVoltageOverride,profile.modulator.maximum_v);
    end
    if isfield(manifest,"trials") && ~isempty(manifest.trials)
        selectedType=string(manifest.trials.pulse_schedule{trialIndex}.protocol_type);
        if level=="pilot_single" && selectedType~="connectivity_screen"
            issues(end+1)="pilot_single requires a connectivity-screen protocol.";
        elseif level=="pilot_mixed_trains" && selectedType~="stf_mixed_conditions"
            issues(end+1)="pilot_mixed_trains requires a mixed STF protocol.";
        end
    end
elseif isfinite(options.ModulatorVoltageOverride) && ...
        options.ModulatorVoltageOverride>0
    if level=="blocked_test"
        issues(end+1)="blocked_test commands 0 V. Remove the Pockels voltage "+ ...
            "or select a light-on release level.";
    else
        issues(end+1)=level+" executes the frozen resolved command voltage. "+ ...
            "Remove the Pockels override or select a staged release level.";
    end
end
if level=="experimental"
    if ~options.ConfirmLiveOutput
        issues(end+1)="Experimental light output has not been explicitly armed.";
    end
    if strlength(options.HardwareValidationRecord)==0 || ...
            ~isfile(options.HardwareValidationRecord)
        issues(end+1)="A galvo hardware-validation record is required.";
    else
        try
            saved=load(options.HardwareValidationRecord,"galvo_hardware_validation");
            required=["passed","feedback_recorded","phase_validated", ...
                "terminal_return_validated","calibration_id"];
            if ~isfield(saved,"galvo_hardware_validation") || ...
                    ~all(isfield(saved.galvo_hardware_validation,required)) || ...
                    ~all([logical(saved.galvo_hardware_validation.passed), ...
                    logical(saved.galvo_hardware_validation.feedback_recorded), ...
                    logical(saved.galvo_hardware_validation.phase_validated), ...
                    logical(saved.galvo_hardware_validation.terminal_return_validated)])
                issues(end+1)="The galvo hardware-validation record is incomplete or did not pass.";
            end
        catch exception
            issues(end+1)="Could not read hardware-validation record: "+ ...
                string(exception.message);
        end
    end
end
if ismember(level,["experimental","standard"]), maximumTrials=Inf; else, maximumTrials=1; end
report=struct("schema_version","0.1.0","release_level",level, ...
    "passed",isempty(issues),"issues",issues, ...
    "maximum_trials_this_call",maximumTrials);
end
