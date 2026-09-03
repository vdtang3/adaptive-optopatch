function protocol = generate_stf_protocol(conditions, options)
%GENERATE_STF_PROTOCOL Randomly intermix STF conditions in one acquisition.
arguments
    conditions table
    options.EventDarkIntervalMs (1,2) double {mustBePositive} = [450 550]
    options.PreDelayMs (1,1) double {mustBeNonnegative} = 100
    options.PostDelayMs (1,1) double {mustBeNonnegative} = 100
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
if any(conditions.frequency_hz(~isnan(conditions.frequency_hz))>100)
    error("adaptive_optopatch:StfFrequencyTooHigh", ...
        "STF frequency cannot exceed 100 Hz.");
end
if ~ismember("amplitude_fraction",string(conditions.Properties.VariableNames))
    if ismember("modulator_voltage",string(conditions.Properties.VariableNames))
        maximum=max(conditions.modulator_voltage,[],"omitmissing");
        if maximum>0, conditions.amplitude_fraction=conditions.modulator_voltage/maximum;
        else, conditions.amplitude_fraction=ones(height(conditions),1); end
    else
        conditions.amplitude_fraction=ones(height(conditions),1);
    end
    conditions.amplitude_fraction(conditions.is_null)=0;
end
if any(~isfinite(conditions.amplitude_fraction) | conditions.amplitude_fraction<0)
    error("adaptive_optopatch:ModulatorVoltageOutOfRange", ...
        "All STF amplitude fractions must be finite and nonnegative.");
end

conditionIndex=[];
for k=1:height(conditions)
    conditionIndex=[conditionIndex;repmat(k,conditions.repeats(k),1)]; %#ok<AGROW>
end
rng(options.RandomSeed,"twister");
conditionIndex=conditionIndex(randperm(numel(conditionIndex)));
nEvents=numel(conditionIndex);
gapsMs=options.EventDarkIntervalMs(1)+ ...
    diff(options.EventDarkIntervalMs)*rand(max(0,nEvents-1),1);

eventIndex=(1:nEvents)';
conditionId=strings(nEvents,1);
eventOnsetS=zeros(nEvents,1);
eventOffsetS=zeros(nEvents,1);
pulseTimes=cell(nEvents,1);
frequencyHz=nan(nEvents,1);
pulsesPerTrain=zeros(nEvents,1);
isNull=false(nEvents,1);
modulatorVoltage=zeros(nEvents,1);
amplitudeFraction=zeros(nEvents,1);
cursorMs=options.PreDelayMs;
for e=1:nEvents
    c=conditions(conditionIndex(e),:);
    conditionId(e)=string(c.condition_id);
    frequencyHz(e)=c.frequency_hz;
    pulsesPerTrain(e)=c.pulses_per_train;
    isNull(e)=c.is_null;
    amplitudeFraction(e)=c.amplitude_fraction;
    if ismember("modulator_voltage",string(c.Properties.VariableNames))
        modulatorVoltage(e)=c.modulator_voltage;
    end
    if c.is_null
        localOnsetsMs=0;
        trainDurationMs=c.pulse_duration_ms;
    elseif c.pulses_per_train==1
        localOnsetsMs=0;
        trainDurationMs=c.pulse_duration_ms;
    else
        periodMs=1000/c.frequency_hz;
        if c.pulse_duration_ms>=periodMs
            error("adaptive_optopatch:OverlappingStfPulses", ...
                "Condition %s has pulse duration >= pulse period.",string(c.condition_id));
        end
        localOnsetsMs=(0:c.pulses_per_train-1)'*periodMs;
        trainDurationMs=localOnsetsMs(end)+c.pulse_duration_ms;
    end
    eventOnsetS(e)=cursorMs/1000;
    eventOffsetS(e)=(cursorMs+trainDurationMs)/1000;
    pulseTimes{e}=(cursorMs+localOnsetsMs)/1000;
    if e<nEvents, cursorMs=cursorMs+trainDurationMs+gapsMs(e); end
end
eventId=eventIndex;
durationS=eventOffsetS-eventOnsetS;
pulseDurationS=conditions.pulse_duration_ms(conditionIndex)/1000;
events=table(eventId,conditionId,eventOnsetS,durationS,amplitudeFraction, ...
    eventIndex,conditionIndex,eventOnsetS,eventOffsetS,frequencyHz, ...
    pulsesPerTrain,isNull,modulatorVoltage,pulseTimes,pulseDurationS, ...
    'VariableNames',{'event_id','condition_id','onset_s','duration_s', ...
    'amplitude_fraction','event_index','condition_index','event_onset_s', ...
    'event_offset_s','frequency_hz','pulses_per_train','is_null', ...
    'modulator_voltage','pulse_times_s','pulse_duration_s'});

protocol=struct;
protocol.schema_version="1.0.0";
protocol.protocol_id="stf_mixed_seed_"+options.RandomSeed;
protocol.protocol_type="stf_mixed_conditions";
protocol.created_at=string(datetime("now","TimeZone","local"));
protocol.random_seed=options.RandomSeed;
protocol.conditions=conditions;
protocol.events=events;
protocol.realized_event_dark_intervals_ms=gapsMs;
protocol.event_dark_interval_range_ms=options.EventDarkIntervalMs;
protocol.pre_delay_ms=options.PreDelayMs;
protocol.post_delay_ms=options.PostDelayMs;
protocol.acquisition_duration_s=eventOffsetS(end)+options.PostDelayMs/1000;
protocol.total_light_on_s=sum(conditions.pulse_duration_ms(conditionIndex).* ...
    conditions.pulses_per_train(conditionIndex).*(~conditions.is_null(conditionIndex)))/1000;
protocol=adaptive_optopatch.normalize_protocol(protocol);
end
