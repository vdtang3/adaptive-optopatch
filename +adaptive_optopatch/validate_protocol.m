function report=validate_protocol(value)
%VALIDATE_PROTOCOL Validate the canonical one-row-per-pulse schema.
arguments
    value (1,1) struct
end
issues=strings(0,1);
try
    protocol=adaptive_optopatch.normalize_protocol(value);
catch exception
    report=struct("schema_version","2.0.0","passed",false, ...
        "issues",string(exception.message),"protocol",struct([]));
    return
end
events=protocol.events;
required=["pulse_id","condition_id","onset_s","duration_s", ...
    "target_cell_id","is_null","command_voltage_v","amplitude_fraction"];
if ~all(ismember(required,string(events.Properties.VariableNames)))
    issues(end+1)="Canonical pulse columns are missing.";
else
    onset=double(events.onset_s); duration=double(events.duration_s);
    command=double(events.command_voltage_v); fraction=double(events.amplitude_fraction);
    isNull=logical(events.is_null);
    if isempty(events), issues(end+1)="Protocol contains no pulses."; end
    if any(~isfinite(onset) | onset<0), issues(end+1)="Pulse onsets must be finite and nonnegative."; end
    if any(~isfinite(duration) | duration<=0), issues(end+1)="Pulse durations must be finite and positive."; end
    if any(isfinite(command) & command<0)
        issues(end+1)="Explicit command voltages must be nonnegative.";
    end
    if any(isfinite(fraction) & (fraction<0 | fraction>1))
        issues(end+1)="Amplitude fractions must lie between zero and one.";
    end
    unresolved=~isNull & ~isfinite(command) & ~isfinite(fraction);
    if any(unresolved), issues(end+1)="Every non-null pulse needs a command voltage or amplitude fraction."; end
    if any(isNull & ((isfinite(command) & command~=0) | (isfinite(fraction) & fraction~=0)))
        issues(end+1)="Null pulses must have zero stimulation amplitude.";
    end
    if numel(unique(string(events.pulse_id)))~=height(events)
        issues(end+1)="Pulse IDs must be unique.";
    end
    if any(strlength(strip(string(events.condition_id)))==0)
        issues(end+1)="Condition IDs must be nonempty.";
    end
    [sortedOnset,index]=sort(onset); sortedEnd=sortedOnset+duration(index);
    if numel(sortedOnset)>1 && any(sortedOnset(2:end)<sortedEnd(1:end-1)-1e-12)
        issues(end+1)="Protocol pulses overlap in time.";
    end
    finalTime=max(onset+duration,[],"omitmissing");
    if ~isscalar(protocol.acquisition_duration_s) || ...
            ~isfinite(protocol.acquisition_duration_s) || ...
            protocol.acquisition_duration_s<finalTime-1e-12
        issues(end+1)="Acquisition duration ends before the final pulse.";
    end
    names=string(events.Properties.VariableNames);
    for name=["train_id","pulse_in_train","repeat_index"]
        if ismember(name,names)
            values=double(events.(name)); present=isfinite(values);
            if any(values(present)<1 | fix(values(present))~=values(present))
                issues(end+1)=name+" values must be positive integers."; %#ok<AGROW>
            end
        end
    end
end
report=struct("schema_version","2.0.0","passed",isempty(issues), ...
    "issues",issues,"protocol",protocol);
end
