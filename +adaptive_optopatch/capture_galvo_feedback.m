function feedback=capture_galvo_feedback(daq,waveforms)
%CAPTURE_GALVO_FEEDBACK Copy completed finite AI samples before DAQ reset.
arguments
    daq
    waveforms (1,1) struct
end
channels=struct("port",{},"sample_rate_hz",{},"data",{}, ...
    "sample_count",{},"minimum_v",{},"maximum_v",{},"range_v",{}, ...
    "correlation_with_x",{},"correlation_with_y",{},"best_axis",{}, ...
    "best_absolute_correlation",{});
tasks=read_member(daq,"buffered_tasks",[]);
for k=1:numel(tasks)
    if string(read_member(tasks(k),"task_type",""))~="aif", continue; end
    taskChannels=read_member(tasks(k),"channels",[]);
    rate=double(read_member(tasks(k),"rate",waveforms.sample_rate_hz));
    for j=1:numel(taskChannels)
        data=double(read_member(taskChannels(j),"data",[]));
        if isempty(data), continue; end
        data=data(:);
        n=min([numel(data),numel(waveforms.x_v),numel(waveforms.y_v)]);
        data=data(1:n); x=double(waveforms.x_v(1:n)); y=double(waveforms.y_v(1:n));
        correlationX=safe_correlation(data,x);
        correlationY=safe_correlation(data,y);
        if abs(correlationX)>=abs(correlationY)
            bestAxis="x"; bestCorrelation=abs(correlationX);
        else
            bestAxis="y"; bestCorrelation=abs(correlationY);
        end
        channels(end+1)=struct( ... %#ok<AGROW>
            "port",string(read_member(taskChannels(j),"phys_channel","")), ...
            "sample_rate_hz",rate,"data",data, ...
            "sample_count",n,"minimum_v",min(data),"maximum_v",max(data), ...
            "range_v",max(data)-min(data), ...
            "correlation_with_x",correlationX, ...
            "correlation_with_y",correlationY,"best_axis",bestAxis, ...
            "best_absolute_correlation",bestCorrelation);
    end
end
valid=[channels.range_v]>=0.01 & [channels.best_absolute_correlation]>=0.8;
validAxes=string({channels(valid).best_axis});
passed=any(validAxes=="x") && any(validAxes=="y");
issues=strings(0,1);
if isempty(channels)
    issues(end+1)="No completed finite analog-input samples were available.";
elseif ~passed
    issues(end+1)=["Galvo feedback did not contain distinct, strongly tracking " + ...
        "X and Y channels. Check feedback wiring and channel assignments."];
end
summary=channels;
for k=1:numel(summary), summary(k).data=[]; end
feedback=struct("schema_version","0.1.0","captured_at", ...
    string(datetime("now","TimeZone","local")),"channels",channels, ...
    "summary",summary,"passed",passed,"issues",issues);
end

function value=safe_correlation(a,b)
a=a-mean(a); b=b-mean(b);
denominator=norm(a)*norm(b);
if denominator<=eps, value=NaN; else, value=(a'*b)/denominator; end
end

function value=read_member(object,name,defaultValue)
if isstruct(object) && isfield(object,name)
    value=object.(name);
elseif isobject(object) && isprop(object,name)
    value=object.(name);
else
    value=defaultValue;
end
end
