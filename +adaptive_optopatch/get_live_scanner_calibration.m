function [calibration,warningMessage] = get_live_scanner_calibration(luminosApp, options)
%GET_LIVE_SCANNER_CALIBRATION Read the active scanner calibration from Luminos.
arguments
    luminosApp = []
    options.ScannerName (1,1) string = "Chameleon (To friends: Ben)"
end
calibration=struct([]);
warningMessage="";
if isempty(luminosApp)
    warningMessage="Live Luminos app was not supplied; exact spirals per pulse "+ ...
        "require launch_reference_gui(luminosApp).";
    return
end
try
    scanner=luminosApp.getDevice("Scanning_Device","name",options.ScannerName);
catch exception
    warningMessage="Could not query the live Luminos scanner: "+string(exception.message);
    return
end
if isempty(scanner)
    warningMessage="The live Luminos session does not contain scanner '"+ ...
        options.ScannerName+"'.";
    return
end
if numel(scanner)~=1
    warningMessage="The live Luminos scanner lookup did not return exactly one device.";
    return
end
try
    tform=scanner.tform;
catch
    tform=[];
end
if isempty(tform)
    warningMessage="The live scanner does not have a calibration transform.";
    return
end
if is_identity_transform(tform)
    warningMessage="The live scanner transform is identity; calibrate the scanner in Luminos.";
    return
end
try
    sampleRate=double(scanner.sample_rate);
catch
    sampleRate=NaN;
end
if ~isscalar(sampleRate) || ~isfinite(sampleRate) || sampleRate<=0
    warningMessage="The live scanner sample rate is missing or invalid.";
    return
end
calibration=struct("name",string(scanner.name),"device_type","Scanning_Device", ...
    "tform",tform,"sample_rate",sampleRate,"source","live_luminos", ...
    "transform_direction","galvo_volts_to_camera_pixels");
try
    calibration.vbounds=scanner.vbounds;
catch
    calibration.vbounds=[];
end
try
    calibration.points_per_volt=scanner.Points_Per_Volt;
catch
    calibration.points_per_volt=[];
end
end

function tf=is_identity_transform(tform)
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
