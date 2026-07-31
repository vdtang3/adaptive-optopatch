function waveforms=build_2p_trial_waveforms(protocol,target,tform,options)
%BUILD_2P_TRIAL_WAVEFORMS Build bounded X/Y/Pockels vectors for one target.
arguments
    protocol (1,1) struct
    target (1,1) struct
    tform
    options.SampleRateHz (1,1) double {mustBePositive} = 200000
    options.CommandBoundsV (1,2) double = [-5 5]
    options.MaximumVelocityVPerS (1,1) double {mustBePositive} = 30
    options.MaximumAccelerationVPerS2 (1,1) double {mustBePositive} = 1800
    options.DarkVoltage (1,1) double = 0
end
pulses=adaptive_optopatch.flatten_pulse_schedule(protocol);
cycle=adaptive_optopatch.generate_2p_spiral_cycle(tform, ...
    target.spiral_center_xy,target.spiral_radius_pixels, ...
    target.spiral_density_points_per_volt, ...
    "CommandBoundsV",options.CommandBoundsV);
[cycle.x_v,cycle.y_v,cycle.retiming]= ...
    adaptive_optopatch.retime_galvo_path(cycle.x_v,cycle.y_v, ...
    options.SampleRateHz, ...
    "MaximumVelocityVPerS",options.MaximumVelocityVPerS, ...
    "MaximumAccelerationVPerS2",options.MaximumAccelerationVPerS2);
cycle.cycle_samples=numel(cycle.x_v);
parkV=adaptive_optopatch.camera_to_galvo_volts(tform,target.parking_point_xy);
centerV=cycle.center_v;
fs=options.SampleRateHz;
moveIn=adaptive_optopatch.minimum_jerk_transition(parkV,centerV,fs, ...
    "MaximumVelocityVPerS",options.MaximumVelocityVPerS, ...
    "MaximumAccelerationVPerS2",options.MaximumAccelerationVPerS2);
moveOut=adaptive_optopatch.minimum_jerk_transition(centerV,parkV,fs, ...
    "MaximumVelocityVPerS",options.MaximumVelocityVPerS, ...
    "MaximumAccelerationVPerS2",options.MaximumAccelerationVPerS2);
requestedTotal=ceil(protocol.acquisition_duration_s*fs);
% Grow only the final acquisition tail when needed. Pulse timing and every
% end-to-start dark interval remain exactly as requested.
finalOn=max(1,floor(pulses.onset_s(end)*fs)+1);
finalOff=ceil(pulses.offset_s(end)*fs);
finalLightCount=finalOff-finalOn+1;
finalRemainder=mod(finalLightCount,cycle.cycle_samples);
finalFinishCount=mod(cycle.cycle_samples-finalRemainder,cycle.cycle_samples);
requiredTotal=finalOff+finalFinishCount+size(moveOut,1);
nTotal=max(requestedTotal,requiredTotal);
x=repmat(parkV(1),nTotal,1); y=repmat(parkV(2),nTotal,1);
pockels=repmat(options.DarkVoltage,nTotal,1);
cursor=1;
perPulse=repmat(struct("on_sample",0,"off_sample",0, ...
    "cycle_count_during_light",0,"cycle_fraction_during_light",0, ...
    "dark_completion_samples",0,"center_return_sample",0, ...
    "parking_arrival_sample",0),height(pulses),1);
for k=1:height(pulses)
    on=max(1,floor(pulses.onset_s(k)*fs)+1);
    off=min(nTotal,ceil(pulses.offset_s(k)*fs));
    moveStart=on-size(moveIn,1)+1;
    if moveStart<cursor
        error("adaptive_optopatch:InsufficientGalvoDarkInterval", ...
            "Pulse %d does not leave enough dark time to reach its target safely.",k);
    end
    idx=moveStart:on;
    x(idx)=moveIn(:,1); y(idx)=moveIn(:,2);
    lightCount=off-on+1;
    cycleIndex=mod((0:lightCount-1)',cycle.cycle_samples)+1;
    x(on:off)=cycle.x_v(cycleIndex); y(on:off)=cycle.y_v(cycleIndex);
    pockels(on:off)=pulses.modulator_voltage(k);
    remainder=mod(lightCount,cycle.cycle_samples);
    finishCount=mod(cycle.cycle_samples-remainder,cycle.cycle_samples);
    finishEnd=off+finishCount;
    if finishCount>0
        if finishEnd>nTotal
            error("adaptive_optopatch:GalvoReturnOutsideAcquisition", ...
                "The final spiral cannot return to center before acquisition end.");
        end
        finishIndex=(remainder+1:cycle.cycle_samples)';
        x(off+1:finishEnd)=cycle.x_v(finishIndex);
        y(off+1:finishEnd)=cycle.y_v(finishIndex);
    end
    parkStart=finishEnd+1; parkEnd=parkStart+size(moveOut,1)-1;
    if parkEnd>nTotal
        error("adaptive_optopatch:GalvoReturnOutsideAcquisition", ...
            "Pulse %d cannot reach the parking point before acquisition end.",k);
    end
    x(parkStart:parkEnd)=moveOut(:,1); y(parkStart:parkEnd)=moveOut(:,2);
    cursor=parkEnd+1;
    perPulse(k).on_sample=on; perPulse(k).off_sample=off;
    perPulse(k).cycle_count_during_light=floor(lightCount/cycle.cycle_samples);
    perPulse(k).cycle_fraction_during_light=lightCount/cycle.cycle_samples;
    perPulse(k).dark_completion_samples=finishCount;
    perPulse(k).center_return_sample=finishEnd;
    perPulse(k).parking_arrival_sample=parkEnd;
end
report=adaptive_optopatch.evaluate_galvo_waveform(x,y,fs, ...
    "CommandBoundsVolts",options.CommandBoundsV, ...
    "MaximumVelocityVPerS",options.MaximumVelocityVPerS, ...
    "MaximumAccelerationVPerS2",options.MaximumAccelerationVPerS2, ...
    "CheckRepetitionRate",false);
if ~report.passed
    error("adaptive_optopatch:GalvoPreflightFailed","%s", ...
        strjoin(report.issues,newline));
end
waveforms=struct("schema_version","0.1.0","sample_rate_hz",fs, ...
    "x_v",x,"y_v",y,"pockels_v",pockels,"cycle",cycle, ...
    "parking_camera_xy",target.parking_point_xy,"parking_v",parkV, ...
    "per_pulse",perPulse,"preflight",report, ...
    "requested_acquisition_duration_s",requestedTotal/fs, ...
    "actual_acquisition_duration_s",nTotal/fs, ...
    "automatic_extension_s",(nTotal-requestedTotal)/fs);
end
