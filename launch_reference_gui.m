function app = launch_reference_gui(luminosApp)
%LAUNCH_REFERENCE_GUI Open the Adaptive Optopatch reference-preparation GUI.
arguments
    luminosApp = []
end
root = fileparts(mfilename("fullpath"));
addpath(root);
if ~isempty(luminosApp)
    try
        status=adaptive_optopatch.load_active_galvo_calibration(luminosApp);
        if status.found, fprintf('%s\n',status.message); end
    catch exception
        warning("adaptive_optopatch:ActiveCalibrationNotApplied", ...
            "Active galvo calibration was not applied: %s",exception.message);
    end
end
app = adaptive_optopatch.ReferencePreparationApp("LuminosApp",luminosApp);
end
