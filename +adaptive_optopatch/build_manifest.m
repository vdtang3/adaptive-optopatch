function [manifest,resolvedProtocols]=build_manifest(reference,targets,definition,options)
%BUILD_MANIFEST Resolve explicit protocol acquisitions into manifest rows.
arguments
    reference (1,1) struct
    targets (1,1) struct
    definition (1,1) struct
    options.Mode (1,1) string {mustBeMember(options.Mode,["1p_dmd","2p_spiral"])} = "2p_spiral"
    options.OutputPrefix (1,1) string = "adaptive_optopatch"
    options.CurrentObisPowerW (1,1) double = NaN
    options.FovState (1,1) struct = struct
    options.GuiDefaults (1,1) struct = struct
end
if isempty(fieldnames(options.FovState))
    error("adaptive_optopatch:FovStateRequired", ...
        "Schema-3 protocol resolution requires the current FOV state.");
end
compatibility=adaptive_optopatch.validate_protocol_for_mode(definition,options.Mode);
if ~compatibility.passed
    error("adaptive_optopatch:ProtocolModeIncompatible", ...
        "%s",strjoin(compatibility.issues,newline));
end
resolvedProtocols=adaptive_optopatch.resolve_protocol(definition, ...
    options.FovState,targets,options.GuiDefaults,"Mode",options.Mode);
n=numel(resolvedProtocols); rows=table;
for k=1:n
    protocol=resolvedProtocols{k}; events=protocol.events;
    used=unique(events.target_cell_id(~events.is_null),"stable");
    if isscalar(used)
        targetCellId=used; targetIndex=events.target_index(find(~events.is_null,1));
    else
        targetCellId="multiple"; targetIndex=NaN;
    end
    trialId=k; repeatIndex=1; mode=options.Mode; isNull=all(events.is_null);
    acquisitionId=string(protocol.acquisition_id);
    protocolId=string(protocol.protocol_id); pulseSchedule={protocol};
    duration=double(protocol.acquisition_duration_s);
    outputTag=options.OutputPrefix+compose("_trial_%04d",k);
    acquisitionParameters={protocol.parameters};
    parameterSources={protocol.parameter_sources};
    row=table(trialId,repeatIndex,mode,targetCellId,isNull,targetIndex, ...
        acquisitionId,protocolId,pulseSchedule,duration,outputTag, ...
        acquisitionParameters,parameterSources,"planned","","", ...
        'VariableNames',{'trial_id','repeat_index','stimulation_mode', ...
        'target_cell_id','is_null','target_index','acquisition_id', ...
        'pulse_protocol_id','pulse_schedule','acquisition_duration_s', ...
        'output_tag','acquisition_parameters','parameter_sources', ...
        'acquisition_status','experiment_directory','analysis_status'});
    rows=[rows;row]; %#ok<AGROW>
end
manifest=struct("schema_version","2.0.0","fov_id",reference.fov_id, ...
    "software",adaptive_optopatch.software_provenance(), ...
    "protocol_schema_version","3.0.0", ...
    "source_protocol_id",string(definition.protocol_id), ...
    "target_policy",string(definition.target_policy), ...
    "event_order",string(definition.event_order), ...
    "random_seed",double(definition.random_seed), ...
    "explicit_definition_acquisition_count",numel(definition.acquisitions), ...
    "resolved_acquisition_count",n,"one_acquisition_per_row",true, ...
    "acquisition_scope",string(definition.target_policy),"trials",rows);
advisories=struct("code",{},"message",{},"cell_id",{}, ...
    "previous_value",{},"current_value",{});
for k=1:n
    protocol=resolvedProtocols{k};
    if options.Mode=="1p_dmd"
        pulseIds=protocol.events.target_cell_id(~protocol.events.is_null);
        advisories=[advisories adaptive_optopatch.collect_blue_spatial_advisories( ...
            targets,pulseIds)]; %#ok<AGROW>
    end
    found=adaptive_optopatch.collect_calibration_advisories( ...
        reference,targets,protocol,"CurrentObisPowerW",options.CurrentObisPowerW);
    advisories=[advisories found]; %#ok<AGROW>
end
manifest.advisories=unique_advisories(advisories);
manifest.trials.advisories=repmat({manifest.advisories},height(rows),1);
end

function output=unique_advisories(values)
output=values;
if isempty(values), return; end
keys=strings(numel(values),1);
for k=1:numel(values)
    keys(k)=string(values(k).code)+"|"+string(values(k).cell_id)+"|"+ ...
        scalar_key(values(k).previous_value)+"|"+scalar_key(values(k).current_value);
end
[~,index]=unique(keys,"stable"); output=values(index);
end

function value=scalar_key(input)
if isnumeric(input) || islogical(input)
    value=string(mat2str(input));
else
    value=strjoin(string(input(:)),",");
end
end
