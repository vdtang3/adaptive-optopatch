function protocol=normalize_protocol(protocol)
%NORMALIZE_PROTOCOL Convert supported legacy schedules to schema 1.0.0.
arguments
    protocol (1,1) struct
end
if ~isfield(protocol,"events") || ~istable(protocol.events)
    error("adaptive_optopatch:InvalidProtocol", ...
        "Protocol events must be stored in a table.");
end
events=protocol.events;
names=string(events.Properties.VariableNames);
n=height(events);
if ~ismember("onset_s",names)
    if ismember("event_onset_s",names), events.onset_s=double(events.event_onset_s);
    else, error("adaptive_optopatch:InvalidProtocol","Protocol events have no onset_s column."); end
end
if ~ismember("duration_s",names)
    if ismember("offset_s",names)
        events.duration_s=double(events.offset_s)-double(events.onset_s);
    elseif ismember("event_offset_s",names)
        events.duration_s=double(events.event_offset_s)-double(events.onset_s);
    else
        error("adaptive_optopatch:InvalidProtocol", ...
            "Protocol events have no duration_s or offset column.");
    end
end
if ~ismember("event_id",names)
    if ismember("pulse_index",names)
        events.event_id=double(events.pulse_index);
    elseif ismember("event_index",names)
        events.event_id=double(events.event_index);
    else
        events.event_id=(1:n)';
    end
end
if ~ismember("condition_id",names)
    events.condition_id=repmat("default",n,1);
else
    events.condition_id=string(events.condition_id);
end
if ~ismember("amplitude_fraction",names)
    if ismember("modulator_voltage",names)
        legacy=double(events.modulator_voltage);
        maximum=max(legacy(isfinite(legacy) & legacy>0),[],"omitmissing");
        if isempty(maximum), maximum=0; end
        if maximum>0, fraction=legacy/maximum;
        else, fraction=ones(n,1); end
        if ismember("is_null",names), fraction(logical(events.is_null))=0; end
        events.amplitude_fraction=fraction;
        protocol.legacy_voltage_scale_v=maximum;
    else
        events.amplitude_fraction=ones(n,1);
        if ismember("is_null",names)
            events.amplitude_fraction(logical(events.is_null))=0;
        end
    end
end
if ~ismember("is_null",string(events.Properties.VariableNames))
    events.is_null=events.amplitude_fraction==0;
end
if ~ismember("offset_s",string(events.Properties.VariableNames))
    events.offset_s=events.onset_s+events.duration_s;
end
if ~isfield(protocol,"protocol_type") || strlength(string(protocol.protocol_type))==0
    protocol.protocol_type="custom";
end
if ~isfield(protocol,"protocol_id") || strlength(string(protocol.protocol_id))==0
    protocol.protocol_id=string(protocol.protocol_type)+"_normalized";
end
if ~isfield(protocol,"created_at")
    protocol.created_at=string(datetime("now","TimeZone","local"));
end
if ~isfield(protocol,"random_seed"), protocol.random_seed=NaN; end
if ~isfield(protocol,"acquisition_duration_s")
    protocol.acquisition_duration_s=max(events.onset_s+events.duration_s);
end
protocol.events=movevars(events, ...
    ["event_id","condition_id","onset_s","duration_s","amplitude_fraction"], ...
    "Before",1);
protocol.schema_version="1.0.0";
if ~isfield(protocol,"normalized_at")
    protocol.normalized_at=string(datetime("now","TimeZone","local"));
end
end
