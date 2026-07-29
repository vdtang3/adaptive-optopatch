function manifest = build_screen_manifest(reference, targets, options)
%BUILD_SCREEN_MANIFEST Plan one acquisition per neuron per repeat.
arguments
    reference (1,1) struct
    targets (1,1) struct
    options.Mode (1,1) string {mustBeMember(options.Mode,["2p_spiral","1p_dmd"])} = "2p_spiral"
    options.Repeats (1,1) double {mustBePositive,mustBeInteger} = 5
    options.NullFraction (1,1) double {mustBeGreaterThanOrEqual(options.NullFraction,0),mustBeLessThan(options.NullFraction,1)} = 0.1
    options.RandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 1
    options.PulseProtocolId (1,1) string = "screen_v1"
    options.OutputPrefix (1,1) string = "connectivity_screen"
    options.PulseCount (1,1) double {mustBePositive,mustBeInteger} = 200
    options.PulseDurationMs (1,1) double {mustBeGreaterThanOrEqual(options.PulseDurationMs,5),mustBeLessThanOrEqual(options.PulseDurationMs,10)} = 5
    options.DarkIntervalMs (1,2) double {mustBePositive} = [45 55]
    options.PreDelayMs (1,1) double {mustBeNonnegative} = 100
    options.PostDelayMs (1,1) double {mustBeNonnegative} = 100
    options.ModulatorVoltage (1,1) double {mustBeGreaterThanOrEqual(options.ModulatorVoltage,0),mustBeLessThanOrEqual(options.ModulatorVoltage,5)} = 0
end

accepted = [reference.cells.accepted] & [targets.targets.qc_pass];
cellIds = string({reference.cells(accepted).cell_id})';
if isempty(cellIds)
    error("adaptive_optopatch:NoAcceptedTargets", ...
        "No accepted targets passed QC.");
end

rng(options.RandomSeed, "twister");
rows = table;
trial = 0;
for repeatIndex = 1:options.Repeats
    blockTargets = cellIds(randperm(numel(cellIds)));
    nNull = round(numel(blockTargets)*options.NullFraction/(1-options.NullFraction));
    block = [blockTargets; repmat("NULL",nNull,1)];
    block = block(randperm(numel(block)));
    for b = 1:numel(block)
        trial = trial + 1;
        isNull = block(b) == "NULL";
        targetIndex = find(string({targets.targets.cell_id}) == block(b), 1);
        if isNull
            targetIndex = 0;
            patternIndex = 0;
            radiusUm = NaN;
            densityPointsPerVolt = NaN;
        else
            patternIndex = targets.targets(targetIndex).dmd_mask_index;
            radiusUm = targets.targets(targetIndex).spiral_radius_um;
            densityPointsPerVolt = targets.targets(targetIndex).spiral_density_points_per_volt;
        end
        trialVoltage=options.ModulatorVoltage;
        if isNull, trialVoltage=0; end
        pulseProtocol=adaptive_optopatch.generate_screen_protocol( ...
            "PulseCount",options.PulseCount, ...
            "PulseDurationMs",options.PulseDurationMs, ...
            "DarkIntervalMs",options.DarkIntervalMs, ...
            "PreDelayMs",options.PreDelayMs, ...
            "PostDelayMs",options.PostDelayMs, ...
            "ModulatorVoltage",trialVoltage, ...
            "RandomSeed",options.RandomSeed+trial);
        pulseSchedule={pulseProtocol};
        acquisitionDurationS=pulseProtocol.acquisition_duration_s;
        row = table(trial, repeatIndex, options.Mode, block(b), isNull, ...
            targetIndex, patternIndex, radiusUm, densityPointsPerVolt, options.PulseProtocolId, ...
            pulseSchedule,acquisitionDurationS, ...
            options.OutputPrefix + compose("_trial_%04d",trial), ...
            "planned", "", "", ...
            'VariableNames', ["trial_id","repeat_index","stimulation_mode", ...
            "target_cell_id","is_null","target_index","dmd_pattern_index", ...
            "spiral_radius_um","spiral_density_points_per_volt", ...
            "pulse_protocol_id","pulse_schedule","acquisition_duration_s","output_tag", ...
            "acquisition_status","experiment_directory","analysis_status"]);
        rows = [rows; row]; %#ok<AGROW>
    end
end

manifest = struct;
manifest.schema_version = "0.1.0";
manifest.fov_id = reference.fov_id;
manifest.random_seed = options.RandomSeed;
manifest.one_acquisition_per_row = true;
manifest.trials = rows;
end
