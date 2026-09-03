function protocol = generate_screen_protocol(options)
%GENERATE_SCREEN_PROTOCOL Create the realized test-pulse schedule.
arguments
    options.PulseCount (1,1) double {mustBePositive,mustBeInteger} = 200
    options.PulseDurationMs (1,1) double {mustBePositive} = 5
    options.DarkIntervalMs (1,2) double {mustBePositive} = [45 55]
    options.PreDelayMs (1,1) double {mustBeNonnegative} = 100
    options.PostDelayMs (1,1) double {mustBeNonnegative} = 100
    options.ModulatorVoltage (1,1) double {mustBeGreaterThanOrEqual(options.ModulatorVoltage,0),mustBeLessThanOrEqual(options.ModulatorVoltage,5)} = 0
    options.RandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 1
end
if options.DarkIntervalMs(2) < options.DarkIntervalMs(1)
    error("adaptive_optopatch:InvalidDarkInterval", ...
        "DarkIntervalMs must be [minimum maximum].");
end

rng(options.RandomSeed,"twister");
nGaps=options.PulseCount-1;
darkMs=options.DarkIntervalMs(1) + ...
    diff(options.DarkIntervalMs)*rand(nGaps,1);
durationMs=repmat(options.PulseDurationMs,options.PulseCount,1);
onsetMs=zeros(options.PulseCount,1);
onsetMs(1)=options.PreDelayMs;
for k=2:options.PulseCount
    onsetMs(k)=onsetMs(k-1)+durationMs(k-1)+darkMs(k-1);
end
offsetMs=onsetMs+durationMs;
eventId=(1:options.PulseCount)';
conditionId=repmat("pulse",options.PulseCount,1);
amplitudeFraction=ones(options.PulseCount,1);
events=table(eventId,conditionId,onsetMs/1000,durationMs/1000, ...
    amplitudeFraction,eventId,offsetMs/1000, ...
    repmat(options.ModulatorVoltage,options.PulseCount,1), ...
    'VariableNames',{'event_id','condition_id','onset_s','duration_s', ...
    'amplitude_fraction','pulse_index','offset_s','modulator_voltage'});

protocol=struct;
protocol.schema_version="1.0.0";
protocol.protocol_id="connectivity_screen_seed_"+options.RandomSeed;
protocol.protocol_type="connectivity_screen";
protocol.created_at=string(datetime("now","TimeZone","local"));
protocol.random_seed=options.RandomSeed;
protocol.pulse_count=options.PulseCount;
protocol.pulse_duration_ms=options.PulseDurationMs;
protocol.dark_interval_range_ms=options.DarkIntervalMs;
protocol.realized_dark_intervals_ms=darkMs;
protocol.pre_delay_ms=options.PreDelayMs;
protocol.post_delay_ms=options.PostDelayMs;
protocol.modulator_voltage=options.ModulatorVoltage;
protocol.interval_semantics="pulse_end_to_next_pulse_start";
protocol.events=events;
protocol.acquisition_duration_s=(offsetMs(end)+options.PostDelayMs)/1000;
protocol.total_light_on_s=sum(durationMs)/1000;
protocol=adaptive_optopatch.normalize_protocol(protocol);
end
