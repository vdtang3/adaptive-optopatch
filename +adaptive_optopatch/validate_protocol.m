function report=validate_protocol(value)
%VALIDATE_PROTOCOL Validate the protocol-independent canonical event schema.
arguments
    value (1,1) struct
end
issues=strings(0,1);
try
    protocol=adaptive_optopatch.normalize_protocol(value);
catch exception
    report=struct("schema_version","1.0.0","passed",false, ...
        "issues",string(exception.message),"protocol",struct([]));
    return
end
events=protocol.events;
required=["event_id","condition_id","onset_s","duration_s","amplitude_fraction"];
if ~all(ismember(required,string(events.Properties.VariableNames)))
    issues(end+1)="Canonical event columns are missing.";
else
    onset=double(events.onset_s); duration=double(events.duration_s);
    amplitude=double(events.amplitude_fraction);
    if isempty(events), issues(end+1)="Protocol contains no events."; end
    if any(~isfinite(onset) | onset<0), issues(end+1)="Event onsets must be finite and nonnegative."; end
    if any(~isfinite(duration) | duration<=0), issues(end+1)="Event durations must be finite and positive."; end
    if any(~isfinite(amplitude) | amplitude<0), issues(end+1)="Amplitude fractions must be finite and nonnegative."; end
    ids=events.event_id;
    if numel(unique(string(ids)))~=height(events)
        issues(end+1)="Event IDs must be unique.";
    end
    if any(strlength(strip(string(events.condition_id)))==0)
        issues(end+1)="Condition IDs must be nonempty.";
    end
    [sortedOnset,index]=sort(onset);
    sortedEnd=sortedOnset+duration(index);
    if numel(sortedOnset)>1 && any(sortedOnset(2:end)<sortedEnd(1:end-1)-1e-12)
        issues(end+1)="Protocol events overlap in time.";
    end
    finalTime=max(onset+duration,[],"omitmissing");
    if ~isscalar(protocol.acquisition_duration_s) || ...
            ~isfinite(protocol.acquisition_duration_s) || ...
            protocol.acquisition_duration_s<finalTime-1e-12
        issues(end+1)="Acquisition duration ends before the final event.";
    end
    names=string(events.Properties.VariableNames);
    if all(ismember(["train_index","pulse_in_train"],names))
        train=double(events.train_index); pulse=double(events.pulse_in_train);
        if any(~isfinite(train) | train<1 | fix(train)~=train) || ...
                any(~isfinite(pulse) | pulse<1 | fix(pulse)~=pulse)
            issues(end+1)="Train indices and pulse positions must be positive integers.";
        end
    end
    if ismember("pulse_times_s",names)
        for k=1:height(events)
            times=double(events.pulse_times_s{k}(:));
            if isempty(times) || any(~isfinite(times)) || ...
                    any(diff(times)<=0) || times(1)<onset(k)-1e-12 || ...
                    times(end)>onset(k)+duration(k)+1e-12
                issues(end+1)= ... %#ok<AGROW>
                    "Train pulse times are inconsistent with their event window.";
                break
            end
        end
    end
end
report=struct("schema_version","1.0.0","passed",isempty(issues), ...
    "issues",issues,"protocol",protocol);
end
