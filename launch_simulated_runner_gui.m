function [gui,sim]=launch_simulated_runner_gui(bundleFolder,options)
%LAUNCH_SIMULATED_RUNNER_GUI Select the real 1P or 2P GUI from its manifest.
arguments
    bundleFolder (1,1) string
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
    options.CameraFrameRateHz (1,1) double {mustBePositive} = 1000
    options.LaserPowerMw (1,1) double {mustBeNonnegative} = 10
    options.SimulationOutputRoot (1,1) string = ""
end
manifestPath=fullfile(bundleFolder,"trial_manifest.mat");
if ~isfile(manifestPath)
    error("adaptive_optopatch:InvalidPlanningBundle", ...
        "The folder does not contain trial_manifest.mat.");
end
saved=load(manifestPath,"manifest");
if ~isfield(saved,"manifest") || ~isfield(saved.manifest,"trials") || ...
        isempty(saved.manifest.trials)
    error("adaptive_optopatch:InvalidPlanningBundle", ...
        "trial_manifest.mat does not contain a nonempty manifest.trials table.");
end
modes=unique(string(saved.manifest.trials.stimulation_mode));
if ~isscalar(modes)
    error("adaptive_optopatch:MixedRunnerModes", ...
        "A simulated runner requires one stimulation mode per manifest.");
end
common={"Visible",options.Visible, ...
    "CameraFrameRateHz",options.CameraFrameRateHz, ...
    "SimulationOutputRoot",options.SimulationOutputRoot};
if modes=="1p_dmd"
    [gui,sim]=launch_simulated_1p_runner_gui(bundleFolder,common{:}, ...
        "LaserPowerMw",options.LaserPowerMw);
elseif modes=="2p_spiral"
    [gui,sim]=launch_simulated_2p_test_runner_gui(bundleFolder,common{:});
else
    error("adaptive_optopatch:UnknownMode", ...
        "Unsupported manifest stimulation mode: %s",modes);
end
end
