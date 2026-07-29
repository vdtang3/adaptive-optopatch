function metrics = calculate_spiral_cycles(scannerTransform, centerXY, radiusPixels, densityPointsPerVolt, pulseDurationMs, options)
%CALCULATE_SPIRAL_CYCLES Calculate calibrated double-spiral timing.
arguments
    scannerTransform
    centerXY (1,2) double
    radiusPixels (1,1) double {mustBePositive}
    densityPointsPerVolt (1,1) double {mustBePositive}
    pulseDurationMs (1,1) double {mustBePositive}
    options.ScannerSampleRateHz (1,1) double {mustBePositive} = 200000
    options.CommandBoundsV (1,2) double = [-5 5]
end
metrics=struct("calibrated",false,"scanner_radius_volts",NaN, ...
    "outbound_samples",NaN,"double_spiral_samples",NaN, ...
    "cycle_duration_ms",NaN,"cycle_rate_hz",NaN, ...
    "complete_cycles_during_pulse",NaN,"cycles_started_during_pulse",NaN, ...
    "fractional_cycles_during_pulse",NaN);
if isempty(scannerTransform) || is_identity(scannerTransform), return; end
try
    centerV=adaptive_optopatch.camera_to_galvo_volts(scannerTransform,centerXY);
    edgeV=adaptive_optopatch.camera_to_galvo_volts( ...
        scannerTransform,centerXY+[radiusPixels 0;0 radiusPixels; ...
        -radiusPixels 0;0 -radiusPixels]);
catch
    return
end
if any([centerV;edgeV]<options.CommandBoundsV(1) | ...
        [centerV;edgeV]>options.CommandBoundsV(2),"all")
    return
end
radiusV=max(vecnorm(edgeV-centerV,2,2));
if ~isfinite(radiusV) || radiusV<=0, return; end
nOutbound=max(2,round(pi*radiusV^2*densityPointsPerVolt^2));
nCycle=2*nOutbound-1;
cycleDurationS=nCycle/options.ScannerSampleRateHz;
pulseDurationS=pulseDurationMs/1000;
metrics.calibrated=true;
metrics.scanner_radius_volts=radiusV;
metrics.outbound_samples=nOutbound;
metrics.double_spiral_samples=nCycle;
metrics.cycle_duration_ms=1000*cycleDurationS;
metrics.cycle_rate_hz=1/cycleDurationS;
metrics.complete_cycles_during_pulse=floor(pulseDurationS/cycleDurationS);
metrics.cycles_started_during_pulse=ceil(pulseDurationS/cycleDurationS);
metrics.fractional_cycles_during_pulse=pulseDurationS/cycleDurationS;
end

function tf=is_identity(tform)
if isa(tform,"affinetform2d") || isa(tform,"projtform2d")
    matrix=tform.A;
elseif isa(tform,"affine2d") || isa(tform,"projective2d")
    matrix=tform.T';
else
    tf=false;
    return
end
tf=norm(matrix-eye(3),"fro")<1e-9;
end
