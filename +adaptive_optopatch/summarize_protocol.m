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
% WHAT KIND OF STIMULATION THIS IS, said plainly, because "dithered" and
% "not dithered" are the two things an operator most needs to tell apart
% and protocol_type alone does not say it. A blanket protocol alternates
% the DMD every millisecond under a duty-cycled background; everything else
% holds a static mask while mod488 shapes the intensity.
blanket=adaptive_optopatch.blanket_depolarization_spec(protocol);
summary.blanket_dithered=blanket.enabled;
summary.stimulation_style=ternary(blanket.enabled, ...
    "blanket-dithered","standard (static mask)");
summary.display_name=display_name(protocol);
summary.command_amplitudes=command_amplitudes(acquisitions);
% HOW MANY CELLS ONE ACQUISITION DRIVES, and through what pattern. A
% simultaneous protocol lights the union of every Stim-enabled cell's mask
% at once and holds it; a per-cell one runs the protocol again for each
% cell through that cell's own mask; a multi-target one steps between them
% within an acquisition. Those are different experiments and the policy
% name alone does not say which.
[summary.targeting,summary.pattern_style]=targeting_text(protocol);
end

function [targeting,pattern]=targeting_text(protocol)
switch string(protocol.target_policy)
    case "simultaneous_stimulation_enabled_cells"
        targeting="all stim-enabled cells simultaneously";
        pattern="static union mask";
    case "each_stimulation_enabled_cell"
        targeting="each stim-enabled cell in turn";
        pattern="static per-cell mask";
    case "multi_target_continuous"
        targeting="scheduled across the stim-enabled cells";
        pattern="stepped per-cell masks";
    otherwise
        targeting=string(protocol.target_policy);
        pattern="";
end
end

function value=display_name(protocol)
%DISPLAY_NAME The protocol type as a person would say it.
%   Only for types whose identifier does not already read as English. An
%   unlisted type falls back to its own name rather than to a prettified
%   guess, which would be a second naming convention.
switch string(protocol.protocol_type)
    case "four_pulse_ramp",              value="4 pulses + ramp";
    case "blanket_round_robin",          value="Blanket round robin (dithered)";
    case "blanket_recruitment_sweep",    value="Blanket recruitment sweep (dithered)";
    case "blanket_population_target_sweep", value="Blanket population sweep (dithered)";
    case "whole_fov_blue_ramp",          value="Whole-FOV Blue ramp";
    case "single_cell_blue_ramp",        value="Single-cell Blue ramp";
    case "connectivity_screen",          value="Connectivity screen";
    otherwise,                           value=string(protocol.protocol_type);
end
end

function value=command_amplitudes(acquisitions)
%COMMAND_AMPLITUDES The distinct commanded levels, by waveform shape.
%   mod488 command volts, which is the one amplitude unit this package
%   has. NaN means the protocol defers to each cell's own Blue
%   calibration, and is reported as such rather than dropped.
value=struct("rectangular_v",[],"linear_ramp_end_v",[],"defers_to_cell",false);
for k=1:numel(acquisitions)
    events=acquisitions(k).events;
    if isempty(events), continue; end
    shapes=repmat("rectangular",height(events),1);
    if ismember("command_waveform",string(events.Properties.VariableNames))
        shapes=string(events.command_waveform);
    end
    levels=double(events.command_voltage_v);
    lit=~logical(events.is_null);
    value.defers_to_cell=value.defers_to_cell||any(isnan(levels(lit)));
    value.rectangular_v=[value.rectangular_v; ...
        levels(lit&shapes=="rectangular")];
    value.linear_ramp_end_v=[value.linear_ramp_end_v; ...
        levels(lit&shapes=="linear_ramp")];
end
value.rectangular_v=unique(value.rectangular_v(isfinite(value.rectangular_v)));
value.linear_ramp_end_v=unique( ...
    value.linear_ramp_end_v(isfinite(value.linear_ramp_end_v)));
end

function value=ternary(condition,whenTrue,whenFalse)
if condition, value=whenTrue; else, value=whenFalse; end
end
