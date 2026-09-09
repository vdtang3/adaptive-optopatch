function protocol=generate_stf_protocol(conditions,options)
%GENERATE_STF_PROTOCOL Realize an explicit per-cell STF acquisition definition.
arguments
    conditions table
    options.EventDarkIntervalMs (1,2) double {mustBeNonnegative} = [450 550]
    options.PreDelayMs (1,1) double {mustBeNonnegative} = 100
    options.PostDelayMs (1,1) double {mustBeNonnegative} = 100
    options.EventOrder (1,1) string {mustBeMember(options.EventOrder,["ordered","randomized"])} = "randomized"
    options.RandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 1
end
required=["condition_id","frequency_hz","pulses_per_train", ...
    "pulse_duration_ms","repeats","is_null"];
if ~all(ismember(required,string(conditions.Properties.VariableNames)))
    error("adaptive_optopatch:InvalidStfConditions", ...
        "STF conditions are missing required columns.");
end
if options.EventDarkIntervalMs(2)<options.EventDarkIntervalMs(1)
    error("adaptive_optopatch:InvalidDarkInterval", ...
        "EventDarkIntervalMs must be [minimum maximum].");
end
names=string(conditions.Properties.VariableNames);
if ~ismember("amplitude_fraction",names), conditions.amplitude_fraction=ones(height(conditions),1); end
if ~ismember("command_voltage_v",names), conditions.command_voltage_v=nan(height(conditions),1); end
conditionIndex=[]; conditionRepeat=[];
for k=1:height(conditions)
    conditionIndex=[conditionIndex;repmat(k,conditions.repeats(k),1)]; %#ok<AGROW>
    conditionRepeat=[conditionRepeat;(1:conditions.repeats(k))']; %#ok<AGROW>
end
stream=RandStream("mt19937ar","Seed",options.RandomSeed);
if options.EventOrder=="randomized"
    order=randperm(stream,numel(conditionIndex));
    conditionIndex=conditionIndex(order); conditionRepeat=conditionRepeat(order);
end
gaps=options.EventDarkIntervalMs(1)+diff(options.EventDarkIntervalMs)* ...
    rand(stream,max(0,numel(conditionIndex)-1),1);
rows=table; cursorMs=options.PreDelayMs; pulseId=0;
for train=1:numel(conditionIndex)
    c=conditions(conditionIndex(train),:); pulseCount=max(1,double(c.pulses_per_train));
    local=(0:pulseCount-1)'*1000/max(double(c.frequency_hz),eps);
    if c.is_null || pulseCount==1, local=0; end
    if ~c.is_null && pulseCount>1 && c.pulse_duration_ms>=1000/c.frequency_hz
        error("adaptive_optopatch:OverlappingStfPulses", ...
            "Condition %s has pulse duration >= pulse period.",string(c.condition_id));
    end
    for p=1:pulseCount
        pulseId=pulseId+1;
        new=table(pulseId,string(c.condition_id), ...
            (cursorMs+local(p))/1000,double(c.pulse_duration_ms)/1000, ...
            logical(c.is_null),double(c.command_voltage_v),NaN, ...
            double(c.amplitude_fraction),double(c.frequency_hz), ...
            train,p,double(conditionRepeat(train)), ...
            'VariableNames',{'pulse_id','condition_id','onset_s','duration_s', ...
            'is_null','command_voltage_v','blue_mask_adjustment_pixels', ...
            'command_voltage_scale','frequency_hz','train_id', ...
            'pulse_in_train','repeat_index'});
        rows=[rows;new]; %#ok<AGROW>
    end
    trainEnd=max(local)+double(c.pulse_duration_ms);
    if train<numel(conditionIndex), cursorMs=cursorMs+trainEnd+gaps(train); end
end
rows.command_voltage_v(rows.is_null)=0; rows.command_voltage_scale(rows.is_null)=0;
acquisition=struct("acquisition_id","stf","events",rows, ...
    "parameters",struct,"event_order_realized",true,"target_repetitions",1, ...
    "acquisition_duration_s",max(rows.onset_s+rows.duration_s)+options.PostDelayMs/1000);
protocol=struct("schema_version","3.0.0","artifact_type","experiment_definition", ...
    "protocol_id","stf_mixed_seed_"+options.RandomSeed, ...
    "protocol_type","stf_mixed_conditions", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "target_policy","each_stimulation_enabled_cell", ...
    "event_order",options.EventOrder,"random_seed",options.RandomSeed, ...
    "parameters",struct,"acquisitions",acquisition);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end
