function pulses = flatten_pulse_schedule(protocol)
%FLATTEN_PULSE_SCHEDULE Convert screen or STF schedules to individual pulses.
arguments
    protocol (1,1) struct
end
if ~isfield(protocol,"events") || isempty(protocol.events)
    error("adaptive_optopatch:EmptyPulseSchedule", ...
        "The protocol contains no events.");
end

if isfield(protocol,"protocol_type") && ...
        string(protocol.protocol_type)=="stf_mixed_conditions"
    events=protocol.events;
    required=["condition_index","is_null","modulator_voltage","pulse_times_s"];
    if ~all(ismember(required,string(events.Properties.VariableNames))) || ...
            ~isfield(protocol,"conditions")
        error("adaptive_optopatch:InvalidStfProtocol", ...
            "The STF protocol is missing pulse timing or condition information.");
    end
    onset=[]; offset=[]; voltage=[]; eventIndex=[]; pulseInEvent=[]; isNull=[];
    for e=1:height(events)
        times=double(events.pulse_times_s{e}(:));
        conditionIndex=events.condition_index(e);
        duration=double(protocol.conditions.pulse_duration_ms(conditionIndex))/1000;
        values=repmat(double(events.modulator_voltage(e)),numel(times),1);
        if events.is_null(e), values(:)=0; end
        onset=[onset;times]; %#ok<AGROW>
        offset=[offset;times+duration]; %#ok<AGROW>
        voltage=[voltage;values]; %#ok<AGROW>
        eventIndex=[eventIndex;repmat(e,numel(times),1)]; %#ok<AGROW>
        pulseInEvent=[pulseInEvent;(1:numel(times))']; %#ok<AGROW>
        isNull=[isNull;repmat(logical(events.is_null(e)),numel(times),1)]; %#ok<AGROW>
    end
else
    events=protocol.events;
    required=["onset_s","offset_s","modulator_voltage"];
    if ~all(ismember(required,string(events.Properties.VariableNames)))
        error("adaptive_optopatch:InvalidScreenProtocol", ...
            "The screen protocol is missing onset, offset, or voltage columns.");
    end
    onset=double(events.onset_s(:));
    offset=double(events.offset_s(:));
    voltage=double(events.modulator_voltage(:));
    eventIndex=(1:height(events))';
    pulseInEvent=ones(height(events),1);
    isNull=false(height(events),1);
end

[onset,order]=sort(onset);
offset=offset(order); voltage=voltage(order);
eventIndex=eventIndex(order); pulseInEvent=pulseInEvent(order);
isNull=isNull(order);
if any(~isfinite(onset) | ~isfinite(offset) | ~isfinite(voltage)) || ...
        any(offset<=onset)
    error("adaptive_optopatch:InvalidPulseTimes", ...
        "All pulse times and commands must be finite and have positive duration.");
end
if numel(onset)>1 && any(onset(2:end)<offset(1:end-1))
    error("adaptive_optopatch:OverlappingPulses", ...
        "The flattened pulse schedule contains overlaps.");
end
if any(onset<0) || any(offset>double(protocol.acquisition_duration_s)+1e-9)
    error("adaptive_optopatch:PulseOutsideAcquisition", ...
        "A pulse lies outside the planned acquisition duration.");
end

pulse_index=(1:numel(onset))';
pulses=table(pulse_index,eventIndex,pulseInEvent,isNull,onset,offset, ...
    offset-onset,voltage, ...
    'VariableNames',{'pulse_index','event_index','pulse_in_event','is_null', ...
    'onset_s','offset_s','duration_s','modulator_voltage'});
end
