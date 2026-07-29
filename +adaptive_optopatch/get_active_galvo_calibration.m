function [artifact,status]=get_active_galvo_calibration(options)
%GET_ACTIVE_GALVO_CALIBRATION Read the active pointer without applying it.
arguments
    options.StoreRoot (1,1) string = ""
end
root=adaptive_optopatch.galvo_calibration_store_root("Root",options.StoreRoot);
pointerPath=fullfile(root,"active_galvo_calibration.mat");
artifact=struct([]);
status=struct("found",false,"store_root",root,"pointer_path",pointerPath, ...
    "artifact_path","","message","No active galvo calibration pointer was found.");
if ~isfile(pointerPath), return; end
loaded=load(pointerPath,"active_galvo_calibration");
if ~isfield(loaded,"active_galvo_calibration")
    error("adaptive_optopatch:InvalidCalibrationPointer", ...
        "The active calibration pointer is malformed.");
end
pointer=loaded.active_galvo_calibration;
artifactPath=fullfile(root,string(pointer.artifact_filename));
if ~isfile(artifactPath)
    error("adaptive_optopatch:MissingCalibrationArtifact", ...
        "Active calibration artifact not found: %s",artifactPath);
end
loaded=load(artifactPath,"galvo_calibration_artifact");
if ~isfield(loaded,"galvo_calibration_artifact")
    error("adaptive_optopatch:InvalidCalibrationArtifact", ...
        "The active calibration artifact is malformed.");
end
artifact=loaded.galvo_calibration_artifact;
status.found=true; status.artifact_path=artifactPath;
status.message="Active galvo calibration "+string(artifact.calibration_id)+" found.";
end
