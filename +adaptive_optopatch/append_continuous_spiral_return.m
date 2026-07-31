function [xOut,yOut] = append_continuous_spiral_return(x,y,centerXY)
%APPEND_CONTINUOUS_SPIRAL_RETURN Return inward without reversing rotation.
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

% Mirror the outbound radial schedule and continue its angular increments
% forward in time. A camera/galvo calibration may reverse handedness, so a
% valid outbound spiral can be consistently clockwise (negative dtheta) or
% counterclockwise (positive dtheta). Only an actual sign reversal is
% unsafe here.
dtheta=diff(theta);
significant=dtheta(abs(dtheta)>1e-9);
if ~isempty(significant) && any(significant>0) && any(significant<0)
    error("adaptive_optopatch:NonmonotonicOutboundAngle", ...
        ["The outbound spiral reverses rotational direction. Its angle " + ...
         "must be monotonic, either increasing or decreasing."]);
end
returnRadius=radius(end-1:-1:1);
returnTheta=theta(end)+cumsum(dtheta(end:-1:1));
xReturn=centerXY(1)+returnRadius.*cos(returnTheta);
yReturn=centerXY(2)+returnRadius.*sin(returnTheta);
xOut=[x;xReturn];
yOut=[y;yReturn];
end
