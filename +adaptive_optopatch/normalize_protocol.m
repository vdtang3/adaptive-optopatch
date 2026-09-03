function protocol=normalize_protocol(protocol)
%NORMALIZE_PROTOCOL Normalize a pulse-level schedule to schema 2.0.0.
arguments
    protocol (1,1) struct
end
if ~isfield(protocol,"events") || ~istable(protocol.events)
    error("adaptive_optopatch:InvalidProtocol", ...
        "Protocol events must be stored in a table.");
end
events=protocol.events;
names=string(events.Properties.VariableNames);
if ismember("pulse_times_s",names)
    error("adaptive_optopatch:ObsoleteTrainRepresentation", ...
        "pulse_times_s is no longer supported. Store one physical light "+ ...
        "pulse per protocol.events row.");
end
n=height(events);
if ~ismember("onset_s",names)
    if ismember("event_onset_s",names), events.onset_s=double(events.event_onset_s);
    else, error("adaptive_optopatch:InvalidProtocol","Protocol events have no onset_s column."); end
end
if ~ismember("duration_s",names)
    if ismember("offset_s",names)
        events.duration_s=double(events.offset_s)-double(events.onset_s);
    else
        error("adaptive_optopatch:InvalidProtocol", ...
            "Protocol events have no duration_s or offset_s column.");
    end
end
if ~ismember("pulse_id",names)
    if ismember("pulse_index",names), events.pulse_id=events.pulse_index;
    else, events.pulse_id=(1:n)'; end
end
if ~ismember("condition_id",names), events.condition_id=repmat("default",n,1); end
events.condition_id=string(events.condition_id);
if ~ismember("target_cell_id",names), events.target_cell_id=repmat("",n,1); end
events.target_cell_id=string(events.target_cell_id);
if ~ismember("is_null",names), events.is_null=false(n,1); end
events.is_null=logical(events.is_null);
if ~ismember("command_voltage_v",names)
    if ismember("modulator_voltage",names)
        events.command_voltage_v=double(events.modulator_voltage);
    else
        events.command_voltage_v=nan(n,1);
    end
end
if ~ismember("amplitude_fraction",names)
    events.amplitude_fraction=nan(n,1);
    events.amplitude_fraction(~isfinite(events.command_voltage_v))=1;
end
events.command_voltage_v=double(events.command_voltage_v);
events.amplitude_fraction=double(events.amplitude_fraction);
events.command_voltage_v(events.is_null)=0;
events.amplitude_fraction(events.is_null)=0;
events.onset_s=double(events.onset_s);
events.duration_s=double(events.duration_s);
events.offset_s=events.onset_s+events.duration_s;
events=sortrows(events,"onset_s");
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
    protocol.acquisition_duration_s=max(events.offset_s,[],"omitmissing");
end
canonical=["pulse_id","condition_id","onset_s","duration_s", ...
    "target_cell_id","is_null","command_voltage_v","amplitude_fraction","offset_s"];
protocol.events=movevars(events,canonical,"Before",1);
protocol.schema_version="2.0.0";
protocol.normalized_at=string(datetime("now","TimeZone","local"));
end
