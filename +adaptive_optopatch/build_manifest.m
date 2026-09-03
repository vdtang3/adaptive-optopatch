function manifest=build_manifest(reference,targets,protocol,options)
%BUILD_MANIFEST Resolve target templates into acquisition-level rows.
arguments
    reference (1,1) struct
    targets (1,1) struct
    protocol (1,1) struct
    options.Mode (1,1) string {mustBeMember(options.Mode,["1p_dmd","2p_spiral"])} = "2p_spiral"
    options.RandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 1
    options.OutputPrefix (1,1) string = "adaptive_optopatch"
end
report=adaptive_optopatch.validate_protocol_for_mode(protocol,options.Mode);
if ~report.passed
    error("adaptive_optopatch:ProtocolModeIncompatible","%s",strjoin(report.issues,newline));
end
protocol=report.protocol;
cellIds=string({reference.cells.cell_id})';
targetIds=string({targets.targets.cell_id})';
eligible=false(numel(targetIds),1);
for k=1:numel(targetIds)
    referenceIndex=find(cellIds==targetIds(k),1);
    if isempty(referenceIndex)
        error("adaptive_optopatch:TargetReferenceMismatch", ...
            "Target bundle cell %s is absent from the reference model.",targetIds(k));
    end
    if options.Mode=="1p_dmd" && isfield(targets.targets,"blue_qc_pass")
        spatialQc=targets.targets(k).blue_qc_pass;
    elseif options.Mode=="2p_spiral" && isfield(targets.targets,"spiral_qc_pass")
        spatialQc=targets.targets(k).spiral_qc_pass;
    else
        spatialQc=targets.targets(k).qc_pass;
    end
    eligible(k)=spatialQc && ...
        cell_flag(reference.cells(referenceIndex),"stimulation_enabled",true);
end
eligibleIndices=find(eligible);
if isempty(eligibleIndices)
    error("adaptive_optopatch:NoAcceptedTargets","No stimulation-enabled targets passed QC.");
end

nonNull=~protocol.events.is_null;
resolved=strlength(protocol.events.target_cell_id(nonNull))>0;
if any(resolved) && ~all(resolved)
    error("adaptive_optopatch:PartiallyResolvedTargets", ...
        "A protocol cannot mix resolved and unresolved non-null target IDs.");
end
if all(resolved) && any(nonNull)
    resolvedProtocols={resolve_pattern_indices(protocol,targets,targetIds,eligible)};
else
    rng(options.RandomSeed,"twister");
    order=eligibleIndices(randperm(numel(eligibleIndices)));
    resolvedProtocols=cell(numel(order),1);
    for k=1:numel(order)
        value=protocol;
        value.events.target_cell_id(nonNull)=targetIds(order(k));
        resolvedProtocols{k}=resolve_pattern_indices(value,targets,targetIds,eligible);
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
    "random_seed",options.RandomSeed,"one_acquisition_per_row",true, ...
    "acquisition_scope",ternary(numel(resolvedProtocols)==1 && ...
        numel(unique(resolvedProtocols{1}.events.target_cell_id(~resolvedProtocols{1}.events.is_null)))>1, ...
        "multi_target_continuous","single_target"), ...
    "protocol_id",string(protocol.protocol_id), ...
    "protocol_schema_version","2.0.0","trials",rows);
end

function protocol=resolve_pattern_indices(protocol,targets,targetIds,eligible)
events=protocol.events; pattern=zeros(height(events),1);
for k=1:height(events)
    if events.is_null(k), continue; end
    index=find(targetIds==events.target_cell_id(k),1);
    if isempty(index)
        error("adaptive_optopatch:UnknownTargetCell", ...
            "Protocol pulse %s targets unknown cell %s.", ...
            string(events.pulse_id(k)),events.target_cell_id(k));
    end
    if ~eligible(index)
        error("adaptive_optopatch:StimulationDisabledCell", ...
            "Protocol pulse %s targets stimulation-disabled or QC-failed cell %s.", ...
            string(events.pulse_id(k)),events.target_cell_id(k));
    end
    if string(protocol.protocol_type)=="calibrated_round_robin"
        target=targets.targets(index);
        calibrated=isfield(target,"calibration_status") && ...
            string(target.calibration_status)=="good" && ...
            isfield(target,"selected_blue_voltage_v") && ...
            isfinite(target.selected_blue_voltage_v) && target.selected_blue_voltage_v>0;
        matchesCalibration=calibrated && isfinite(events.command_voltage_v(k)) && ...
            abs(events.command_voltage_v(k)-target.selected_blue_voltage_v)<1e-12;
        if ~matchesCalibration
            error("adaptive_optopatch:MissingOrMismatchedCalibration", ...
                "Round-robin pulse %s requires the current good calibration "+ ...
                "for %s and must use its selected Blue voltage.", ...
                string(events.pulse_id(k)),events.target_cell_id(k));
        end
    end
    pattern(k)=index;
end
events.dmd_pattern_index=pattern;
protocol.events=events;
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function value=cell_flag(record,name,default)
if isfield(record,name), value=logical(record.(name)); else, value=default; end
end

function value=ternary(condition,yes,no)
if condition, value=yes; else, value=no; end
end
