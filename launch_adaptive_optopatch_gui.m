function app=launch_adaptive_optopatch_gui(luminosApp,options)
%LAUNCH_ADAPTIVE_OPTOPATCH_GUI Open the unified planning and runner app.
%   When the Luminos session already owns an Adaptive Optopatch controller,
%   this attaches to it rather than building a second one, so the GUI and the
%   interface's Adaptive Optopatch tab show the same session. Pass Controller
%   to name one explicitly; pass an empty luminosApp, or one that owns no
%   controller, and the app builds its own exactly as before.
arguments
    luminosApp
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
    options.RunRoot (1,1) string = ""
    options.Controller = []
end
root=fileparts(mfilename("fullpath")); addpath(root);
controller=options.Controller;
if isempty(controller)
    controller=shared_controller_from(luminosApp);
end
app=adaptive_optopatch.AdaptiveOptopatchApp( ...
    "LuminosApp",luminosApp,"Visible",options.Visible, ...
    "RunRoot",options.RunRoot,"Controller",controller);
end

function controller=shared_controller_from(luminosApp)
%SHARED_CONTROLLER_FROM The Luminos session's controller, if it owns one.
%   Duck-typed on purpose. A Luminos old enough to predate shared ownership,
%   and the simulated backend the tests use, simply do not have the method, and
%   both must keep working - so this asks rather than requiring.
controller=[];
if isempty(luminosApp) || ...
        ~ismethod(luminosApp,"getAdaptiveOptopatchController")
    return
end
controller=luminosApp.getAdaptiveOptopatchController();
end
