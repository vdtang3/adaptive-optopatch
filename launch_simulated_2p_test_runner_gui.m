function [gui,sim]=launch_simulated_2p_test_runner_gui(bundleFolder,options)
%LAUNCH_SIMULATED_2P_TEST_RUNNER_GUI Open the real 2P GUI with no hardware.
arguments
    bundleFolder (1,1) string
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
    options.CameraFrameRateHz (1,1) double {mustBePositive} = 1000
    options.SimulationOutputRoot (1,1) string = ""
end
root=fileparts(mfilename("fullpath")); addpath(root);
outputRoot=options.SimulationOutputRoot;
if strlength(outputRoot)==0
    outputRoot=fullfile(bundleFolder,"simulation_runs");
end
sim=adaptive_optopatch.testing.make_simulated_luminos( ...
    "CameraFrameRateHz",options.CameraFrameRateHz, ...
    "SimulationOutputRoot",outputRoot);
gui=adaptive_optopatch.TwoPhotonTestRunnerApp( ...
    sim,bundleFolder,"Visible",options.Visible);
end
