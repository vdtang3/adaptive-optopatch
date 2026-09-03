function app=launch_adaptive_optopatch_gui(luminosApp,options)
%LAUNCH_ADAPTIVE_OPTOPATCH_GUI Open the unified planning and runner app.
arguments
    luminosApp
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
    options.RunRoot (1,1) string = ""
end
root=fileparts(mfilename("fullpath")); addpath(root);
app=adaptive_optopatch.AdaptiveOptopatchApp( ...
    "LuminosApp",luminosApp,"Visible",options.Visible, ...
    "RunRoot",options.RunRoot);
end
