function [xOut,yOut] = append_continuous_spiral_return(x,y,centerXY)
%APPEND_CONTINUOUS_SPIRAL_RETURN Return inward while angle keeps increasing.
arguments
    x (:,1) double
    y (:,1) double
    centerXY (1,2) double
end
if numel(x) ~= numel(y)
    error("adaptive_optopatch:WaveformSizeMismatch", ...
        "X and Y waveforms must have the same number of samples.");
end
if numel(x) < 3
    error("adaptive_optopatch:WaveformTooShort", ...
        "At least three samples are required for a continuous spiral return.");
end

dx=x-centerXY(1); dy=y-centerXY(2);
radius=hypot(dx,dy);
theta=unwrap(atan2(dy,dx));
% atan2 is undefined at exactly r=0. Anchor the center angle to the first
% nonzero point so the outbound angular increments remain well defined.
firstNonzero=find(radius>max(radius)*eps,1);
if isempty(firstNonzero)
    error("adaptive_optopatch:DegenerateWaveform","The spiral has zero radius.");
end
theta(1:firstNonzero-1)=theta(firstNonzero);
theta=unwrap(theta);

% Mirror the outbound radial schedule, but mirror the positive angular
% increments forward in time. This produces an interleaved inward spiral
% with no reversal of rotational direction.
dtheta=diff(theta);
if any(dtheta < -1e-9)
    error("adaptive_optopatch:NonmonotonicOutboundAngle", ...
        "The outbound spiral angle must be monotonically increasing.");
end
returnRadius=radius(end-1:-1:1);
returnTheta=theta(end)+cumsum(dtheta(end:-1:1));
xReturn=centerXY(1)+returnRadius.*cos(returnTheta);
yReturn=centerXY(2)+returnRadius.*sin(returnTheta);
xOut=[x;xReturn];
yOut=[y;yReturn];
end
