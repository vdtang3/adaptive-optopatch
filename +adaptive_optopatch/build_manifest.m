function manifest=build_manifest(reference,targets,protocol,options)
%BUILD_MANIFEST Resolve target templates into acquisition-level rows.
arguments
    reference (1,1) struct
    targets (1,1) struct
    protocol (1,1) struct
    options.Mode (1,1) string {mustBeMember(options.Mode,["1p_dmd","2p_spiral"])} = "2p_spiral"
    options.RandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 1
    options.OutputPrefix (1,1) string = "adaptive_optopatch"
    options.CurrentObisPowerW (1,1) double = NaN
end
report=adaptive_optopatch.validate_protocol_for_mode(protocol,options.Mode);
if ~report.passed
    error("adaptive_optopatch:ProtocolModeIncompatible","%s",strjoin(report.issues,newline));
end
protocol=report.protocol;
cellIds=string({reference.cells.cell_id})';
targetIds=string({targets.targets.cell_id})';
enabled=false(numel(targetIds),1);
executable=false(numel(targetIds),1);
for k=1:numel(targetIds)
    referenceIndex=find(cellIds==targetIds(k),1);
    if isempty(referenceIndex)
        error("adaptive_optopatch:TargetReferenceMismatch", ...
            "Target bundle cell %s is absent from the reference model.",targetIds(k));
    end
    if options.Mode=="1p_dmd"
        executable(k)=adaptive_optopatch.is_blue_target_executable(targets,k);
    elseif options.Mode=="2p_spiral" && isfield(targets.targets,"spiral_qc_pass")
        executable(k)=logical(targets.targets(k).spiral_qc_pass);
    else
        executable(k)=logical(targets.targets(k).qc_pass);
    end
    enabled(k)=cell_flag(reference.cells(referenceIndex),"stimulation_enabled",true);
end
eligible=executable & enabled;
eligibleIndices=find(eligible);

nonNull=~protocol.events.is_null;
resolved=strlength(protocol.events.target_cell_id(nonNull))>0;
if any(resolved) && ~all(resolved)
    error("adaptive_optopatch:PartiallyResolvedTargets", ...
        "A protocol cannot mix resolved and unresolved non-null target IDs.");
end
if all(resolved) && any(nonNull)
    resolvedProtocols={resolve_pattern_indices(protocol,targets,targetIds, ...
        enabled,executable,options.Mode)};
else
    if isempty(eligibleIndices)
        error("adaptive_optopatch:NoAcceptedTargets", ...
            "No stimulation-enabled targets are executable for %s.",options.Mode);
    end
    rng(options.RandomSeed,"twister");
    order=eligibleIndices(randperm(numel(eligibleIndices)));
    resolvedProtocols=cell(numel(order),1);
    for k=1:numel(order)
        value=protocol;
        value.events.target_cell_id(nonNull)=targetIds(order(k));
        resolvedProtocols{k}=resolve_pattern_indices(value,targets,targetIds, ...
            enabled,executable,options.Mode);
    end
end

rows=table;
for k=1:numel(resolvedProtocols)
    value=resolvedProtocols{k};
    uniqueTargets=unique(value.events.target_cell_id(~value.events.is_null),"stable");
    if options.Mode=="2p_spiral" && numel(uniqueTargets)~=1
        error("adaptive_optopatch:DynamicTwoPhotonTargetsUnsupported", ...
            "A 2P acquisition must resolve to exactly one target cell.");
    end
    if numel(uniqueTargets)==1
        targetCellId=uniqueTargets; targetIndex=find(targetIds==targetCellId,1);
        patternIndex=targetIndex;
    else
        targetCellId="multiple"; targetIndex=NaN; patternIndex=NaN;
    end
    trialId=k; repeatIndex=1; mode=options.Mode; isNull=all(value.events.is_null);
    protocolId=string(value.protocol_id); pulseSchedule={value};
    duration=double(value.acquisition_duration_s);
    outputTag=options.OutputPrefix+compose("_trial_%04d",k);
    row=table(trialId,repeatIndex,mode,targetCellId,isNull,targetIndex, ...
        patternIndex,protocolId,pulseSchedule,duration,outputTag,"planned","","", ...
        'VariableNames',{'trial_id','repeat_index','stimulation_mode', ...
        'target_cell_id','is_null','target_index','dmd_pattern_index', ...
        'pulse_protocol_id','pulse_schedule','acquisition_duration_s', ...
        'output_tag','acquisition_status','experiment_directory','analysis_status'});
    rows=[rows;row]; %#ok<AGROW>
end
manifest=struct("schema_version","1.0.0","fov_id",reference.fov_id, ...
    "software",adaptive_optopatch.software_provenance(), ...
    "random_seed",options.RandomSeed,"one_acquisition_per_row",true, ...
    "acquisition_scope",ternary(numel(resolvedProtocols)==1 && ...
        numel(unique(resolvedProtocols{1}.events.target_cell_id(~resolvedProtocols{1}.events.is_null)))>1, ...
        "multi_target_continuous","single_target"), ...
    "protocol_id",string(protocol.protocol_id), ...
    "protocol_schema_version","2.0.0","trials",rows);
advisories=struct("code",{},"message",{},"cell_id",{}, ...
    "previous_value",{},"current_value",{});
for k=1:numel(resolvedProtocols)
    if options.Mode=="1p_dmd"
        pulseIds=resolvedProtocols{k}.events.target_cell_id( ...
            ~resolvedProtocols{k}.events.is_null);
        advisories=[advisories adaptive_optopatch.collect_blue_spatial_advisories( ...
            targets,pulseIds)]; %#ok<AGROW>
    end
    found=adaptive_optopatch.collect_calibration_advisories( ...
        reference,targets,resolvedProtocols{k}, ...
        "CurrentObisPowerW",options.CurrentObisPowerW);
    advisories=[advisories found]; %#ok<AGROW>
end
manifest.advisories=unique_advisories(advisories);
manifest.trials.advisories=repmat({manifest.advisories},height(manifest.trials),1);
end

function protocol=resolve_pattern_indices(protocol,targets,targetIds,enabled,executable,mode)
events=protocol.events; pattern=zeros(height(events),1);
for k=1:height(events)
    if events.is_null(k), continue; end
    index=find(targetIds==events.target_cell_id(k),1);
    if isempty(index)
        error("adaptive_optopatch:UnknownTargetCell", ...
            "Protocol pulse %s targets unknown cell %s.", ...
            string(events.pulse_id(k)),events.target_cell_id(k));
    end
    if ~enabled(index)
        error("adaptive_optopatch:StimulationDisabledCell", ...
            "Protocol pulse %s targets stimulation-disabled cell %s.", ...
            string(events.pulse_id(k)),events.target_cell_id(k));
    end
    if ~executable(index)
        if mode=="1p_dmd"
            error("adaptive_optopatch:UnusableBlueTarget", ...
                "Protocol pulse %s targets cell %s, whose Blue mask is missing or empty.", ...
                string(events.pulse_id(k)),events.target_cell_id(k));
        end
        error("adaptive_optopatch:TargetQcFailed", ...
            "Protocol pulse %s targets cell %s, which did not pass %s execution QC.", ...
            string(events.pulse_id(k)),events.target_cell_id(k),mode);
    end
    if mode=="1p_dmd"
        voltage=double(events.command_voltage_v(k));
        if string(protocol.protocol_type)=="calibrated_round_robin" && ...
                (~isfinite(voltage) || voltage<=0)
            error("adaptive_optopatch:InvalidTargetVoltage", ...
                "Pulse %s for %s requires a positive finite command voltage.", ...
                string(events.pulse_id(k)),events.target_cell_id(k));
        end
        profile=adaptive_optopatch.virtual_upright_1p_profile();
        if isfinite(voltage) && ...
                (voltage<profile.modulator.minimum_v || voltage>profile.modulator.maximum_v)
            error("adaptive_optopatch:ModulatorVoltageOutOfRange", ...
                "Pulse %s command %.6g V is outside the %.6g-%.6g V hardware range.", ...
                string(events.pulse_id(k)),voltage,profile.modulator.minimum_v, ...
                profile.modulator.maximum_v);
        end
    end
    pattern(k)=index;
end
events.dmd_pattern_index=pattern;
protocol.events=events;
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function values=unique_advisories(values)
if isempty(values), return; end
keys=string({values.code})+"|"+string({values.cell_id})+"|"+string({values.message});
[~,index]=unique(keys,"stable");
values=values(index);
end

function value=cell_flag(record,name,default)
if isfield(record,name), value=logical(record.(name)); else, value=default; end
end

function value=ternary(condition,yes,no)
if condition, value=yes; else, value=no; end
end
