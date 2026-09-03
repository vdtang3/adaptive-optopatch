function waveforms=build_2p_trial_waveforms(protocol,target,tform,options)
%BUILD_2P_TRIAL_WAVEFORMS Build bounded X/Y/Pockels vectors for one target.
arguments
    protocol (1,1) struct
    target (1,1) struct
    tform
    options.SampleRateHz (1,1) double {mustBePositive} = 200000
    options.CommandBoundsV (1,2) double = [-5 5]
    options.MaximumVelocityVPerS (1,1) double {mustBePositive} = 1000
    options.MaximumAccelerationVPerS2 (1,1) double {mustBePositive} = 6e6
    options.DarkVoltage (1,1) double = 0
    options.ModulatorVoltage (1,1) double = NaN
    options.MinimumIlluminatedRadiusFraction (1,1) double ...
        {mustBePositive,mustBeLessThanOrEqual(options.MinimumIlluminatedRadiusFraction,1)} = 0.95
end
pulses=adaptive_optopatch.flatten_pulse_schedule(protocol, ...
    "ConfiguredVoltage",options.ModulatorVoltage);
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
finalOff=ceil(pulses.offset_s(end)*fs);
groups=pulse_groups(pulses);
finalEvent=groups(end);
finalEventFirst=find(groups==finalEvent,1,"first");
finalEventOn=max(1,ceil(pulses.onset_s(finalEventFirst)*fs)+1);
finalEventSamples=finalOff-finalEventOn+1;
finalRemainder=mod(finalEventSamples,cycle.cycle_samples);
finalFinishCount=mod(cycle.cycle_samples-finalRemainder,cycle.cycle_samples);
requiredTotal=finalOff+finalFinishCount+size(moveOut,1);
nTotal=max(requestedTotal,requiredTotal);
x=repmat(parkV(1),nTotal,1); y=repmat(parkV(2),nTotal,1);
pockels=repmat(options.DarkVoltage,nTotal,1);
cursor=1;
eventCycleStart=NaN;
perPulse=repmat(struct("on_sample",0,"off_sample",0, ...
    "cycle_count_during_light",0,"cycle_fraction_during_light",0, ...
    "maximum_illuminated_radius_fraction",0, ...
    "dark_completion_samples",0,"center_return_sample",0, ...
    "parking_arrival_sample",0),height(pulses),1);
for k=1:height(pulses)
    % Samples represent t=(index-1)/fs. Use the first sample at or after
    % onset and the final sample strictly before offset.
    on=max(1,ceil(pulses.onset_s(k)*fs)+1);
    off=min(nTotal,ceil(pulses.offset_s(k)*fs));
    continuingEvent=k>1 && groups(k)==groups(k-1);
    lastInEvent=k==height(pulses) || ...
        groups(k)~=groups(k+1);
    if continuingEvent
        if on<cursor
            error("adaptive_optopatch:OverlappingTrainPulses", ...
                "Pulse %d overlaps the preceding pulse in its train.",k);
        end
        if on>cursor
            darkIdx=(cursor:on-1)';
            phase=mod(darkIdx-eventCycleStart,cycle.cycle_samples)+1;
            x(darkIdx)=cycle.x_v(phase); y(darkIdx)=cycle.y_v(phase);
        end
    else
        moveStart=on-size(moveIn,1)+1;
        if moveStart<cursor
            if k==1
                availableMs=pulses.onset_s(k)*1000;
                requiredMs=size(moveIn,1)/fs*1000;
                error("adaptive_optopatch:InsufficientGalvoPreDelay", ...
                    ['Pulse 1 has %.3f ms of pre-delay, but the bounded move from ' ...
                     'the dark parking point to the target requires at least %.3f ms. ' ...
                     'Increase the pre-delay to at least %d ms.'], ...
                    availableMs,requiredMs,ceil(requiredMs+1));
            end
            availableMs=(pulses.onset_s(k)-pulses.offset_s(k-1))*1000;
            completionMs=perPulse(k-1).dark_completion_samples/fs*1000;
            parkOutMs=size(moveOut,1)/fs*1000;
            parkInMs=size(moveIn,1)/fs*1000;
            requiredMs=completionMs+parkOutMs+parkInMs;
            error("adaptive_optopatch:InsufficientGalvoDarkInterval", ...
                ['Pulse %d has %.3f ms of end-to-start dark time, but this ' ...
                 'trajectory requires at least %.3f ms: %.3f ms to finish the ' ...
                 'spiral, %.3f ms to reach the dark parking point, and %.3f ms ' ...
                 'to return to the target. Set the minimum dark interval to at ' ...
                 'least %d ms and save a new planning bundle.'], ...
                k,availableMs,requiredMs,completionMs,parkOutMs,parkInMs, ...
                ceil(requiredMs+1));
        end
        idx=moveStart:on;
        x(idx)=moveIn(:,1); y(idx)=moveIn(:,2);
        eventCycleStart=on;
    end
    lightCount=off-on+1;
    cycleIndex=mod((on:off)'-eventCycleStart,cycle.cycle_samples)+1;
    [illuminatedX,illuminatedY]=transformPointsForward(tform, ...
        cycle.x_v(cycleIndex),cycle.y_v(cycleIndex));
    illuminatedRadius=max(hypot( ...
        illuminatedX-target.spiral_center_xy(1), ...
        illuminatedY-target.spiral_center_xy(2)));
    illuminatedRadiusFraction=illuminatedRadius/target.spiral_radius_pixels;
    if illuminatedRadiusFraction<options.MinimumIlluminatedRadiusFraction
        [cycleCameraX,cycleCameraY]=transformPointsForward(tform, ...
            cycle.x_v,cycle.y_v);
        firstMaximum=find(hypot( ...
            cycleCameraX-target.spiral_center_xy(1), ...
            cycleCameraY-target.spiral_center_xy(2))>= ...
            options.MinimumIlluminatedRadiusFraction* ...
            target.spiral_radius_pixels,1);
        if isempty(firstMaximum), firstMaximum=cycle.cycle_samples; end
        requiredMs=firstMaximum/fs*1000;
        error("adaptive_optopatch:PulseTooShortForSpiralRadius", ...
            ['Pulse %d reaches only %.1f%% of the requested scanner radius. ' ...
             'At the current motion limits it needs at least %.3f ms of ' ...
             'illumination to reach %.1f%% of the radius.'], ...
            k,100*illuminatedRadiusFraction,requiredMs, ...
            100*options.MinimumIlluminatedRadiusFraction);
    end
    x(on:off)=cycle.x_v(cycleIndex); y(on:off)=cycle.y_v(cycleIndex);
    pockels(on:off)=pulses.modulator_voltage(k);
    finishCount=0; finishEnd=off; parkEnd=0;
    if lastInEvent
        eventSamples=off-eventCycleStart+1;
        remainder=mod(eventSamples,cycle.cycle_samples);
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
    else
        cursor=off+1;
    end
    perPulse(k).on_sample=on; perPulse(k).off_sample=off;
    perPulse(k).cycle_count_during_light=floor(lightCount/cycle.cycle_samples);
    perPulse(k).cycle_fraction_during_light=lightCount/cycle.cycle_samples;
    perPulse(k).maximum_illuminated_radius_fraction= ...
        illuminatedRadiusFraction;
    perPulse(k).dark_completion_samples=finishCount;
    perPulse(k).center_return_sample=finishEnd*(lastInEvent);
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

function groups=pulse_groups(pulses)
if ismember("train_id",string(pulses.Properties.VariableNames))
    groups=double(pulses.train_id);
    missing=~isfinite(groups);
    groups(missing)=max([groups(~missing);0])+(1:sum(missing))';
else
    groups=(1:height(pulses))';
end
end
