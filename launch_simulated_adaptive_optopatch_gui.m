function [app,sim]=launch_simulated_adaptive_optopatch_gui(options)
%LAUNCH_SIMULATED_ADAPTIVE_OPTOPATCH_GUI Open the unified app without hardware.
arguments
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
    options.RunRoot (1,1) string = ""
    options.CameraFrameRateHz (1,1) double {mustBePositive} = 1000
    options.LaserPowerMw (1,1) double {mustBeNonnegative} = 10
    options.SimulationOutputRoot (1,1) string = ""
end
sim=simulatedLuminosApp( ...
    "CameraFrameRateHz",options.CameraFrameRateHz, ...
    "LaserPowerMw",options.LaserPowerMw, ...
    "SimulationOutputRoot",options.SimulationOutputRoot);
app=launch_adaptive_optopatch_gui(sim, ...
    "Visible",options.Visible,"RunRoot",options.RunRoot);
end
