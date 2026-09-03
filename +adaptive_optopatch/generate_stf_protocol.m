function protocol=generate_stf_protocol(conditions,options)
%GENERATE_STF_PROTOCOL Randomize conditions and emit one row per pulse.
arguments
    conditions table
    options.EventDarkIntervalMs (1,2) double {mustBePositive} = [450 550]
    options.PreDelayMs (1,1) double {mustBeNonnegative} = 100
    options.PostDelayMs (1,1) double {mustBeNonnegative} = 100
    options.RandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 1
end
required=["condition_id","frequency_hz","pulses_per_train", ...
    "pulse_duration_ms","repeats","is_null"];
names=string(conditions.Properties.VariableNames);
if ~all(ismember(required,names))
    error("adaptive_optopatch:InvalidStfConditions", ...
        "STF conditions are missing required columns.");
end
if options.EventDarkIntervalMs(2)<options.EventDarkIntervalMs(1)
    error("adaptive_optopatch:InvalidDarkInterval", ...
        "EventDarkIntervalMs must be [minimum maximum].");
end
if any(conditions.frequency_hz(~isnan(conditions.frequency_hz))>100)
    error("adaptive_optopatch:StfFrequencyTooHigh","STF frequency cannot exceed 100 Hz.");
end
if ~ismember("amplitude_fraction",names), conditions.amplitude_fraction=ones(height(conditions),1); end
if ~ismember("command_voltage_v",names), conditions.command_voltage_v=nan(height(conditions),1); end
if ~ismember("target_cell_id",names), conditions.target_cell_id=repmat("",height(conditions),1); end
conditions.target_cell_id=string(conditions.target_cell_id);
conditions.amplitude_fraction(conditions.is_null)=0;
conditions.command_voltage_v(conditions.is_null)=0;

conditionIndex=[]; conditionRepeat=[];
for k=1:height(conditions)
    conditionIndex=[conditionIndex;repmat(k,conditions.repeats(k),1)]; %#ok<AGROW>
    conditionRepeat=[conditionRepeat;(1:conditions.repeats(k))']; %#ok<AGROW>
end
rng(options.RandomSeed,"twister");
order=randperm(numel(conditionIndex));
conditionIndex=conditionIndex(order); conditionRepeat=conditionRepeat(order);
nTrains=numel(conditionIndex);
gapsMs=options.EventDarkIntervalMs(1)+ ...
    diff(options.EventDarkIntervalMs)*rand(max(0,nTrains-1),1);

rows=table; cursorMs=options.PreDelayMs; pulseId=0;
for train=1:nTrains
    c=conditions(conditionIndex(train),:);
    pulseCount=max(1,double(c.pulses_per_train));
    if c.is_null || pulseCount==1
        localOnsetsMs=0;
    else
        periodMs=1000/double(c.frequency_hz);
        if c.pulse_duration_ms>=periodMs
            error("adaptive_optopatch:OverlappingStfPulses", ...
                "Condition %s has pulse duration >= pulse period.",string(c.condition_id));
        end
        localOnsetsMs=(0:pulseCount-1)'*periodMs;
    end
    for p=1:pulseCount
        pulseId=pulseId+1;
        conditionId=string(c.condition_id);
        onsetS=(cursorMs+localOnsetsMs(p))/1000;
        durationS=double(c.pulse_duration_ms)/1000;
        targetCellId=string(c.target_cell_id);
        isNull=logical(c.is_null);
        commandVoltageV=double(c.command_voltage_v);
        amplitudeFraction=double(c.amplitude_fraction);
        trainId=train; pulseInTrain=p; repeatIndex=conditionRepeat(train);
        frequencyHz=double(c.frequency_hz);
        row=table(pulseId,conditionId,onsetS,durationS,targetCellId,isNull, ...
            commandVoltageV,amplitudeFraction,trainId,pulseInTrain, ...
            repeatIndex,frequencyHz,conditionIndex(train), ...
            'VariableNames',{'pulse_id','condition_id','onset_s','duration_s', ...
            'target_cell_id','is_null','command_voltage_v','amplitude_fraction', ...
            'train_id','pulse_in_train','repeat_index','frequency_hz','condition_index'});
        rows=[rows;row]; %#ok<AGROW>
    end
    trainDurationMs=localOnsetsMs(end)+double(c.pulse_duration_ms);
    if train<nTrains, cursorMs=cursorMs+trainDurationMs+gapsMs(train); end
end

protocol=struct;
protocol.schema_version="2.0.0";
protocol.protocol_id="stf_mixed_seed_"+options.RandomSeed;
protocol.protocol_type="stf_mixed_conditions";
protocol.created_at=string(datetime("now","TimeZone","local"));
protocol.random_seed=options.RandomSeed;
protocol.conditions=conditions;
protocol.events=rows;
protocol.realized_event_dark_intervals_ms=gapsMs;
protocol.event_dark_interval_range_ms=options.EventDarkIntervalMs;
protocol.pre_delay_ms=options.PreDelayMs;
protocol.post_delay_ms=options.PostDelayMs;
protocol.acquisition_duration_s=max(rows.onset_s+rows.duration_s)+options.PostDelayMs/1000;
protocol.total_light_on_s=sum(rows.duration_s(~rows.is_null));
protocol=adaptive_optopatch.normalize_protocol(protocol);
end
