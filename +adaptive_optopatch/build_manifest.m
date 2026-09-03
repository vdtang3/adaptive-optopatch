function manifest=build_manifest(reference,targets,protocol,options)
%BUILD_MANIFEST Combine a spatial plan with an existing pulse protocol.
arguments
    reference (1,1) struct
    targets (1,1) struct
    protocol (1,1) struct
    options.Mode (1,1) string {mustBeMember(options.Mode,["1p_dmd","2p_spiral"])} = "2p_spiral"
    options.RandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 1
    options.OutputPrefix (1,1) string = "adaptive_optopatch"
end
compatibility=adaptive_optopatch.validate_protocol_for_mode(protocol,options.Mode);
if ~compatibility.passed
    error("adaptive_optopatch:ProtocolModeIncompatible", ...
        "%s",strjoin(compatibility.issues,newline));
end
protocol=compatibility.protocol;
accepted=[reference.cells.accepted] & [targets.targets.qc_pass];
targetIndices=find(accepted);
if isempty(targetIndices)
    error("adaptive_optopatch:NoAcceptedTargets","No accepted targets passed QC.");
end
rng(options.RandomSeed,"twister");
targetIndices=targetIndices(randperm(numel(targetIndices)));
rows=table;
for k=1:numel(targetIndices)
    targetIndex=targetIndices(k);
    target=targets.targets(targetIndex);
    trialId=k; repeatIndex=1; mode=options.Mode;
    targetCellId=string(target.cell_id); isNull=false;
    patternIndex=target.dmd_mask_index;
    radiusUm=target.spiral_radius_um;
    density=target.spiral_density_points_per_volt;
    protocolId=string(protocol.protocol_id);
    pulseSchedule={protocol};
    duration=double(protocol.acquisition_duration_s);
    outputTag=options.OutputPrefix+compose("_trial_%04d",k);
    row=table(trialId,repeatIndex,mode,targetCellId,isNull,targetIndex, ...
        patternIndex,radiusUm,density,protocolId,pulseSchedule,duration, ...
        outputTag,"planned","","", ...
        'VariableNames',["trial_id","repeat_index","stimulation_mode", ...
        "target_cell_id","is_null","target_index","dmd_pattern_index", ...
        "spiral_radius_um","spiral_density_points_per_volt", ...
        "pulse_protocol_id","pulse_schedule","acquisition_duration_s", ...
        "output_tag","acquisition_status","experiment_directory","analysis_status"]);
    rows=[rows;row]; %#ok<AGROW>
end
manifest=struct("schema_version","0.2.0","fov_id",reference.fov_id, ...
    "random_seed",options.RandomSeed,"one_acquisition_per_row",true, ...
    "protocol_id",string(protocol.protocol_id), ...
    "protocol_schema_version",string(protocol.schema_version),"trials",rows);
end
