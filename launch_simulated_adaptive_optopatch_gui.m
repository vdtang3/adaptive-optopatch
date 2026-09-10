function [app,sim]=launch_simulated_adaptive_optopatch_gui(options)
%LAUNCH_SIMULATED_ADAPTIVE_OPTOPATCH_GUI Open the unified app without hardware.
arguments
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
    options.RunRoot (1,1) string = ""
    options.CameraFrameRateHz (1,1) double {mustBePositive} = 1000
    options.LaserPowerMw (1,1) double {mustBeNonnegative} = 10
    options.SimulationOutputRoot (1,1) string = ""
    % The simulated Camera 1 acquisition grid. Planning starts from a
    % reference image the simulator cannot produce, so state the grid that
    % image represents; the runners then apply the real camera-geometry
    % invariant against it.
    options.CameraRoi (1,4) double = [0 2048 0 2048]
    options.CameraBin (1,1) double {mustBePositive} = 1
end
sim=simulatedLuminosApp( ...
    "CameraFrameRateHz",options.CameraFrameRateHz, ...
    "LaserPowerMw",options.LaserPowerMw, ...
    "SimulationOutputRoot",options.SimulationOutputRoot, ...
    "CameraRoi",options.CameraRoi,"CameraBin",options.CameraBin);
app=launch_adaptive_optopatch_gui(sim, ...
    "Visible",options.Visible,"RunRoot",options.RunRoot);
end
