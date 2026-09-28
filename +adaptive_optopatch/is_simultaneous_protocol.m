function result=is_simultaneous_protocol(protocol)
%IS_SIMULTANEOUS_PROTOCOL Explicit acquisition-level group targeting.
result=isfield(protocol,"target_policy") && ...
    string(protocol.target_policy)=="simultaneous_stimulation_enabled_cells";
end
