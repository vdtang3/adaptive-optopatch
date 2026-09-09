function protocol=normalize_protocol(protocol)
%NORMALIZE_PROTOCOL Normalize a schema-3 definition or resolved acquisition.
arguments
    protocol (1,1) struct
end
if ~isfield(protocol,"schema_version") || string(protocol.schema_version)~="3.0.0"
    error("adaptive_optopatch:ObsoleteProtocolSchema", ...
        "This artifact uses an obsolete Adaptive Optopatch protocol schema. "+ ...
        "Regenerate it with the current package.");
end
if ~isfield(protocol,"artifact_type")
    error("adaptive_optopatch:InvalidProtocol", ...
        "Schema 3 protocols require artifact_type.");
end
type=string(protocol.artifact_type);
if type=="experiment_definition"
    protocol=normalize_definition(protocol);
elseif type=="resolved_acquisition"
    protocol=normalize_resolved(protocol);
else
    error("adaptive_optopatch:InvalidProtocol", ...
        "artifact_type must be experiment_definition or resolved_acquisition.");
end
end

function protocol=normalize_definition(protocol)
required=["protocol_id","protocol_type","target_policy","event_order", ...
    "random_seed","acquisitions"];
require_fields(protocol,required,"Protocol definition");
protocol.protocol_id=string(protocol.protocol_id);
protocol.protocol_type=string(protocol.protocol_type);
protocol.target_policy=string(protocol.target_policy);
protocol.event_order=string(protocol.event_order);
if ~ismember(protocol.target_policy, ...
        ["each_stimulation_enabled_cell","multi_target_continuous"])
    error("adaptive_optopatch:InvalidTargetPolicy", ...
        "target_policy must be each_stimulation_enabled_cell or multi_target_continuous.");
end
if ~ismember(protocol.event_order,["ordered","randomized"])
    error("adaptive_optopatch:InvalidEventOrder", ...
        "event_order must be ordered or randomized.");
end
protocol.random_seed=double(protocol.random_seed);
if ~isscalar(protocol.random_seed) || ~isfinite(protocol.random_seed) || ...
        protocol.random_seed<0 || fix(protocol.random_seed)~=protocol.random_seed
    error("adaptive_optopatch:InvalidRandomSeed", ...
        "Schema 3 definitions require a nonnegative integer random_seed.");
end
if isempty(protocol.acquisitions) || ~isstruct(protocol.acquisitions)
    error("adaptive_optopatch:ExplicitAcquisitionsRequired", ...
        "Define at least one explicit protocol acquisition.");
end
if ~isfield(protocol,"parameters"), protocol.parameters=struct; end
if ~isstruct(protocol.parameters) || ~isscalar(protocol.parameters)
    error("adaptive_optopatch:InvalidProtocolParameters", ...
        "Protocol parameters must be one scalar struct.");
end
if ~isfield(protocol.acquisitions,"event_order_realized")
    [protocol.acquisitions.event_order_realized]=deal(true);
end
if ~isfield(protocol.acquisitions,"target_repetitions")
    [protocol.acquisitions.target_repetitions]=deal(1);
end
for k=1:numel(protocol.acquisitions)
    acquisition=protocol.acquisitions(k);
    require_fields(acquisition,["acquisition_id","events","parameters"], ...
        "Acquisition definition");
    if ~isstruct(acquisition.parameters) || ~isscalar(acquisition.parameters)
        error("adaptive_optopatch:InvalidProtocolParameters", ...
            "Acquisition %s parameters must be one scalar struct.", ...
            string(acquisition.acquisition_id));
    end
    acquisition.acquisition_id=string(acquisition.acquisition_id);
    if ~istable(acquisition.events)
        error("adaptive_optopatch:InvalidProtocol", ...
            "Acquisition %s events must be a table.",acquisition.acquisition_id);
    end
    acquisition.events=normalize_events(acquisition.events,false);
    acquisition.event_order_realized=logical(acquisition.event_order_realized);
    if ~isscalar(acquisition.event_order_realized)
        error("adaptive_optopatch:InvalidEventOrder", ...
            "event_order_realized must be scalar logical.");
    end
    acquisition.target_repetitions=double(acquisition.target_repetitions);
    if ~isscalar(acquisition.target_repetitions) || ...
            acquisition.target_repetitions<1 || ...
            fix(acquisition.target_repetitions)~=acquisition.target_repetitions
        error("adaptive_optopatch:InvalidTargetRepetitions", ...
            "target_repetitions must be a positive integer.");
    end
    if protocol.target_policy=="each_stimulation_enabled_cell" && ...
            acquisition.target_repetitions~=1
        error("adaptive_optopatch:InvalidTargetRepetitions", ...
            "each_stimulation_enabled_cell acquisitions use target_repetitions=1.");
    end
    protocol.acquisitions(k)=acquisition;
end
if ~isfield(protocol,"created_at")
    protocol.created_at=string(datetime("now","TimeZone","local"));
end
end

function protocol=normalize_resolved(protocol)
required=["protocol_id","protocol_type","source_protocol_id", ...
    "acquisition_id","target_policy","event_order","random_seed", ...
    "events","parameters","parameter_sources","acquisition_duration_s"];
require_fields(protocol,required,"Resolved acquisition");
protocol.events=normalize_events(protocol.events,true);
protocol.acquisition_duration_s=double(protocol.acquisition_duration_s);
if ~isscalar(protocol.acquisition_duration_s) || ...
        ~isfinite(protocol.acquisition_duration_s) || ...
        protocol.acquisition_duration_s<max(protocol.events.offset_s,[],"omitmissing")
    error("adaptive_optopatch:InvalidAcquisitionDuration", ...
        "Resolved acquisition duration must include every event.");
end
end

function events=normalize_events(events,resolved)
required=["pulse_id","condition_id","onset_s","duration_s","is_null", ...
    "command_voltage_v","blue_mask_adjustment_pixels"];
require_table_columns(events,required);
n=height(events);
events.pulse_id=double(events.pulse_id);
events.condition_id=string(events.condition_id);
events.onset_s=double(events.onset_s);
events.duration_s=double(events.duration_s);
events.is_null=logical(events.is_null);
events.command_voltage_v=double(events.command_voltage_v);
events.blue_mask_adjustment_pixels=double(events.blue_mask_adjustment_pixels);
if resolved
    resolvedRequired=["target_cell_id","target_index","dmd_pattern_index", ...
        "command_voltage_source","pulse_duration_source", ...
        "blue_mask_adjustment_source"];
    require_table_columns(events,resolvedRequired);
    events.target_cell_id=string(events.target_cell_id);
    events.target_index=double(events.target_index);
    events.dmd_pattern_index=double(events.dmd_pattern_index);
    events.command_voltage_source=string(events.command_voltage_source);
    events.pulse_duration_source=string(events.pulse_duration_source);
    events.blue_mask_adjustment_source=string(events.blue_mask_adjustment_source);
end
events.offset_s=events.onset_s+events.duration_s;
canonical=["pulse_id","condition_id","onset_s","duration_s","is_null", ...
    "command_voltage_v","blue_mask_adjustment_pixels","offset_s"];
if resolved
    canonical=[canonical(1:2) "target_cell_id" "target_index" ...
        canonical(3:end) "dmd_pattern_index" "command_voltage_source" ...
        "pulse_duration_source" "blue_mask_adjustment_source"];
end
events=movevars(events,canonical,"Before",1);
if height(events)~=n
    error("adaptive_optopatch:InvalidProtocol","Protocol normalization changed event count.");
end
end

function require_fields(value,names,context)
missing=names(~isfield(value,cellstr(names)));
if ~isempty(missing)
    error("adaptive_optopatch:InvalidProtocol", ...
        "%s is missing: %s.",context,strjoin(missing,", "));
end
end

function require_table_columns(value,names)
missing=names(~ismember(names,string(value.Properties.VariableNames)));
if ~isempty(missing)
    error("adaptive_optopatch:InvalidProtocol", ...
        "Protocol events are missing: %s.",strjoin(missing,", "));
end
end
