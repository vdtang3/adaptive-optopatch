function protocol=generate_round_robin_protocol(fovState,options)
%GENERATE_ROUND_ROBIN_PROTOCOL Interleave calibrated stimulation-enabled cells.
arguments
    fovState (1,1) struct
    options.PulsesPerCell (1,1) double {mustBePositive,mustBeInteger} = 100
    options.PulseDurationMs (1,1) double {mustBePositive} = 10
    options.DarkIntervalMs (1,2) double {mustBePositive} = [90 110]
    options.PreDelayMs (1,1) double {mustBeNonnegative} = 100
    options.PostDelayMs (1,1) double {mustBeNonnegative} = 100
    options.RandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 3001
end
if options.DarkIntervalMs(2)<options.DarkIntervalMs(1)
    error("adaptive_optopatch:InvalidDarkInterval","DarkIntervalMs must be [minimum maximum].");
end
cells=fovState.cells;
enabled=arrayfun(@(c)cell_flag(c,"stimulation_enabled",true),cells(:));
good=arrayfun(@(c)cell_string(c,"calibration_status","uncalibrated")=="good",cells(:));
voltage=arrayfun(@(c)cell_number(c,"selected_blue_voltage_v",NaN),cells(:));
eligible=enabled & good & isfinite(voltage) & voltage>0;
if ~any(eligible)
    error("adaptive_optopatch:NoCalibratedTargets", ...
        "No stimulation-enabled cells have a good positive-voltage calibration.");
end
indices=find(eligible);
sequence=repelem(indices(:),options.PulsesPerCell);
rng(options.RandomSeed,"twister"); sequence=sequence(randperm(numel(sequence)));
n=numel(sequence);
gapsMs=options.DarkIntervalMs(1)+diff(options.DarkIntervalMs)*rand(max(0,n-1),1);
onsetMs=zeros(n,1); onsetMs(1)=options.PreDelayMs;
for k=2:n
    onsetMs(k)=onsetMs(k-1)+options.PulseDurationMs+gapsMs(k-1);
end
pulseId=(1:n)'; conditionId=repmat("round_robin",n,1);
onsetS=onsetMs/1000; durationS=repmat(options.PulseDurationMs/1000,n,1);
targetCellId=string({cells(sequence).cell_id})'; isNull=false(n,1);
commandVoltageV=voltage(sequence); amplitudeFraction=nan(n,1);
repeatIndex=zeros(n,1);
for index=reshape(indices,1,[])
    positions=find(sequence==index);
    repeatIndex(positions)=(1:numel(positions))';
end
events=table(pulseId,conditionId,onsetS,durationS,targetCellId,isNull, ...
    commandVoltageV,amplitudeFraction,repeatIndex, ...
    'VariableNames',{'pulse_id','condition_id','onset_s','duration_s', ...
    'target_cell_id','is_null','command_voltage_v','amplitude_fraction','repeat_index'});
protocol=struct("schema_version","2.0.0", ...
    "protocol_id","round_robin_seed_"+options.RandomSeed, ...
    "protocol_type","calibrated_round_robin", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "random_seed",options.RandomSeed,"events",events, ...
    "eligible_cell_ids",string({cells(indices).cell_id}), ...
    "acquisition_duration_s",max(onsetS+durationS)+options.PostDelayMs/1000);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function value=cell_flag(record,name,fallback)
if isfield(record,name), value=logical(record.(name)); else, value=fallback; end
end

function value=cell_string(record,name,fallback)
if isfield(record,name), value=string(record.(name)); else, value=string(fallback); end
end

function value=cell_number(record,name,fallback)
if isfield(record,name), value=double(record.(name)); else, value=fallback; end
end
