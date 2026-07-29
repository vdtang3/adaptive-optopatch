function conditions = default_stf_conditions(options)
%DEFAULT_STF_CONDITIONS Initial randomized STF condition set.
arguments
    options.RepeatsPerCondition (1,1) double {mustBePositive,mustBeInteger} = 100
    options.PulsesPerTrain (1,1) double {mustBeGreaterThanOrEqual(options.PulsesPerTrain,2),mustBeInteger} = 5
    options.PulseDurationMs (1,1) double {mustBePositive} = 5
    options.ModulatorVoltage (1,1) double {mustBeGreaterThanOrEqual(options.ModulatorVoltage,0),mustBeLessThanOrEqual(options.ModulatorVoltage,5)} = 0
end
condition_id=["single";"train_50hz";"train_100hz"];
frequency_hz=[NaN;50;100];
pulses_per_train=[1;options.PulsesPerTrain;options.PulsesPerTrain];
pulse_duration_ms=repmat(options.PulseDurationMs,3,1);
repeats=repmat(options.RepeatsPerCondition,3,1);
modulator_voltage=repmat(options.ModulatorVoltage,3,1);
is_null=false(3,1);
conditions=table(condition_id,frequency_hz,pulses_per_train, ...
    pulse_duration_ms,repeats,modulator_voltage,is_null);
end
