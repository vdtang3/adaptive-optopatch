function status=load_active_galvo_calibration(app,options)
%LOAD_ACTIVE_GALVO_CALIBRATION Validate and apply the persisted calibration.
arguments
    app
    options.StoreRoot (1,1) string = ""
    options.Apply (1,1) logical = true
end
[artifact,status]=adaptive_optopatch.get_active_galvo_calibration( ...
    "StoreRoot",options.StoreRoot);
status.applied=false; status.validation=struct([]);
if ~status.found, return; end
validation=adaptive_optopatch.validate_galvo_calibration_artifact(artifact,app);
status.validation=validation;
if ~validation.passed
    error("adaptive_optopatch:ActiveCalibrationRejected","%s", ...
        strjoin(validation.issues,newline));
end
if options.Apply
    scanner=app.getDevice("Scanning_Device","name",artifact.scanner_name);
    scanner.tform=artifact.calibration.tform;
    status.applied=true;
    status.message="Applied active galvo calibration "+artifact.calibration_id+".";
end
status.calibration_id=artifact.calibration_id;
status.artifact=artifact;
end
