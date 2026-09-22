function summary=summarize_protocol(value)
%SUMMARIZE_PROTOCOL Return compact schema-4 protocol information.
report=adaptive_optopatch.validate_protocol(value);
if ~report.passed
    error("adaptive_optopatch:InvalidProtocol","%s",strjoin(report.issues,newline));
end
protocol=report.protocol;
isDefinition=string(protocol.artifact_type)=="experiment_definition";
if isDefinition
    acquisitions=protocol.acquisitions;
else
    acquisitions=struct("events",protocol.events);
end
% SCHEDULER-BACKED ACQUISITIONS ARE COUNTED BY THEIR DESIGN, not by their
% rows. Such an acquisition carries ONE untargeted template event and
% realizes its real pulses against the selected cells at Update plan, so
% adding its height to event_count would report a ten-thousand-pulse
% connectivity screen as containing ten events - and, before this, as
% containing one. The honest answer before resolution is "so many pulses
% per selected cell", because how many cells there will be is exactly what
% the definition does not know.
eventCount=0; lightCount=0; onePhotonCount=0; twoPhotonCount=0;
conditions=strings(0,1); durations=[];
scheduledCount=0; pulsesPerCell=0; schedulerTypes=strings(0,1);
for k=1:numel(acquisitions)
    events=acquisitions(k).events;
    % Only a DEFINITION can still be unrealized. A resolved acquisition
    % has its literal events and is counted as what it is.
    scheduler=struct([]);
    if isDefinition
        scheduler=adaptive_optopatch.acquisition_scheduler_spec(acquisitions(k));
    end
    if ~isempty(scheduler)
        scheduledCount=scheduledCount+1;
        pulsesPerCell=pulsesPerCell+scheduler.pulses_per_cell;
        schedulerTypes(end+1,1)=scheduler.type; %#ok<AGROW>
        conditions=[conditions;events.condition_id]; %#ok<AGROW>
        durations=[durations;events.duration_s(isfinite(events.duration_s))]; %#ok<AGROW>
        continue
    end
    eventCount=eventCount+height(events);
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
    "duration_range_s",durationRange,"random_seed",protocol.random_seed, ...
    ... % How much of this protocol has targets that are not known yet.
    ... % scheduled_acquisition_count > 0 means event_count describes only
    ... % the explicitly scheduled part, and the rest is
    ... % pulses_per_selected_cell pulses for each cell selected at Update
    ... % plan. A view says so rather than showing a pulse count that is
    ... % not the experiment.
    "scheduled_acquisition_count",scheduledCount, ...
    "pulses_per_selected_cell",pulsesPerCell, ...
    "scheduler_types",unique(schedulerTypes,"stable"), ...
    "targets_resolved_at_update_plan",scheduledCount>0);
end
