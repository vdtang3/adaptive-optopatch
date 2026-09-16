classdef LuminosSessionStub < handle
    %LUMINOSSESSIONSTUB Minimal stand-in for Luminos's shared-controller hook.
    %   Rig_Control_App cannot be constructed on Linux - it needs the Windows
    %   MEX stack, NI-DAQ and the Instrument Control Toolbox - so the tests use
    %   this in its place. It implements exactly the one method Adaptive
    %   Optopatch actually depends on, with the same contract Luminos's
    %   getAdaptiveOptopatchController documents:
    %
    %     - lazy: nothing is built until somebody asks
    %     - the SAME handle is returned to every later caller
    %     - empty when this session does not support Adaptive Optopatch
    %     - no StateChangedFcn is installed, so a view can own the callback
    %
    %   A test helper, deliberately not production code: nothing under
    %   +adaptive_optopatch knows it exists.

    properties
        %SUPPORTSADAPTIVEOPTOPATCH False stands for a Luminos session where
        %   adaptive-optopatch is not on the MATLAB path.
        SupportsAdaptiveOptopatch (1,1) logical = true
        %CONSTRUCTIONCOUNT How many controllers this session has built, which
        %   is the thing repeated polling must not increase.
        ConstructionCount (1,1) double = 0
    end

    properties (Access=private)
        OwnedController = []
    end

    methods
        function controller = getAdaptiveOptopatchController(session)
            controller = session.OwnedController;
            if ~isempty(controller) && isvalid(controller)
                return
            end
            if ~session.SupportsAdaptiveOptopatch
                controller = [];
                return
            end
            controller = adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp", session);
            session.ConstructionCount = session.ConstructionCount + 1;
            session.OwnedController = controller;
        end
    end
end
