function gui=launch_2p_test_runner_gui(luminosApp,bundleFolder,options)
%LAUNCH_2P_TEST_RUNNER_GUI Open the staged blocked/attenuated 2P runner.
arguments
    luminosApp
    bundleFolder (1,1) string = ""
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
end
gui=adaptive_optopatch.TwoPhotonTestRunnerApp( ...
    luminosApp,bundleFolder,"Visible",options.Visible);
end
