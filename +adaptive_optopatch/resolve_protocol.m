function resolved=resolve_protocol(definition,fovState,targets,guiDefaults,options)
%RESOLVE_PROTOCOL Resolve schema-3 intent into concrete acquisition schedules.
arguments
    definition (1,1) struct
    fovState (1,1) struct
    targets (1,1) struct
    guiDefaults (1,1) struct
    options.Mode (1,1) string {mustBeMember(options.Mode,["1p_dmd","2p_spiral"])} = "1p_dmd"
end
report=adaptive_optopatch.validate_protocol(definition);
if ~report.passed
    error("adaptive_optopatch:InvalidProtocol","%s",strjoin(report.issues,newline));
end
definition=report.protocol;
if string(definition.artifact_type)~="experiment_definition"
    error("adaptive_optopatch:ProtocolDefinitionRequired", ...
        "Plan resolution requires a schema-3 experiment_definition.");
end

[cellIndices,targetIndices]=selected_targets(fovState,targets);
if isempty(cellIndices)
    error("adaptive_optopatch:NoAcceptedTargets", ...
        "No stimulation-enabled targets are executable for %s.",options.Mode);
end
resolved=cell(0,1); outputIndex=0;
for acquisitionIndex=1:numel(definition.acquisitions)
    acquisition=definition.acquisitions(acquisitionIndex);
    if definition.target_policy=="each_stimulation_enabled_cell"
        for selectedIndex=1:numel(cellIndices)
            outputIndex=outputIndex+1;
            resolved{outputIndex,1}=resolve_acquisition(definition,acquisition, ...
                fovState,guiDefaults,cellIndices(selectedIndex), ...
                targetIndices(selectedIndex),acquisitionIndex,outputIndex);
        end
    else
        outputIndex=outputIndex+1;
        resolved{outputIndex,1}=resolve_multi_target(definition,acquisition, ...
            fovState,guiDefaults,cellIndices,targetIndices, ...
            acquisitionIndex,outputIndex);
    end
end
if options.Mode=="1p_dmd"
    validate_blue_mask_executability(resolved,targets);
end
end

function validate_blue_mask_executability(resolved,targets)
% Every distinct non-null (target, resolved blue_mask_adjustment_pixels)
% combination must produce a nonempty physical mask via the same
% canonical primitive used at DMD execution time. This is evaluated after
% event resolution so an event-level override (which may differ from the
% bundle/GUI default) is authoritative rather than the bundle's default
% mask.
seen=strings(0,1);
for i=1:numel(resolved)
    events=resolved{i}.events;
    for k=reshape(find(~events.is_null),1,[])
        targetIndex=double(events.target_index(k));
        adjustment=double(events.blue_mask_adjustment_pixels(k));
        key=string(targetIndex)+"_"+string(adjustment);
        if any(seen==key), continue; end
        seen(end+1,1)=key; %#ok<AGROW>
        adaptive_optopatch.apply_blue_mask_adjustment( ...
            targets.canonical_roi_masks(:,:,targetIndex),adjustment,"Context", ...
            sprintf("cell %s, pulse %s, requested adjustment %d", ...
            events.target_cell_id(k),string(events.pulse_id(k)),adjustment));
    end
end
end

function protocol=resolve_acquisition(definition,acquisition,fovState,gui, ...
        cellIndex,targetIndex,acquisitionIndex,outputIndex)
events=acquisition.events;
n=height(events);
if definition.event_order=="randomized" && ~acquisition.event_order_realized
    stream=RandStream("mt19937ar","Seed",definition.random_seed+acquisitionIndex-1);
    events=events(randperm(stream,n),:);
    events.pulse_id=(1:n)';
end
events.target_cell_id=repmat(string(fovState.cells(cellIndex).cell_id),n,1);
events.target_index=repmat(targetIndex,n,1);
protocol=resolve_values(definition,acquisition,events,fovState,gui, ...
    repmat(cellIndex,n,1),acquisitionIndex,outputIndex);
end

function protocol=resolve_multi_target(definition,acquisition,fovState,gui, ...
        cellIndices,targetIndices,acquisitionIndex,outputIndex)
template=acquisition.events;
nTemplate=height(template); repetitions=acquisition.target_repetitions;
rows=cell(numel(cellIndices)*repetitions*nTemplate,1); cellMap=zeros(numel(rows),1);
cursor=0;
for repeat=1:repetitions
    for selected=1:numel(cellIndices)
        for eventIndex=1:nTemplate
            cursor=cursor+1;
            rows{cursor}=template(eventIndex,:);
            cellMap(cursor)=cellIndices(selected);
        end
    end
end
events=vertcat(rows{:});
targetMap=zeros(size(cellMap));
for k=1:numel(cellMap)
    selected=find(cellIndices==cellMap(k),1);
    targetMap(k)=targetIndices(selected);
end
if definition.event_order=="randomized" && ~acquisition.event_order_realized
    stream=RandStream("mt19937ar","Seed",definition.random_seed+acquisitionIndex-1);
    order=randperm(stream,height(events));
    events=events(order,:); cellMap=cellMap(order); targetMap=targetMap(order);
end
events.target_cell_id=string({fovState.cells(cellMap).cell_id})';
events.target_index=targetMap;
events.pulse_id=(1:height(events))';
protocol=resolve_values(definition,acquisition,events,fovState,gui, ...
    cellMap,acquisitionIndex,outputIndex);
end

function protocol=resolve_values(definition,acquisition,events,fovState,gui, ...
        cellMap,acquisitionIndex,outputIndex)
n=height(events); metadata=adaptive_optopatch.protocol_parameter_metadata();
eventSources=struct;
for name=["command_voltage_v","pulse_duration_s","blue_mask_adjustment_pixels"]
    meta=metadata(string({metadata.name})==name);
    column=string(meta.event_field);
    if name=="pulse_duration_s", raw=events.duration_s; else, raw=events.(column); end
    values=zeros(n,1); sources=strings(n,1);
    for k=1:n
        if events.is_null(k) && name=="command_voltage_v"
            values(k)=0; sources(k)="null"; continue
        end
        [values(k),sources(k)]=resolve_one(raw(k),name,definition, ...
            acquisition,fovState.cells(cellMap(k)),gui);
    end
    if name=="command_voltage_v" && ...
            ismember("command_voltage_scale",string(events.Properties.VariableNames))
        scale=double(events.command_voltage_scale);
        selected=isfinite(scale) & ~events.is_null;
        values(selected)=values(selected).*scale(selected);
        sources(selected)=sources(selected)+"*event_scale";
    end
    if name=="pulse_duration_s", events.duration_s=values;
    else, events.(column)=values; end
    eventSources.(name)=sources;
end
events.command_voltage_source=eventSources.command_voltage_v;
events.pulse_duration_source=eventSources.pulse_duration_s;
events.blue_mask_adjustment_source=eventSources.blue_mask_adjustment_pixels;
events.target_cell_id(events.is_null)="";
events.target_index(events.is_null)=0;
if any(~isfinite(events.onset_s))
    events=realize_timeline(events,acquisition, ...
        definition.random_seed+acquisitionIndex-1);
end

acquisitionCell=struct;
if all(cellMap==cellMap(1))
    acquisitionCell=fovState.cells(cellMap(1));
end
[orange,orangeSource]=resolve_one(NaN,"orange_expansion_pixels",definition, ...
    acquisition,acquisitionCell,gui);
[radius,radiusSource]=resolve_one(NaN,"spiral_radius_um",definition, ...
    acquisition,acquisitionCell,gui);
[density,densitySource]=resolve_one(NaN,"spiral_density_points_per_volt", ...
    definition,acquisition,acquisitionCell,gui);
parameters=struct("orange_expansion_pixels",orange, ...
    "spiral_radius_um",radius,"spiral_density_points_per_volt",density);
parameterSources=struct("orange_expansion_pixels",orangeSource, ...
    "spiral_radius_um",radiusSource,"spiral_density_points_per_volt",densitySource);
validate_resolved_values(events,parameters);

events.dmd_pattern_index=zeros(n,1);
nonnull=find(~events.is_null);
if ~isempty(nonnull)
    pairs=[events.target_index(nonnull) events.blue_mask_adjustment_pixels(nonnull)];
    [~,~,pattern]=unique(pairs,"rows","stable");
    events.dmd_pattern_index(nonnull)=pattern;
end

events.offset_s=events.onset_s+events.duration_s;
postDelay=field_number(acquisition,"post_delay_s",0);
duration=max(events.offset_s)+postDelay;
if isfield(acquisition,"acquisition_duration_s") && ...
        isfinite(double(acquisition.acquisition_duration_s))
    duration=double(acquisition.acquisition_duration_s);
end
protocol=struct("schema_version","3.0.0", ...
    "artifact_type","resolved_acquisition", ...
    "protocol_id",definition.protocol_id+compose("_acq_%04d",outputIndex), ...
    "protocol_type",definition.protocol_type, ...
    "source_protocol_id",definition.protocol_id, ...
    "acquisition_id",acquisition.acquisition_id, ...
    "definition_acquisition_index",acquisitionIndex, ...
    "target_policy",definition.target_policy,"event_order",definition.event_order, ...
    "event_order_realized",true,"random_seed",definition.random_seed,"events",events, ...
    "parameters",parameters,"parameter_sources",parameterSources, ...
    "acquisition_duration_s",duration, ...
    "resolved_at",string(datetime("now","TimeZone","local")));
protocol=adaptive_optopatch.normalize_protocol(protocol);
validation=adaptive_optopatch.validate_protocol(protocol);
if ~validation.passed
    error("adaptive_optopatch:ProtocolResolutionFailed", ...
        "%s",strjoin(validation.issues,newline));
end
end

function validate_resolved_values(events,parameters)
nonNull=~events.is_null;
voltage=events.command_voltage_v(nonNull);
if any(~isfinite(voltage) | voltage<=0 | voltage>5)
    error("adaptive_optopatch:InvalidCommandVoltage", ...
        "Resolved command voltage must lie in (0,5] V for every non-null event.");
end
adjustment=events.blue_mask_adjustment_pixels;
if any(~isfinite(adjustment) | fix(adjustment)~=adjustment)
    error("adaptive_optopatch:InvalidBlueMaskAdjustment", ...
        "Resolved Blue DMD-mask adjustment must be a finite integer pixel count.");
end
if ~isfinite(parameters.orange_expansion_pixels) || ...
        parameters.orange_expansion_pixels<0 || ...
        fix(parameters.orange_expansion_pixels)~=parameters.orange_expansion_pixels
    error("adaptive_optopatch:InvalidOrangeExpansion", ...
        "Resolved Orange DMD-mask expansion must be a nonnegative integer pixel count.");
end
if ~isfinite(parameters.spiral_radius_um) || parameters.spiral_radius_um<=0
    error("adaptive_optopatch:InvalidSpiralRadius", ...
        "Resolved 2P spiral radius must be positive and finite.");
end
if ~isfinite(parameters.spiral_density_points_per_volt) || ...
        parameters.spiral_density_points_per_volt<=0
    error("adaptive_optopatch:InvalidSpiralDensity", ...
        "Resolved 2P spiral density must be positive and finite.");
end
end

function [value,source]=resolve_one(eventValue,name,definition,acquisition,cellRecord,gui)
allowed=allowed_sources(definition,name);
if isfinite_scalar(eventValue) && ismember("event",allowed)
    value=double(eventValue); source="event"; return
end
if isfield(acquisition.parameters,name) && ...
        isfinite_scalar(acquisition.parameters.(name)) && ismember("acquisition",allowed)
    value=double(acquisition.parameters.(name)); source="acquisition"; return
end
if isfield(definition.parameters,name) && ...
        isfinite_scalar(definition.parameters.(name)) && ismember("protocol",allowed)
    value=double(definition.parameters.(name)); source="protocol"; return
end
meta=adaptive_optopatch.protocol_parameter_metadata();
meta=meta(string({meta.name})==name);
fovName=string(meta.fov_cell_field);
if ~isempty(fieldnames(cellRecord)) && isfield(cellRecord,fovName) && ...
        isfinite_scalar(cellRecord.(fovName)) && ismember("fov_cell",allowed)
    value=double(cellRecord.(fovName)); source="fov_cell"; return
end
guiName=string(meta.gui_field);
if isfield(gui,guiName) && isfinite_scalar(gui.(guiName)) && ismember("gui",allowed)
    value=double(gui.(guiName)); source="gui"; return
end
error("adaptive_optopatch:UnresolvedProtocolParameter", ...
    "Required parameter %s remains unresolved after event, acquisition, FOV-cell, and GUI resolution.",name);
end

function allowed=allowed_sources(definition,name)
allowed=["event","acquisition","protocol","fov_cell","gui"];
if isfield(definition,"parameter_sources") && ...
        isfield(definition.parameter_sources,name)
    allowed=string(definition.parameter_sources.(name));
end
end

function events=realize_timeline(events,acquisition,seed)
if ~isfield(acquisition,"sequence")
    error("adaptive_optopatch:UnresolvedEventTimes", ...
        "Unrealized event onsets require an explicit acquisition.sequence definition.");
end
sequence=acquisition.sequence;
required=["pre_delay_s","dark_interval_range_s"];
if ~all(isfield(sequence,cellstr(required)))
    error("adaptive_optopatch:InvalidSequenceDefinition", ...
        "sequence requires pre_delay_s and dark_interval_range_s.");
end
range=double(sequence.dark_interval_range_s);
if numel(range)~=2 || any(~isfinite(range)) || range(1)<0 || range(2)<range(1)
    error("adaptive_optopatch:InvalidSequenceDefinition", ...
        "dark_interval_range_s must be [minimum maximum].");
end
stream=RandStream("mt19937ar","Seed",seed);
gaps=range(1)+diff(range)*rand(stream,max(0,height(events)-1),1);
onsets=zeros(height(events),1); onsets(1)=double(sequence.pre_delay_s);
for k=2:height(events)
    previousDuration=events.duration_s(k-1);
    if ~isfinite(previousDuration)
        error("adaptive_optopatch:UnresolvedProtocolParameter", ...
            "Pulse duration must resolve before timeline realization.");
    end
    onsets(k)=onsets(k-1)+previousDuration+gaps(k-1);
end
events.onset_s=onsets;
events.realized_dark_interval_s=[gaps;NaN];
end

function [cellIndices,targetIndices]=selected_targets(fovState,targets)
% Stim selection is authoritative for both 1P and 2P: a stimulation-
% enabled cell with matching target geometry always participates in
% resolution. Advisory QC (spiral_qc_pass, edge_flag, parking QC) never
% determines acquisition count; true physical impossibility is detected
% explicitly downstream (validate_blue_mask_executability for 1P; the
% appropriate resolved/preflight/hardware validation for 2P) so a
% requested target either participates or fails explicitly, never
% silently disappears.
cells=fovState.cells; targetIds=string({targets.targets.cell_id});
cellIndices=zeros(0,1); targetIndices=zeros(0,1);
for k=1:numel(cells)
    if ~logical(cells(k).stimulation_enabled), continue; end
    cellId=string(cells(k).cell_id);
    matches=find(targetIds==cellId);
    if isempty(matches)
        error("adaptive_optopatch:MissingTargetGeometry", ...
            "Stimulation-enabled cell %s has no matching target geometry " + ...
            "in the target bundle.",cellId);
    elseif numel(matches)>1
        error("adaptive_optopatch:AmbiguousTargetGeometry", ...
            "Stimulation-enabled cell %s matches %d target entries; " + ...
            "its target geometry cannot be unambiguously resolved.", ...
            cellId,numel(matches));
    end
    cellIndices(end+1,1)=k; %#ok<AGROW>
    targetIndices(end+1,1)=matches; %#ok<AGROW>
end
end

function value=isfinite_scalar(value)
value=isnumeric(value) && isscalar(value) && isfinite(double(value));
end

function value=field_number(record,name,fallback)
value=fallback;
if isfield(record,name) && isfinite_scalar(record.(name)), value=double(record.(name)); end
end
