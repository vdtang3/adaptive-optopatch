function gui=launch_galvo_calibration_gui(luminosApp,options)
%LAUNCH_GALVO_CALIBRATION_GUI Open the Camera 1 / galvo calibration tool.
arguments
    luminosApp
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
end
gui=adaptive_optopatch.GalvoCalibrationApp(luminosApp, ...
    "Visible",options.Visible);
end
