function xy=minimum_jerk_transition(startXY,endXY,sampleRate,options)
%MINIMUM_JERK_TRANSITION Quintic transition satisfying vector limits.
arguments
    startXY (1,2) double
    endXY (1,2) double
    sampleRate (1,1) double {mustBePositive}
    options.MaximumVelocityVPerS (1,1) double {mustBePositive} = 1000
    options.MaximumAccelerationVPerS2 (1,1) double {mustBePositive} = 6e6
end
distance=norm(endXY-startXY);
if distance==0, xy=startXY; return; end
duration=max(1.875*distance/options.MaximumVelocityVPerS, ...
    sqrt(5.773503*distance/options.MaximumAccelerationVPerS2));
n=max(3,ceil(duration*sampleRate)+1);
s=linspace(0,1,n)';
q=10*s.^3-15*s.^4+6*s.^5;
xy=startXY+q.*(endXY-startXY);
end
