function waveform=generate_galvo_dynamics_waveform(axisName,amplitudeV,frequencyHz,options)
%GENERATE_GALVO_DYNAMICS_WAVEFORM Smooth finite sine burst for one axis.
arguments
    axisName (1,1) string {mustBeMember(axisName,["x","y"])}
    amplitudeV (1,1) double {mustBePositive,mustBeLessThanOrEqual(amplitudeV,0.25)}
    frequencyHz (1,1) double {mustBePositive,mustBeLessThanOrEqual(frequencyHz,1000)}
    options.SampleRateHz (1,1) double {mustBePositive} = 200000
    options.Cycles (1,1) double {mustBeInteger,mustBeGreaterThanOrEqual(options.Cycles,10)} = 20
    options.RampCycles (1,1) double {mustBeInteger,mustBePositive} = 2
    options.PreDelayS (1,1) double {mustBeNonnegative} = 0.1
    options.PostDelayS (1,1) double {mustBeNonnegative} = 0.5
    options.CommandCenterV (1,2) double = [0 0]
    options.CommandBoundsV (1,2) double = [-5 5]
end
if 2*options.RampCycles>=options.Cycles
    error("adaptive_optopatch:InvalidGalvoDynamicsEnvelope", ...
        "RampCycles must leave at least one full-amplitude cycle.");
end
fs=options.SampleRateHz;
nPre=ceil(options.PreDelayS*fs);
nBurst=ceil(options.Cycles/frequencyHz*fs);
nPost=ceil(options.PostDelayS*fs);
t=(0:nBurst-1)'/fs;
phase=2*pi*frequencyHz*t;
nRamp=min(floor(nBurst/2),ceil(options.RampCycles/frequencyHz*fs));
envelope=ones(nBurst,1);
q=(0:nRamp-1)'/max(1,nRamp-1);
ramp=0.5-0.5*cos(pi*q);
envelope(1:nRamp)=ramp;
envelope(end-nRamp+1:end)=flipud(ramp);
burst=amplitudeV*envelope.*sin(phase);
x=repmat(options.CommandCenterV(1),nPre+nBurst+nPost,1);
y=repmat(options.CommandCenterV(2),size(x));
burstIndices=nPre+(1:nBurst);
if axisName=="x", x(burstIndices)=x(burstIndices)+burst;
else, y(burstIndices)=y(burstIndices)+burst; end
if any(x<options.CommandBoundsV(1) | x>options.CommandBoundsV(2) | ...
        y<options.CommandBoundsV(1) | y>options.CommandBoundsV(2),"all")
    error("adaptive_optopatch:GalvoDynamicsOutsideBounds", ...
        "The dynamics waveform exceeds scanner command bounds.");
end
velocity=max(hypot(diff(x),diff(y)))*fs;
acceleration=max(hypot(diff(x,2),diff(y,2)))*fs^2;
waveform=struct("schema_version","0.1.0","sample_rate_hz",fs, ...
    "x_v",x,"y_v",y,"pockels_v",zeros(size(x)), ...
    "axis",axisName,"amplitude_v",amplitudeV,"frequency_hz",frequencyHz, ...
    "cycles",options.Cycles,"ramp_cycles",options.RampCycles, ...
    "burst_indices",burstIndices(:),"analysis_indices", ...
    (nPre+nRamp+1:nPre+nBurst-nRamp)', ...
    "pre_delay_s",options.PreDelayS,"post_delay_s",options.PostDelayS, ...
    "duration_s",numel(x)/fs,"maximum_velocity_v_per_s",velocity, ...
    "maximum_acceleration_v_per_s2",acceleration, ...
    "preflight",struct("passed",true),"per_pulse",struct([]), ...
    "requested_acquisition_duration_s",numel(x)/fs, ...
    "actual_acquisition_duration_s",numel(x)/fs,"automatic_extension_s",0);
end
