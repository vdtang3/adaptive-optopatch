function report = preflight_trial(targets, trialRow, options)
%PREFLIGHT_TRIAL Validate a planned acquisition without touching hardware.
arguments
    targets (1,1) struct
    trialRow (1,:) table
    options.RequireConfirmedLiveProtocol (1,1) logical = true
    options.LiveProtocolConfirmed (1,1) logical = false
end
if height(trialRow)~=1
    error("adaptive_optopatch:SingleTrialRequired","Provide exactly one trial row.");
end
issues=strings(0,1);
warnings=strings(0,1);
required=["stimulation_mode","is_null","target_index","pulse_schedule"];
if ~all(ismember(required,string(trialRow.Properties.VariableNames)))
    issues(end+1)="Trial row is missing required fields.";
else
    protocol=trialRow.pulse_schedule{1};
    validation=adaptive_optopatch.validate_protocol(protocol);
    if ~validation.passed
        issues=[issues;validation.issues(:)];
    else
        try
            adaptive_optopatch.flatten_pulse_schedule( ...
                validation.protocol,"ConfiguredVoltage",1);
        catch exception
            issues(end+1)=string(exception.message);
        end
    end
    if ~trialRow.is_null
        idx=trialRow.target_index;
        if idx<1 || idx>numel(targets.targets)
            issues(end+1)="Target index is outside the target bundle.";
        elseif ~targets.targets(idx).qc_pass
            issues(end+1)="Target did not pass ROI/target QC.";
        end
    end
end
if options.RequireConfirmedLiveProtocol && ~options.LiveProtocolConfirmed
    warnings(end+1)="Live Luminos protocol is unconfirmed; dry-run only.";
end
if string(trialRow.stimulation_mode)=="2p_spiral"
    warnings(end+1)="Exact galvo voltage, repetition rate, and tracking checks "+ ...
        "remain pending live scanner calibration and feedback.";
end
report=struct("schema_version","0.2.0","passed",isempty(issues), ...
    "issues",issues,"warnings",warnings);
end
