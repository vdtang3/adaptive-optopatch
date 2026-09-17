function summary=summarize_protocol(value)
%SUMMARIZE_PROTOCOL Return compact schema-4 protocol information.
report=adaptive_optopatch.validate_protocol(value);
if ~report.passed
    error("adaptive_optopatch:InvalidProtocol","%s",strjoin(report.issues,newline));
end
protocol=report.protocol;
if protocol.artifact_type=="resolved_acquisition"
    acquisitions=struct("events",protocol.events);
else
    acquisitions=protocol.acquisitions;
end
eventCount=0; lightCount=0; onePhotonCount=0; twoPhotonCount=0;
conditions=strings(0,1); durations=[];
for k=1:numel(acquisitions)
    events=acquisitions(k).events; eventCount=eventCount+height(events);
    lightCount=lightCount+sum(~events.is_null);
    onePhotonCount=onePhotonCount+sum(events.stimulation_source=="1p_dmd");
    twoPhotonCount=twoPhotonCount+sum(events.stimulation_source=="2p_spiral");
    conditions=[conditions;events.condition_id]; %#ok<AGROW>
    durations=[durations;events.duration_s(isfinite(events.duration_s))]; %#ok<AGROW>
end
if isempty(durations), durationRange=[NaN NaN];
else, durationRange=[min(durations) max(durations)]; end
summary=struct("schema_version","4.0.0", ...
    "protocol_type",string(protocol.protocol_type), ...
    "protocol_id",string(protocol.protocol_id), ...
    "target_policy",string(protocol.target_policy), ...
    "event_order",string(protocol.event_order), ...
    "definition_acquisition_count",numel(acquisitions), ...
    "event_count",eventCount,"light_event_count",lightCount, ...
    "onephoton_event_count",onePhotonCount, ...
    "twophoton_event_count",twoPhotonCount, ...
    "condition_count",numel(unique(conditions)), ...
    "duration_range_s",durationRange,"random_seed",protocol.random_seed);
end
