function report = evaluate_galvo_waveform(x,y,sampleRate,options)
%EVALUATE_GALVO_WAVEFORM Conservative GVS002 command-domain preflight.
arguments
    x (:,1) double
    y (:,1) double
    sampleRate (1,1) double {mustBePositive}
    options.CommandBoundsVolts (1,2) double = [-5 5]
    options.DriverVoltsPerDegree (1,1) double {mustBeMember(options.DriverVoltsPerDegree,[0.5 0.8 1.0])} = 0.5
    options.SmallAngleLimitDegrees (1,1) double {mustBePositive} = 0.2
    options.SmallAngleMaxRateHz (1,1) double {mustBePositive} = 1000
    options.LargeAngleMaxRateHz (1,1) double {mustBePositive} = 100
    options.MaximumVelocityVPerS (1,1) double {mustBePositive} = Inf
    options.MaximumAccelerationVPerS2 (1,1) double {mustBePositive} = Inf
    options.CheckRepetitionRate (1,1) logical = true
end
if numel(x)~=numel(y) || numel(x)<3
    error("adaptive_optopatch:InvalidGalvoWaveform", ...
        "X and Y must have equal length with at least three samples.");
end
issues=strings(0,1);
if any(~isfinite(x)) || any(~isfinite(y))
    issues(end+1)="Waveform contains nonfinite samples.";
end
if any(x<options.CommandBoundsVolts(1) | x>options.CommandBoundsVolts(2)) || ...
        any(y<options.CommandBoundsVolts(1) | y>options.CommandBoundsVolts(2))
    issues(end+1)="Waveform exceeds configured scanner voltage bounds.";
end
angleX=x/options.DriverVoltsPerDegree;
angleY=y/options.DriverVoltsPerDegree;
excursionX=(max(angleX)-min(angleX))/2;
excursionY=(max(angleY)-min(angleY))/2;
smallAngle=max(excursionX,excursionY)<=options.SmallAngleLimitDegrees;
repetitionRate=sampleRate/numel(x);
if smallAngle
    rateLimit=options.SmallAngleMaxRateHz;
else
    rateLimit=options.LargeAngleMaxRateHz;
end
if options.CheckRepetitionRate && repetitionRate>rateLimit
    issues(end+1)="Waveform repetition rate exceeds the conservative GVS002 limit.";
end
dx=diff(x)*sampleRate; dy=diff(y)*sampleRate;
ddx=diff(x,2)*sampleRate^2; ddy=diff(y,2)*sampleRate^2;
maximumVelocity=max(hypot(dx,dy));
maximumAcceleration=max(hypot(ddx,ddy));
if maximumVelocity>options.MaximumVelocityVPerS
    issues(end+1)="Waveform exceeds the configured galvo velocity limit.";
end
if maximumAcceleration>options.MaximumAccelerationVPerS2
    issues(end+1)="Waveform exceeds the configured galvo acceleration limit.";
end
report=struct("schema_version","0.2.0","passed",isempty(issues), ...
    "issues",issues,"sample_rate_hz",sampleRate, ...
    "sample_count",numel(x),"repetition_rate_hz",repetitionRate, ...
    "rate_limit_hz",rateLimit,"small_angle_class",smallAngle, ...
    "driver_volts_per_degree",options.DriverVoltsPerDegree, ...
    "excursion_x_degrees",excursionX,"excursion_y_degrees",excursionY, ...
    "max_command_step_volts",max(hypot(diff(x),diff(y))), ...
    "max_command_velocity_volts_per_s",maximumVelocity, ...
    "max_command_acceleration_volts_per_s2",maximumAcceleration, ...
    "wrap_step_volts",hypot(x(1)-x(end),y(1)-y(end)));
end
