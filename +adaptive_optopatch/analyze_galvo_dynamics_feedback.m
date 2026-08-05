function result=analyze_galvo_dynamics_feedback(waveform,feedback,options)
%ANALYZE_GALVO_DYNAMICS_FEEDBACK Score one driven-axis feedback burst.
arguments
    waveform (1,1) struct
    feedback (1,1) struct
    options.ExpectedAbsoluteGain (1,1) double {mustBePositive} = 0.625
    options.GainToleranceFraction (1,1) double {mustBePositive} = 0.15
    options.MinimumAbsoluteCorrelation (1,1) double {mustBePositive} = 0.98
    options.MaximumNormalizedRmsError (1,1) double {mustBePositive} = 0.05
    options.MaximumLagUs (1,1) double {mustBePositive} = 600
    options.MaximumTerminalErrorFraction (1,1) double {mustBePositive} = 0.05
end
issues=strings(0,1);
if isempty(feedback.channels)
    result=failed("No finite AI feedback samples were captured."); return
end
if waveform.axis=="x", command=double(waveform.x_v(:));
else, command=double(waveform.y_v(:)); end
indices=double(waveform.analysis_indices(:));
maxLag=ceil(options.MaximumLagUs*1e-6*waveform.sample_rate_hz);
scores=repmat(struct("channel_index",0,"port","","lag_samples",0, ...
    "lag_us",NaN,"correlation",NaN,"gain",NaN,"offset_v",NaN, ...
    "normalized_rms_error",Inf,"terminal_error_fraction",Inf, ...
    "passed",false,"issues",strings(0,1)),numel(feedback.channels),1);
for k=1:numel(feedback.channels)
    data=double(feedback.channels(k).data(:));
    n=min(numel(command),numel(data));
    validIndices=indices(indices>=1 & indices<=n);
    [lag,correlation]=best_lag(command,data,validIndices,maxLag);
    [commandAligned,dataAligned]=align(command,data,validIndices,lag);
    coefficients=[commandAligned ones(size(commandAligned))]\dataAligned;
    prediction=coefficients(1)*commandAligned+coefficients(2);
    scale=max(dataAligned)-min(dataAligned);
    normalizedRms=sqrt(mean((dataAligned-prediction).^2))/max(scale,eps);
    nTerminal=max(1,round(0.02*waveform.sample_rate_hz));
    baseline=mean(data(1:min(nTerminal,n)));
    terminal=mean(data(max(1,n-nTerminal+1):n));
    terminalError=abs(terminal-baseline)/ ...
        max(options.ExpectedAbsoluteGain*waveform.amplitude_v,eps);
    channelIssues=strings(0,1);
    if abs(correlation)<options.MinimumAbsoluteCorrelation
        channelIssues(end+1)="correlation below threshold";
    end
    gainError=abs(abs(coefficients(1))-options.ExpectedAbsoluteGain)/ ...
        options.ExpectedAbsoluteGain;
    if gainError>options.GainToleranceFraction
        channelIssues(end+1)="feedback gain outside tolerance";
    end
    if normalizedRms>options.MaximumNormalizedRmsError
        channelIssues(end+1)="normalized RMS tracking error above threshold";
    end
    if terminalError>options.MaximumTerminalErrorFraction
        channelIssues(end+1)="terminal return error above threshold";
    end
    scores(k)=struct("channel_index",k,"port",feedback.channels(k).port, ...
        "lag_samples",lag,"lag_us",lag/waveform.sample_rate_hz*1e6, ...
        "correlation",correlation,"gain",coefficients(1), ...
        "offset_v",coefficients(2),"normalized_rms_error",normalizedRms, ...
        "terminal_error_fraction",terminalError,"passed",isempty(channelIssues), ...
        "issues",channelIssues);
end
[~,bestIndex]=max(abs([scores.correlation]));
best=scores(bestIndex);
if ~best.passed
    issues="Best feedback channel "+best.port+" failed: "+strjoin(best.issues,", ")+".";
end
result=struct("schema_version","0.1.0","passed",best.passed, ...
    "issues",issues,"axis",waveform.axis,"amplitude_v",waveform.amplitude_v, ...
    "frequency_hz",waveform.frequency_hz, ...
    "maximum_velocity_v_per_s",waveform.maximum_velocity_v_per_s, ...
    "maximum_acceleration_v_per_s2",waveform.maximum_acceleration_v_per_s2, ...
    "best_channel",best,"all_channels",scores);

    function value=failed(message)
        value=struct("schema_version","0.1.0","passed",false, ...
            "issues",string(message),"axis",waveform.axis, ...
            "amplitude_v",waveform.amplitude_v,"frequency_hz",waveform.frequency_hz, ...
            "maximum_velocity_v_per_s",waveform.maximum_velocity_v_per_s, ...
            "maximum_acceleration_v_per_s2",waveform.maximum_acceleration_v_per_s2, ...
            "best_channel",struct([]),"all_channels",struct([]));
    end
end

function [bestLag,bestCorrelation]=best_lag(command,data,indices,maxLag)
bestLag=0; bestCorrelation=NaN; bestMagnitude=-Inf;
for lag=-maxLag:maxLag
    [a,b]=align(command,data,indices,lag);
    a=a-mean(a); b=b-mean(b); denominator=norm(a)*norm(b);
    if denominator<=eps, correlation=NaN; else, correlation=(a'*b)/denominator; end
    if isfinite(correlation) && abs(correlation)>bestMagnitude
        bestMagnitude=abs(correlation); bestCorrelation=correlation; bestLag=lag;
    end
end
end

function [a,b]=align(command,data,indices,lag)
commandIndices=indices;
dataIndices=indices+lag;
valid=dataIndices>=1 & dataIndices<=numel(data) & ...
    commandIndices>=1 & commandIndices<=numel(command);
a=command(commandIndices(valid)); b=data(dataIndices(valid));
end
