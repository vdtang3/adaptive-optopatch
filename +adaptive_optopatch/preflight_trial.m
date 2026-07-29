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
    if ~isfield(protocol,"events") || isempty(protocol.events)
        issues(end+1)="Pulse schedule is empty.";
    elseif isfield(protocol,"protocol_type") && protocol.protocol_type=="stf_mixed_conditions"
        events=protocol.events;
        if any(events.modulator_voltage<0 | events.modulator_voltage>5)
            issues(end+1)="An STF modulator command lies outside 0-5 V.";
        end
        if any(events.event_offset_s<=events.event_onset_s)
            issues(end+1)="An STF event has nonpositive duration.";
        end
        if height(events)>1 && ...
                any(events.event_onset_s(2:end)<events.event_offset_s(1:end-1))
            issues(end+1)="STF event schedule contains overlaps.";
        end
        for e=1:height(events)
            times=events.pulse_times_s{e};
            if numel(times)>1 && any(diff(times)<=0)
                issues(end+1)="An STF train contains nonincreasing pulse times."; %#ok<AGROW>
            end
        end
        if abs(protocol.acquisition_duration_s- ...
                (events.event_offset_s(end)+protocol.post_delay_ms/1000))>1e-9
            issues(end+1)="Acquisition duration does not match the STF schedule.";
        end
    else
        events=protocol.events;
        if any(events.modulator_voltage<0 | events.modulator_voltage>5)
            issues(end+1)="A modulator command lies outside 0-5 V.";
        end
        if any(events.offset_s<=events.onset_s)
            issues(end+1)="A pulse has nonpositive duration.";
        end
        if height(events)>1 && any(events.onset_s(2:end)<events.offset_s(1:end-1))
            issues(end+1)="Pulse schedule contains overlapping pulses.";
        end
        if abs(protocol.acquisition_duration_s- ...
                (events.offset_s(end)+protocol.post_delay_ms/1000))>1e-9
            issues(end+1)="Acquisition duration does not match the pulse schedule.";
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
