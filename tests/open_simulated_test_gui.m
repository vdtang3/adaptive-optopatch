function [app,luminosApp]=open_simulated_test_gui(options)
%OPEN_SIMULATED_TEST_GUI Compose the supported simulator and GUI in tests.
arguments
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "off"
    options.RunRoot (1,1) string = ""
    options.CameraRoi (1,4) double = [0 2048 0 2048]
    options.CameraBin (1,1) double {mustBePositive} = 1
    options.CameraFrameRateHz (1,1) double {mustBePositive} = 1000
    options.LaserPowerMw (1,1) double {mustBeNonnegative} = 10
    options.SimulationOutputRoot (1,1) string = ""
end
luminosApp=simulatedLuminosApp( ...
    "CameraRoi",options.CameraRoi,"CameraBin",options.CameraBin, ...
    "CameraFrameRateHz",options.CameraFrameRateHz, ...
    "LaserPowerMw",options.LaserPowerMw, ...
    "SimulationOutputRoot",options.SimulationOutputRoot);
app=launch_adaptive_optopatch_gui(luminosApp, ...
    "Visible",options.Visible,"RunRoot",options.RunRoot);
end
