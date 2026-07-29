function manifest = build_stf_manifest(acceptedPairs, targets, conditions, options)
%BUILD_STF_MANIFEST Plan one randomized mixed-condition acquisition per source.
arguments
    acceptedPairs table
    targets (1,1) struct
    conditions table = adaptive_optopatch.default_stf_conditions()
    options.Mode (1,1) string {mustBeMember(options.Mode,["2p_spiral","1p_dmd"])} = "2p_spiral"
    options.EventDarkIntervalMs (1,2) double {mustBePositive} = [450 550]
    options.PreDelayMs (1,1) double {mustBeNonnegative} = 100
    options.PostDelayMs (1,1) double {mustBeNonnegative} = 100
    options.RandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 1001
    options.OutputPrefix (1,1) string = "stf"
end
required=["source_index","source_cell_id","observed_cell_id"];
if ~all(ismember(required,string(acceptedPairs.Properties.VariableNames)))
    error("adaptive_optopatch:InvalidAcceptedPairs", ...
        "Accepted-pairs table is missing source/observed columns.");
end
if ismember("accepted",string(acceptedPairs.Properties.VariableNames))
    acceptedPairs=acceptedPairs(acceptedPairs.accepted,:);
end
if isempty(acceptedPairs)
    error("adaptive_optopatch:NoAcceptedPairs","No directed pairs were accepted.");
end
[sourceIndices,firstRows]=unique(acceptedPairs.source_index,"stable");
n=numel(sourceIndices);
trial_id=(1:n)'; target_index=sourceIndices(:);
target_cell_id=string(acceptedPairs.source_cell_id(firstRows));
observed_cell_ids=cell(n,1); pulse_schedule=cell(n,1);
acquisition_duration_s=zeros(n,1);
for k=1:n
    rows=acceptedPairs.source_index==sourceIndices(k);
    observed_cell_ids{k}=unique(string(acceptedPairs.observed_cell_id(rows)),"stable");
    pulse_schedule{k}=adaptive_optopatch.generate_stf_protocol(conditions, ...
        "EventDarkIntervalMs",options.EventDarkIntervalMs, ...
        "PreDelayMs",options.PreDelayMs,"PostDelayMs",options.PostDelayMs, ...
        "RandomSeed",options.RandomSeed+k);
    acquisition_duration_s(k)=pulse_schedule{k}.acquisition_duration_s;
end
stimulation_mode=repmat(options.Mode,n,1);
is_null=false(n,1);
dmd_pattern_index=zeros(n,1); spiral_radius_um=nan(n,1);
spiral_density_points_per_volt=nan(n,1);
for k=1:n
    t=targets.targets(target_index(k));
    dmd_pattern_index(k)=t.dmd_mask_index;
    spiral_radius_um(k)=t.spiral_radius_um;
    spiral_density_points_per_volt(k)=t.spiral_density_points_per_volt;
end
output_tag=options.OutputPrefix+compose("_source_%03d",target_index);
acquisition_status=repmat("planned",n,1);
experiment_directory=repmat("",n,1); analysis_status=repmat("",n,1);
trials=table(trial_id,stimulation_mode,target_cell_id,observed_cell_ids, ...
    is_null,target_index,dmd_pattern_index,spiral_radius_um, ...
    spiral_density_points_per_volt,pulse_schedule,acquisition_duration_s, ...
    output_tag,acquisition_status,experiment_directory,analysis_status);
manifest=struct("schema_version","0.2.0","manifest_type","stf", ...
    "random_seed",options.RandomSeed,"one_acquisition_per_source",true, ...
    "conditions",conditions,"trials",trials);
end
