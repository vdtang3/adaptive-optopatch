function volts=camera_to_galvo_volts(tform,cameraXY)
%CAMERA_TO_GALVO_VOLTS Invert Luminos's scanner-volts-to-camera transform.
arguments
    tform
    cameraXY (:,2) double
end
if isempty(tform)
    error("adaptive_optopatch:MissingScannerTransform", ...
        "A Luminos scanner calibration transform is required.");
end
try
    [vx,vy]=transformPointsInverse(tform,cameraXY(:,1),cameraXY(:,2));
catch exception
    error("adaptive_optopatch:InvalidScannerTransform", ...
        "Could not invert the Luminos scanner transform: %s",exception.message);
end
volts=[double(vx(:)) double(vy(:))];
if any(~isfinite(volts),"all")
    error("adaptive_optopatch:InvalidScannerTransform", ...
        "The camera-to-galvo transformation produced nonfinite values.");
end
end
