function protocol=generate_single_cell_ramp_protocol(targetCellId,voltageLevelsV,options)
%GENERATE_SINGLE_CELL_RAMP_PROTOCOL Build ascending voltage blocks for one cell.
arguments
    targetCellId (1,1) string
    voltageLevelsV (1,:) double
    options.RepeatsPerVoltage (1,1) double {mustBePositive,mustBeInteger} = 10
    options.PulseDurationMs (1,1) double {mustBePositive} = 10
    options.DarkIntervalMs (1,1) double {mustBePositive} = 90
    options.PreDelayMs (1,1) double {mustBeNonnegative} = 100
    options.PostDelayMs (1,1) double {mustBeNonnegative} = 100
end
if strlength(targetCellId)==0
    error("adaptive_optopatch:TargetCellRequired","Ramp target_cell_id is required.");
end
if isempty(voltageLevelsV) || any(~isfinite(voltageLevelsV) | voltageLevelsV<=0)
    error("adaptive_optopatch:InvalidRampVoltages", ...
        "VoltageLevelsV must be a nonempty vector of positive physical voltages.");
end
levels=double(voltageLevelsV(:)); nLevels=numel(levels);
n=nLevels*options.RepeatsPerVoltage;
commandVoltageV=repelem(levels,options.RepeatsPerVoltage);
levelIndex=repelem((1:nLevels)',options.RepeatsPerVoltage);
repeatIndex=repmat((1:options.RepeatsPerVoltage)',nLevels,1);
pulseId=(1:n)'; conditionId="voltage_"+replace(compose("%.4gV",commandVoltageV),".","p");
onsetS=(options.PreDelayMs+(0:n-1)'*(options.PulseDurationMs+options.DarkIntervalMs))/1000;
durationS=repmat(options.PulseDurationMs/1000,n,1);
targetCellIds=repmat(targetCellId,n,1); isNull=false(n,1);
amplitudeFraction=nan(n,1);
events=table(pulseId,conditionId,onsetS,durationS,targetCellIds,isNull, ...
    commandVoltageV,amplitudeFraction,levelIndex,repeatIndex, ...
    'VariableNames',{'pulse_id','condition_id','onset_s','duration_s', ...
    'target_cell_id','is_null','command_voltage_v','amplitude_fraction', ...
    'voltage_level_index','repeat_index'});
protocol=struct("schema_version","2.0.0", ...
    "protocol_id","single_cell_ramp_"+targetCellId, ...
    "protocol_type","single_cell_blue_ramp", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "random_seed",NaN,"target_cell_id",targetCellId, ...
    "voltage_levels_v",levels',"repeats_per_voltage",options.RepeatsPerVoltage, ...
    "events",events,"acquisition_duration_s", ...
    max(onsetS+durationS)+options.PostDelayMs/1000);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end
