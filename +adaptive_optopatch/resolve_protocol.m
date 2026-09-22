function resolved=resolve_protocol(definition,fovState,targets,guiDefaults,options)
%RESOLVE_PROTOCOL Resolve schema-4 per-event intent into acquisitions.
arguments
    definition (1,1) struct
    fovState (1,1) struct
    targets (1,1) struct
    guiDefaults (1,1) struct
    options.Mode (1,1) string {mustBeMember(options.Mode,["1p_dmd","2p_spiral"])} = "1p_dmd" % deprecated
    options.FreshRandomization (1,1) logical = false
end
report=adaptive_optopatch.validate_protocol(definition);
if ~report.passed
    error("adaptive_optopatch:InvalidProtocol","%s",strjoin(report.issues,newline));
end
definition=report.protocol;
if string(definition.artifact_type)~="experiment_definition"
    error("adaptive_optopatch:ProtocolDefinitionRequired", ...
        "Plan resolution requires a schema-4 experiment_definition.");
end

[cellIndices,targetIndices]=selected_targets(fovState,targets);
if isempty(cellIndices)
    error("adaptive_optopatch:NoAcceptedTargets", ...
        "No stimulation-enabled targets are executable for this protocol.");
end
resolved=cell(0,1); outputIndex=0;
for acquisitionIndex=1:numel(definition.acquisitions)
    acquisition=definition.acquisitions(acquisitionIndex);
    scheduler=adaptive_optopatch.acquisition_scheduler_spec(acquisition);
    if ~isempty(scheduler)
        % THE SCHEDULE IS BUILT HERE, against the cells that are actually
        % Stim-enabled, and nowhere else. The definition says how; this is
        % the first moment anything knows who. What comes out is an
        % ordinary resolved acquisition with literal target IDs and finite
        % onsets, which is what gets frozen into the plan and what the
        % runner executes literally - the scheduler is never reached again.
        if definition.target_policy=="each_stimulation_enabled_cell"
            error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
                "A scheduler-backed acquisition schedules ACROSS the " + ...
                "selected cells, so it cannot belong to an " + ...
                "each_stimulation_enabled_cell protocol, which makes one " + ...
                "acquisition per cell. Use multi_target_continuous.");
        end
        outputIndex=outputIndex+1;
        resolved{outputIndex,1}=resolve_scheduled_acquisition(definition, ...
            acquisition,scheduler,fovState,guiDefaults,cellIndices, ...
            targetIndices,acquisitionIndex,outputIndex);
        continue
    end
    if definition.target_policy=="each_stimulation_enabled_cell"
        for selectedIndex=1:numel(cellIndices)
            outputIndex=outputIndex+1;
            resolved{outputIndex,1}=resolve_acquisition(definition,acquisition, ...
                fovState,guiDefaults,cellIndices(selectedIndex), ...
                targetIndices(selectedIndex),acquisitionIndex,outputIndex, ...
                options.FreshRandomization);
        end
    else
        outputIndex=outputIndex+1;
        resolved{outputIndex,1}=resolve_multi_target(definition,acquisition, ...
            fovState,guiDefaults,cellIndices,targetIndices, ...
            acquisitionIndex,outputIndex,options.FreshRandomization);
    end
end
validate_blue_mask_executability(resolved,targets);
validate_mixed_constraints(resolved);
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
    for k=reshape(find(events.stimulation_source=="1p_dmd"),1,[])
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
        cellIndex,targetIndex,acquisitionIndex,outputIndex,freshRandomization)
events=acquisition.events;
n=height(events);
if definition.event_order=="randomized" && ~acquisition.event_order_realized
    order=randomized_order(n,definition.random_seed+acquisitionIndex-1, ...
        freshRandomization);
    events=events(order,:);
    events.pulse_id=(1:n)';
end
events.target_cell_id=repmat(string(fovState.cells(cellIndex).cell_id),n,1);
events.target_index=repmat(targetIndex,n,1);
protocol=resolve_values(definition,acquisition,events,fovState,gui, ...
    repmat(cellIndex,n,1),acquisitionIndex,outputIndex);
end

function protocol=resolve_scheduled_acquisition(definition,acquisition, ...
        scheduler,fovState,gui,cellIndices,targetIndices,acquisitionIndex, ...
        outputIndex)
%RESOLVE_SCHEDULED_ACQUISITION Realize one scheduler-backed chunk.
%   The definition named no cell. The selected cells are known now, so the
%   schedule is built now - once - and the literal event table it produces
%   is what is frozen, archived and executed.
%
%   TARGET ORDER IS THE FOV'S OWN. selected_targets walks fovState.cells in
%   order, so selectedIds is the canonical AO cell order and not the order
%   anything happened to be clicked in. That is what makes "same definition,
%   same selection, same schedule" true.
selectedIds=string({fovState.cells(cellIndices).cell_id})';
targetCount=numel(selectedIds);

% FLUT CAPACITY, AGAINST THE REAL TARGET COUNT.
%
% The generator used to check this when the protocol was written, from the
% cell IDs it was handed. An FOV-independent definition has none, and the
% count that matters is how many cells the experimenter actually selected -
% which is known here and nowhere earlier. Checked at Update plan so a
% field of view too large for the requested chunk is refused while there is
% still something to do about it, rather than at Run.
eventCount=targetCount*scheduler.pulses_per_cell;
capacity=adaptive_optopatch.calculate_dmd_flut_playlist_capacity( ...
    scheduler.flut_max_entries,targetCount);
if eventCount>capacity
    error("adaptive_optopatch:ConnectivityChunkExceedsFlutCapacity", ...
        "Acquisition %s schedules %d events for the %d selected cells " + ...
        "(%d pulses per cell), but the executable DMD FLUT playlist " + ...
        "capacity for %d targets is %d events.\n" + ...
        "Reduce pulses_per_cell_per_chunk to at most %d, or select " + ...
        "fewer cells, and regenerate the protocol.", ...
        string(acquisition.acquisition_id),eventCount,targetCount, ...
        scheduler.pulses_per_cell,targetCount,capacity, ...
        max(1,floor(capacity/max(targetCount,1))));
end

% THE TEMPLATE EVENT IS THE EVENT TIER, not a pulse. Its command voltage
% and mask adjustment are broadcast onto every realized pulse, so an
% event-level override in the definition still outranks the acquisition,
% the protocol and the per-cell calibration exactly as it does everywhere
% else - and NaN, the normal case, still falls through to the cell's own
% selected_blue_voltage_v.
template=acquisition.events(1,:);
[events,metadata]=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
    selectedIds,scheduler.pulses_per_cell,scheduler.pulse_duration_s, ...
    scheduler.preferred_global_spacing_s, ...
    scheduler.minimum_same_cell_post_pulse_gap_s, ...
    double(template.command_voltage_v), ...
    "PreDelayS",scheduler.pre_delay_s, ...
    "ConditionId",string(template.condition_id), ...
    "RandomSeed",scheduler.random_seed);
events.blue_mask_adjustment_pixels(:)= ...
    double(template.blue_mask_adjustment_pixels);

% Each realized target back to the FOV cell record and target geometry it
% names, so the ordinary resolver supplies per-cell voltage and mask.
positions=zeros(height(events),1);
for k=1:numel(selectedIds)
    positions(events.target_cell_id==selectedIds(k))=k;
end
cellMap=cellIndices(positions);
events.target_index=targetIndices(positions);

metadata.scheduler_type=scheduler.type;
metadata.chunk_index=scheduler.chunk_index;
metadata.chunk_count=scheduler.chunk_count;
metadata.selected_target_ids=selectedIds;
metadata.realized_at_resolution=true;
metadata.flut=struct("event_count",eventCount, ...
    "unique_mask_upper_bound",targetCount, ...
    "playlist_capacity",capacity, ...
    "max_entries",scheduler.flut_max_entries,"valid",true);
acquisition.scheduler_metadata=metadata;

protocol=resolve_values(definition,acquisition,events,fovState,gui, ...
    cellMap,acquisitionIndex,outputIndex);
end

function protocol=resolve_multi_target(definition,acquisition,fovState,gui, ...
        cellIndices,targetIndices,acquisitionIndex,outputIndex,freshRandomization)
template=acquisition.events;
if ismember("target_cell_id",string(template.Properties.VariableNames))
    if ~acquisition.event_order_realized
        error("adaptive_optopatch:UnrealizedExplicitTargetSchedule", ...
            "An explicit target_cell_id schedule must already have realized order and timing.");
    end
    if acquisition.target_repetitions~=1 || any(~isfinite(template.onset_s))
        error("adaptive_optopatch:UnrealizedExplicitTargetSchedule", ...
            "Explicit multi-target schedules require target_repetitions=1 and finite event onsets.");
    end
    selectedIds=string({fovState.cells(cellIndices).cell_id})';
    eventIds=string(template.target_cell_id);
    cellMap=zeros(height(template),1); targetMap=zeros(height(template),1);
    for k=1:height(template)
        if template.is_null(k), continue; end
        selected=find(selectedIds==eventIds(k),1);
        if isempty(selected)
            error("adaptive_optopatch:ScheduledTargetUnavailable", ...
                "Resolved protocol target %s is not stimulation-enabled in this FOV.",eventIds(k));
        end
        cellMap(k)=cellIndices(selected); targetMap(k)=targetIndices(selected);
    end
    if any(template.is_null)
        fallback=find(~template.is_null,1);
        if isempty(fallback)
            error("adaptive_optopatch:ScheduledTargetUnavailable", ...
                "An all-null explicit multi-target schedule has no target context.");
        end
        cellMap(template.is_null)=cellMap(fallback);
    end
    events=template;
    events.target_index=targetMap;
    protocol=resolve_values(definition,acquisition,events,fovState,gui, ...
        cellMap,acquisitionIndex,outputIndex);
    return
end
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
    order=randomized_order(height(events), ...
        definition.random_seed+acquisitionIndex-1,freshRandomization);
    events=events(order,:); cellMap=cellMap(order); targetMap=targetMap(order);
end
events.target_cell_id=string({fovState.cells(cellMap).cell_id})';
events.target_index=targetMap;
events.pulse_id=(1:height(events))';
protocol=resolve_values(definition,acquisition,events,fovState,gui, ...
    cellMap,acquisitionIndex,outputIndex);
end

function order=randomized_order(count,seed,freshRandomization)
if freshRandomization
    order=randperm(count);
else
    stream=RandStream("mt19937ar","Seed",seed);
    order=randperm(stream,count);
end
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
            acquisition,fovState.cells(cellMap(k)),gui,events.stimulation_source(k));
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
    acquisition,acquisitionCell,gui,"none");
if any(events.stimulation_source=="2p_spiral")
    [radius,radiusSource]=resolve_one(NaN,"spiral_radius_um",definition, ...
        acquisition,acquisitionCell,gui,"2p_spiral");
    [density,densitySource]=resolve_one(NaN,"spiral_density_points_per_volt", ...
        definition,acquisition,acquisitionCell,gui,"2p_spiral");
else
    radius=NaN; density=NaN; radiusSource="not_required"; densitySource="not_required";
end
parameters=struct("orange_expansion_pixels",orange, ...
    "spiral_radius_um",radius,"spiral_density_points_per_volt",density);
parameterSources=struct("orange_expansion_pixels",orangeSource, ...
    "spiral_radius_um",radiusSource,"spiral_density_points_per_volt",densitySource);
validate_resolved_values(events,parameters);

events.dmd_pattern_index=zeros(n,1);
nonnull=find(events.stimulation_source=="1p_dmd");
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
protocol=struct("schema_version","4.0.0", ...
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
if isfield(acquisition,"scheduler_metadata")
    protocol.scheduler_metadata=acquisition.scheduler_metadata;
end
if isfield(acquisition,"dmd_diagnostic")
    protocol.dmd_diagnostic=acquisition.dmd_diagnostic;
end
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
adjustment=events.blue_mask_adjustment_pixels(events.stimulation_source=="1p_dmd");
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
hasTwoPhoton=any(events.stimulation_source=="2p_spiral");
if hasTwoPhoton && (~isfinite(parameters.spiral_radius_um) || parameters.spiral_radius_um<=0)
    error("adaptive_optopatch:InvalidSpiralRadius", ...
        "Resolved 2P spiral radius must be positive and finite.");
end
if hasTwoPhoton && (~isfinite(parameters.spiral_density_points_per_volt) || ...
        parameters.spiral_density_points_per_volt<=0)
    error("adaptive_optopatch:InvalidSpiralDensity", ...
        "Resolved 2P spiral density must be positive and finite.");
end
end

function validate_mixed_constraints(resolved)
for acquisitionIndex=1:numel(resolved)
    events=resolved{acquisitionIndex}.events;
    twoPhoton=events.stimulation_source=="2p_spiral";
    targets=unique(events.target_cell_id(twoPhoton),"stable");
    targets=targets(strlength(targets)>0);
    if numel(targets)>1
        error("adaptive_optopatch:MultipleTwoPhotonTargetsUnsupported", ...
            "Pass 3B temporarily supports at most one distinct 2P " + ...
            "target_cell_id per acquisition; acquisition %s contains: %s.", ...
            resolved{acquisitionIndex}.acquisition_id,strjoin(targets,", "));
    end
    onePhoton=find(events.stimulation_source=="1p_dmd");
    twoPhoton=find(twoPhoton);
    for i=reshape(onePhoton,1,[])
        overlap=twoPhoton(events.onset_s(twoPhoton)<events.offset_s(i)-1e-12 & ...
            events.offset_s(twoPhoton)>events.onset_s(i)+1e-12);
        if ~isempty(overlap)
            error("adaptive_optopatch:OverlappingStimulationSources", ...
                "1P pulse %s overlaps 2P pulse %s. Pass 3B supports " + ...
                "interleaved sources but not simultaneous 1P + 2P stimulation.", ...
                string(events.pulse_id(i)),string(events.pulse_id(overlap(1))));
        end
    end
end
end

function [value,source]=resolve_one(eventValue,name,definition,acquisition,cellRecord,gui,stimulationSource)
allowed=allowed_sources(definition,name,stimulationSource);
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
if ismember("gui",allowed)
    guiName=string(meta.gui_field);
    if isfield(gui,guiName) && isfinite_scalar(gui.(guiName))
        value=double(gui.(guiName)); source="gui"; return
    end
end
if stimulationSource=="2p_spiral" && name=="command_voltage_v"
    error("adaptive_optopatch:MissingTwoPhotonPockelsVoltage", ...
        ['This 2P protocol does not define its Pockels stimulation voltage. ' ...
         'A 2p_spiral acquisition takes its command only from the protocol ' ...
         'artifact: set command_voltage_v on the events, on the acquisition ' ...
         'parameters, or on the protocol parameters. There is deliberately ' ...
         'no GUI default and no per-cell Blue-calibration ' ...
         '(selected_blue_voltage_v) fallback for the 2P Pockels command.']);
end
if name=="command_voltage_v"
    % NAMES THE CELL. This is reached once per event, and the event knows
    % which cell it is for - so an experimenter with twelve selected cells
    % and one uncalibrated does not have to find it by elimination. A
    % connectivity protocol leaves command_voltage_v NaN on purpose, which
    % makes "this cell has no Blue calibration" the single most likely way
    % for Update plan to fail.
    error("adaptive_optopatch:UnresolvedProtocolParameter", ...
        ['%s has no Blue voltage, so this 1P pulse cannot be resolved. ' ...
        'Set a Blue V for it in the cell table and press Update plan, or ' ...
        'give the protocol an explicit command_voltage_v on the event, ' ...
        'the acquisition or the protocol. The GUI has no voltage fallback ' ...
        'and no other cell''s calibration is borrowed.'], ...
        cell_label(cellRecord));
end
error("adaptive_optopatch:UnresolvedProtocolParameter", ...
    "Required parameter %s remains unresolved after event, acquisition, FOV-cell, and GUI resolution.",name);
end

function allowed=allowed_sources(definition,name,stimulationSource)
allowed=["event","acquisition","protocol","fov_cell","gui"];
if isfield(definition,"parameter_sources") && ...
        isfield(definition.parameter_sources,name)
    allowed=string(definition.parameter_sources.(name));
end
if name=="command_voltage_v"
    % Stimulation amplitude is experiment intent, never an editable GUI
    % default. A 1P cell calibration remains an explicit FOV-owned source.
    allowed=setdiff(allowed,"gui","stable");
end
if stimulationSource=="2p_spiral" && name=="command_voltage_v"
    % The Pockels command is owned by the 2P protocol artifact. The
    % fov_cell tier for this parameter is selected_blue_voltage_v, a 488 nm
    % calibration that must never become a Chameleon command, and a GUI
    % default must never silently supply a missing 2P voltage. Narrowing
    % here rather than in each generator makes the rule unconditional: a
    % protocol cannot widen it back with its own parameter_sources.
    allowed=intersect(allowed,["event","acquisition","protocol"],"stable");
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

function label=cell_label(cellRecord)
%CELL_LABEL How to refer to a cell in an operator-facing error.
label="This cell";
if isempty(fieldnames(cellRecord)) || ~isfield(cellRecord,"cell_id")
    return
end
identifier=string(cellRecord.cell_id);
if isscalar(identifier) && strlength(identifier)>0
    label="Cell "+identifier;
end
end

function value=isfinite_scalar(value)
value=isnumeric(value) && isscalar(value) && isfinite(double(value));
end

function value=field_number(record,name,fallback)
value=fallback;
if isfield(record,name) && isfinite_scalar(record.(name)), value=double(record.(name)); end
end
