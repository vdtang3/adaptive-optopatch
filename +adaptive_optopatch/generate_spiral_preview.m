function xy = generate_spiral_preview(centerXY, radiusPixels, densityPointsPerVolt, options)
%GENERATE_SPIRAL_PREVIEW Render Luminos's Fermat spiral in normalized volts.
% The live turn count is radius_in_scanner_volts * Points_Per_Volt. Offline,
% the scanner-voltage radius is unavailable, so the default is one volt.
arguments
    centerXY (1,2) double
    radiusPixels (1,1) double {mustBePositive}
    densityPointsPerVolt (1,1) double {mustBePositive}
    options.NormalizedRadiusVolts (1,1) double {mustBePositive} = 1
    options.MaximumDisplayPoints (1,1) double {mustBePositive,mustBeInteger} = 50000
    options.ContinuousReturn (1,1) logical = true
end

radiusVolts = options.NormalizedRadiusVolts;
nNative = max(2,round(pi*radiusVolts^2*densityPointsPerVolt^2));
t = linspace(0,nNative-1,min(nNative,options.MaximumDisplayPoints));
rVolts = sqrt(t/(pi*densityPointsPerVolt^2));
theta = sqrt(4*pi*t);
rPixels = radiusPixels*(rVolts/radiusVolts);
xy = [centerXY(1)+rPixels.*cos(theta); ...
      centerXY(2)+rPixels.*sin(theta)]';
if options.ContinuousReturn && size(xy,1) > 2
    [x,y] = adaptive_optopatch.append_continuous_spiral_return( ...
        xy(:,1),xy(:,2),centerXY);
    xy=[x y];
end
end
