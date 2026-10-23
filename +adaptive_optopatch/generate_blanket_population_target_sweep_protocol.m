function protocol=generate_blanket_population_target_sweep_protocol(levelsV,options)
%GENERATE_BLANKET_POPULATION_TARGET_SWEEP_PROTOCOL Step the target level under a fixed blanket.
%
%   protocol=GENERATE_BLANKET_POPULATION_TARGET_SWEEP_PROTOCOL(levelsV,...)
%   returns a field-of-view-independent schema-4 definition that holds the
%   blanket at BlanketMod488V and delivers RepetitionsPerLevel brief target
%   epochs at each level of LEVELSV, in order.
%
%   WHAT IT DELIVERS, cycle by cycle, exactly as the blanket round robin:
%
%     target epoch:  0.2 ms Stim-enabled union at the blanket level
%                    0.8 ms union-of-all-selected-cells mask at this level,
%                           the first target_onset_guard_s of it at 0 V
%     between:       0.2 ms Stim-enabled union at the blanket level
%                    0.8 ms blank mask at 0 V
%
%   The target is the UNION of the selected cells' own stimulation masks, so
%   the rest of the field of view keeps receiving only the blanket phase. It
%   is never the full-FOV mask at the target level. The guard is the one in
%   BLANKET_DEPOLARIZATION_SPEC, not a second value.
%
%   SHORT EPOCHS, REPEATED. Each level is sampled by several brief epochs
%   rather than one long exposure, so reliability can be read off repeated
%   attempts instead of one.
%
%   WHAT IT IS NOT. Stimulating every inhibitory cell at once recruits the
%   network's own inhibition, which the isolated-cell round robin does not.
%   This is a fast way to find a useful target-voltage RANGE under blanket
%   depolarization. It is not a substitute for per-cell calibration, and a
%   threshold measured here may differ from the one a single cell shows.
%
%   See also BLANKET_DEPOLARIZATION_SPEC,
%   GENERATE_BLANKET_RECRUITMENT_SWEEP_PROTOCOL,
%   GENERATE_BLANKET_ROUND_ROBIN_PROTOCOL.
arguments
    levelsV (:,1) double
    options.BlanketMod488V (1,1) double = NaN
    options.RepetitionsPerLevel (1,1) double {mustBePositive,mustBeInteger} = 8
    options.EpochDurationS (1,1) double {mustBePositive} = 0.020
    options.InterEpochGapS (1,1) double {mustBePositive} = 0.080
    options.CyclePeriodS (1,1) double {mustBePositive} = 0.001
    options.BlanketFraction (1,1) double = 0.20
    options.TargetOnsetGuardS (1,1) double {mustBeNonnegative} = 50e-6
    options.PreDelayS (1,1) double {mustBeNonnegative} = 0.100
    options.PostDelayS (1,1) double {mustBeNonnegative} = 0.100
    options.ProtocolId (1,1) string = "blanket_population_target_sweep"
end
scheduler=struct("type","blanket_population_target_sweep", ...
    "levels_v",levelsV, ...
    "repetitions_per_level",options.RepetitionsPerLevel, ...
    "epoch_duration_s",options.EpochDurationS, ...
    "inter_epoch_gap_s",options.InterEpochGapS, ...
    "pre_delay_s",options.PreDelayS, ...
    "chunk_index",1,"chunk_count",1);
acquisition=struct("acquisition_id","blanket_population_target_sweep", ...
    "events",template_event("blanket_population_target_sweep", ...
        options.EpochDurationS), ...
    "parameters",struct, ...
    "event_order_realized",true,"target_repetitions",1, ...
    "post_delay_s",options.PostDelayS,"scheduler",scheduler);
blanket=struct("enabled",true, ...
    "mod488_v",options.BlanketMod488V, ...
    "cycle_period_s",options.CyclePeriodS, ...
    "blanket_fraction",options.BlanketFraction, ...
    "target_onset_guard_s",options.TargetOnsetGuardS, ...
    "schedule","population_target_sweep");
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","experiment_definition", ...
    "protocol_id",options.ProtocolId, ...
    "protocol_type","blanket_population_target_sweep", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "target_policy","multi_target_continuous", ...
    "event_order","ordered","random_seed",0, ...
    "parameter_sources",struct("command_voltage_v",["event","acquisition"]), ...
    "parameters",struct, ...
    "blanket_depolarization",blanket, ...
    "acquisitions",acquisition);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function events=template_event(conditionId,epochDurationS)
% The event tier of parameter resolution, not an epoch. Its command voltage
% stays NaN: a population epoch's voltage is the sweep's level, and the
% per-cell Blue calibration is deliberately not a source for it - the target
% is a union of cells, not one of them.
pulse_id=1;
condition_id=string(conditionId);
stimulation_source="1p_dmd";
onset_s=NaN;
duration_s=epochDurationS;
is_null=false;
command_voltage_v=NaN;
blue_mask_adjustment_pixels=NaN;
events=table(pulse_id,condition_id,stimulation_source,onset_s,duration_s, ...
    is_null,command_voltage_v,blue_mask_adjustment_pixels);
end
