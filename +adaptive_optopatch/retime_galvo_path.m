function [xOut,yOut,info]=retime_galvo_path(x,y,sampleRate,options)
%RETIME_GALVO_PATH Add samples until command velocity/acceleration are bounded.
arguments
    x (:,1) double
    y (:,1) double
    sampleRate (1,1) double {mustBePositive}
    options.MaximumVelocityVPerS (1,1) double {mustBePositive}
    options.MaximumAccelerationVPerS2 (1,1) double {mustBePositive}
    options.MaximumSamples (1,1) double {mustBePositive,mustBeInteger} = 1e7
end
originalCount=numel(x);
arc=[0;cumsum(hypot(diff(x),diff(y)))];
if arc(end)<=0
    error("adaptive_optopatch:DegenerateWaveform","The galvo path has zero length.");
end
[arc,uniqueIndex]=unique(arc/arc(end),"stable");
xBase=x(uniqueIndex); yBase=y(uniqueIndex);
n=originalCount;
for iteration=1:12
    s=linspace(0,1,n)';
    q=10*s.^3-15*s.^4+6*s.^5;
    xOut=interp1(arc,xBase,q,"pchip");
    yOut=interp1(arc,yBase,q,"pchip");
    velocity=max(hypot(diff(xOut),diff(yOut)))*sampleRate;
    acceleration=max(hypot(diff(xOut,2),diff(yOut,2)))*sampleRate^2;
    factor=max([1,velocity/options.MaximumVelocityVPerS, ...
        sqrt(acceleration/options.MaximumAccelerationVPerS2)]);
    if factor<=1+1e-9, break; end
    newCount=min(options.MaximumSamples,max(n+1,ceil(1.05*factor*n)));
    if newCount<=n
        error("adaptive_optopatch:GalvoRetimingFailed", ...
            "The requested galvo path cannot be retimed within the sample limit.");
    end
    n=newCount;
end
velocity=max(hypot(diff(xOut),diff(yOut)))*sampleRate;
acceleration=max(hypot(diff(xOut,2),diff(yOut,2)))*sampleRate^2;
if velocity>options.MaximumVelocityVPerS*(1+1e-6) || ...
        acceleration>options.MaximumAccelerationVPerS2*(1+1e-6)
    error("adaptive_optopatch:GalvoRetimingFailed", ...
        "The path still exceeds its dynamic limits after retiming.");
end
info=struct("original_samples",originalCount,"retimed_samples",numel(xOut), ...
    "maximum_velocity_v_per_s",velocity, ...
    "maximum_acceleration_v_per_s2",acceleration);
end
