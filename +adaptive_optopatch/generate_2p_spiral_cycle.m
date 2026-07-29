function cycle=generate_2p_spiral_cycle(tform,centerXY,radiusPixels,pointsPerVolt,options)
%GENERATE_2P_SPIRAL_CYCLE Generate an outward/inward camera-circular spiral.
arguments
    tform
    centerXY (1,2) double
    radiusPixels (1,1) double {mustBePositive}
    pointsPerVolt (1,1) double {mustBePositive}
    options.CommandBoundsV (1,2) double = [-5 5]
    options.MaximumCycleSamples (1,1) double {mustBePositive,mustBeInteger} = 2e6
end
centerV=adaptive_optopatch.camera_to_galvo_volts(tform,centerXY);
edgeCamera=centerXY+[radiusPixels 0;0 radiusPixels;-radiusPixels 0;0 -radiusPixels];
edgeV=adaptive_optopatch.camera_to_galvo_volts(tform,edgeCamera);
allV=[centerV;edgeV];
if any(allV<options.CommandBoundsV(1) | allV>options.CommandBoundsV(2),"all")
    error("adaptive_optopatch:ScannerCalibrationOutsideBounds", ...
        "The archived camera-to-galvo calibration maps this target outside " + ...
        "the configured %.3g to %.3g V command range. Recalibrate before use.", ...
        options.CommandBoundsV(1),options.CommandBoundsV(2));
end
radiusV=max(vecnorm(edgeV-centerV,2,2));
nOutbound=max(3,round(pi*radiusV^2*pointsPerVolt^2));
if 2*nOutbound-1>options.MaximumCycleSamples
    error("adaptive_optopatch:ScannerCalibrationImplausible", ...
        "The calibration would require %d samples for one spiral cycle.", ...
        2*nOutbound-1);
end
t=(0:nOutbound-1)';
r=sqrt(t/(pi*pointsPerVolt^2));
theta=sqrt(4*pi*t);
% Normalize the terminal radius exactly, then draw the desired circle in
% camera space and invert the archived Luminos calibration.
rCamera=radiusPixels*r/max(r);
cameraXY=centerXY+[rCamera.*cos(theta) rCamera.*sin(theta)];
outboundV=adaptive_optopatch.camera_to_galvo_volts(tform,cameraXY);
[x,y]=adaptive_optopatch.append_continuous_spiral_return( ...
    outboundV(:,1),outboundV(:,2),centerV);
cycle=struct("schema_version","0.1.0","x_v",x,"y_v",y, ...
    "center_camera_xy",centerXY,"center_v",centerV, ...
    "radius_pixels",radiusPixels,"maximum_radius_v",radiusV, ...
    "points_per_volt",pointsPerVolt,"outbound_samples",nOutbound, ...
    "cycle_samples",numel(x));
end
