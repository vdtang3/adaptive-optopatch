function gui = launch_1p_runner_gui(luminosApp,bundleFolder)
%LAUNCH_1P_RUNNER_GUI Open the automated DMD_Blue acquisition runner.
arguments
    luminosApp
    bundleFolder (1,1) string = ""
end
root=fileparts(mfilename("fullpath")); addpath(root);
gui=adaptive_optopatch.OnePhotonRunnerApp(luminosApp,bundleFolder);
end
