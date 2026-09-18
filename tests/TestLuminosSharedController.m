classdef TestLuminosSharedController < matlab.unittest.TestCase
    %TESTLUMINOSSHAREDCONTROLLER One controller, two frontends.
    %   A Luminos session owns one AdaptiveOptopatchController; the MATLAB
    %   planning GUI and the React Adaptive Optopatch tab are both views of it.
    %   These tests pin the parts of that arrangement Adaptive Optopatch is
    %   responsible for: that the GUI will attach to a controller it is given,
    %   that it still builds its own when it is not, and that a polling client
    %   keeps working whether or not a GUI currently owns StateChangedFcn.
    %
    %   Luminos's half of the arrangement - Rig_Control_App's accessor and the
    %   get_adaptive_optopatch_state_js endpoint - is stood in for by
    %   LuminosSessionStub, because Rig_Control_App cannot be constructed on
    %   Linux. What that stub cannot prove is verified on the rig; see the
    %   Phase 1B validation notes.

    methods (Test)
        % ---------------------------------------------------------------
        % Shared ownership
        % ---------------------------------------------------------------
        function aSessionHandsTheSameControllerToEveryClient(testCase)
            session = LuminosSessionStub();

            first = session.getAdaptiveOptopatchController();
            second = session.getAdaptiveOptopatchController();

            testCase.verifySameHandle(first, second);
            testCase.verifyEqual(session.ConstructionCount, 1, ...
                "Asking again must not build a second controller.");
        end

        function repeatedPollingNeverBuildsAnotherController(testCase)
            session = LuminosSessionStub();

            % What a second of interface polling looks like from here.
            for k = 1:20
                state = session.getAdaptiveOptopatchController().getState();
            end

            testCase.verifyEqual(session.ConstructionCount, 1);
            testCase.verifyEqual(state.revision, 0, ...
                "Reading state must not change it.");
        end

        function readingStateChangesNothing(testCase)
            controller = LuminosSessionStub().getAdaptiveOptopatchController();

            before = controller.getState();
            controller.getState();
            after = controller.getState();

            testCase.verifyEqual(after.revision, before.revision);
            testCase.verifyEqual(after.lifecycle, before.lifecycle);
            testCase.verifyEqual(after.plan_state, before.plan_state);
            testCase.verifyEqual(after.legal_actions, before.legal_actions);
        end

        function aSessionWithoutAdaptiveOptopatchReportsAbsenceNotFailure(testCase)
            session = LuminosSessionStub();
            session.SupportsAdaptiveOptopatch = false;

            controller = session.getAdaptiveOptopatchController();

            % Empty is what the endpoint turns into the null the tab already
            % renders as "no Adaptive Optopatch controller". It must not throw:
            % a rig without the package is a normal configuration, not a fault.
            testCase.verifyEmpty(controller);
            testCase.verifyEqual(session.ConstructionCount, 0);
        end

        function buildingAControllerOpensNoFigure(testCase)
            before = findall(groot, "Type", "figure");

            session = LuminosSessionStub();
            session.getAdaptiveOptopatchController().getState();

            testCase.verifyEqual(findall(groot, "Type", "figure"), before, ...
                "Owning AO state must never put a window on the rig's screen.");
        end

        % ---------------------------------------------------------------
        % StateChangedFcn and multiple clients
        % ---------------------------------------------------------------
        function aSessionInstallsNoStateChangedCallback(testCase)
            controller = LuminosSessionStub().getAdaptiveOptopatchController();

            % StateChangedFcn is one property, not a listener list, so whoever
            % assigns last owns it. Luminos must leave it alone or opening the
            % planning GUI would silently stop refreshing it.
            testCase.verifyEmpty(controller.StateChangedFcn);
        end

        function pollingWorksWhicheverViewOwnsTheCallback(testCase)
            session = LuminosSessionStub();
            controller = session.getAdaptiveOptopatchController();
            poll = @() session.getAdaptiveOptopatchController().getState();

            % 1. Nobody is watching: polling is the only client.
            testCase.verifyEmpty(controller.StateChangedFcn);
            testCase.verifyEqual(poll().revision, controller.Revision);

            % 2. The planning GUI attaches and takes the callback.
            app = testCase.attachedGui(controller);
            testCase.verifyClass(controller.StateChangedFcn, "function_handle");
            testCase.verifyEqual(poll().revision, controller.Revision);

            % 3. A change reaches both: the GUI through its callback, the
            %    polling client through the revision it reads next.
            before = poll().revision;
            controller.setStatus("changed from the controller");
            testCase.verifyGreaterThan(poll().revision, before);
            testCase.verifyEqual(poll().status, controller.statusText());

            % 4. The GUI goes away. It releases the callback and leaves the
            %    controller alone, so the polling client never notices.
            delete(app);
            testCase.verifyTrue(isvalid(controller));
            testCase.verifyEmpty(controller.StateChangedFcn);
            testCase.verifyEqual(poll().revision, controller.Revision);
        end

        % ---------------------------------------------------------------
        % The GUI as a client
        % ---------------------------------------------------------------
        function anInjectedControllerIsUsedRatherThanANewOne(testCase)
            session = LuminosSessionStub();
            shared = session.getAdaptiveOptopatchController();
            shared.setStatus("state that already existed");

            app = testCase.attachedGui(shared);

            testCase.verifySameHandle(app.Controller, shared);
            testCase.verifyEqual(session.ConstructionCount, 1, ...
                "Opening the GUI must not build a second controller.");
            testCase.verifyEqual(app.Controller.getState().status, ...
                shared.statusText(), ...
                "The GUI must show the state it was handed.");
        end

        function standaloneStillBuildsItsOwnController(testCase)
            app = testCase.newGui(simulatedLuminosApp());

            testCase.verifyNotEmpty(app.Controller);
            testCase.verifyClass(app.Controller, ...
                "adaptive_optopatch.AdaptiveOptopatchController");
            testCase.verifyEqual(app.Controller.LifecycleState, "EDITABLE");
        end

        function theLauncherAttachesToASessionThatOwnsAController(testCase)
            session = LuminosSessionStub();
            shared = session.getAdaptiveOptopatchController();

            app = launch_adaptive_optopatch_gui(session, "Visible", "off");
            testCase.addTeardown(@() delete(app));

            testCase.verifySameHandle(app.Controller, shared);
            testCase.verifyEqual(session.ConstructionCount, 1);
        end

        function theLauncherBuildsItsOwnWhenTheSessionOwnsNone(testCase)
            % The simulated backend has no ownership hook at all, which is also
            % what a Luminos predating this looks like. Both must still work.
            simulator = simulatedLuminosApp();

            app = launch_adaptive_optopatch_gui(simulator, "Visible", "off");
            testCase.addTeardown(@() delete(app));

            testCase.verifyNotEmpty(app.Controller);
            testCase.verifyEqual(app.Controller.LifecycleState, "EDITABLE");
        end

        function openingTheGuiDoesNotWipeASharedRunRoot(testCase)
            session = LuminosSessionStub();
            shared = session.getAdaptiveOptopatchController();
            shared.RunRoot = "/somewhere/the/session/already/chose";

            app = testCase.attachedGui(shared);

            % The GUI used to assign RunRoot unconditionally, which is harmless
            % for a controller it just built - a new one's is already "" - but
            % wiped one the session had set.
            testCase.verifyEqual(app.Controller.RunRoot, ...
                "/somewhere/the/session/already/chose");
        end

        function anExplicitRunRootStillWins(testCase)
            shared = LuminosSessionStub().getAdaptiveOptopatchController();
            shared.RunRoot = "/the/session/choice";

            app = adaptive_optopatch.AdaptiveOptopatchApp( ...
                "Visible", "off", "Controller", shared, ...
                "RunRoot", "/the/caller/choice");
            testCase.addTeardown(@() delete(app));

            testCase.verifyEqual(app.Controller.RunRoot, "/the/caller/choice");
        end

        % ---------------------------------------------------------------
        % What crosses the wire
        % ---------------------------------------------------------------
        function stateSurvivesTheJsonEncodingJsServerUses(testCase)
            controller = LuminosSessionStub().getAdaptiveOptopatchController();

            testCase.verifyJsonSafe(controller.getState());
        end

        function aLoadedSessionAlsoSurvivesIt(testCase)
            controller = testCase.loadedController();

            state = controller.getState();
            decoded = testCase.verifyJsonSafe(state);

            % The fields the tab reads, through the encoder that actually
            % carries them.
            testCase.verifyEqual(string(decoded.lifecycle), "frozen");
            testCase.verifyEqual(string(decoded.plan_state), "FROZEN");
            testCase.verifyTrue(decoded.fov.loaded);
            testCase.verifyEqual(numel(decoded.cells), 2);
            testCase.verifyTrue(decoded.protocol.loaded);
            testCase.verifyTrue(decoded.active_run.frozen);
        end

        function absentNumbersCrossTheWireAsNullNotZero(testCase)
            controller = testCase.loadedController();

            decoded = jsondecode(jsonencode(controller.getState()));

            % cell_002 has no stored 1P calibration, so its blue voltage is
            % NaN. jsonencode writes null and jsondecode reads it back empty -
            % which is what the browser turns into null rather than a real
            % measurement of zero volts.
            testCase.verifyEmpty(decoded.cells(2).selected_blue_voltage_v);
            testCase.verifyEqual(decoded.cells(1).selected_blue_voltage_v, 1.4);
        end

        function stateCarriesNoTablesOrObjects(testCase)
            % activeRunSummary reads the frozen trial table to count progress,
            % and must report numbers rather than hand the table over: a table
            % does not survive this channel in any useful shape.
            testCase.verifyNoTablesOrObjects( ...
                testCase.loadedController().getState(), "state");
        end
    end

    methods (Access=private)
        function app = newGui(testCase, luminosApp)
            app = adaptive_optopatch.AdaptiveOptopatchApp( ...
                "LuminosApp", luminosApp, "Visible", "off");
            testCase.addTeardown(@() delete(app));
        end

        function app = attachedGui(testCase, controller)
            app = adaptive_optopatch.AdaptiveOptopatchApp( ...
                "Visible", "off", "Controller", controller);
            testCase.addTeardown(@() delete(app));
        end

        function controller = loadedController(testCase)
            root = tempname; mkdir(root);
            testCase.addTeardown(@() remove_if_present(root));

            controller = adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp", simulatedLuminosApp("CameraRoi", [974 100 984 80]), ...
                "RunRoot", string(root));
            controller.setReferenceData(ones(80, 100), reference_info(root), ...
                {[25 25; 40 25; 40 40; 25 40], [60 40; 75 40; 75 55; 60 55]});
            controller.setCellCalibration("cell_001", 1.4, "test");
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount", 1, "ModulatorVoltage", 1));
            controller.setPlanParameter("mode", "1p_dmd");
            controller.freezeRun();
        end

        function decoded = verifyJsonSafe(testCase, state)
            encoded = "";
            testCase.verifyWarningFree(@() assign_encoded());
            decoded = jsondecode(encoded);

            for field = ["schema_version", "revision", "lifecycle", ...
                    "plan_state", "editable_state_changed", ...
                    "stop_after_current_requested", "status", "fov", ...
                    "cells", "soma_polygons", "protocol", "plan_parameters", ...
                    "active_run", "legal_actions"]
                testCase.verifyTrue(isfield(decoded, field), ...
                    sprintf("The encoded state is missing %s.", field));
            end

            function assign_encoded()
                encoded = jsonencode(state);
            end
        end

        function verifyNoTablesOrObjects(testCase, value, path)
            testCase.verifyFalse(istable(value), ...
                sprintf("%s is a table.", path));
            testCase.verifyFalse(isobject(value) && ~isstring(value), ...
                sprintf("%s is an object.", path));
            if isstruct(value)
                for name = string(fieldnames(value))'
                    for k = 1:numel(value)
                        testCase.verifyNoTablesOrObjects(value(k).(name), ...
                            path + "." + name);
                    end
                end
                return
            end
            if iscell(value)
                for k = 1:numel(value)
                    testCase.verifyNoTablesOrObjects(value{k}, ...
                        sprintf("%s{%d}", path, k));
                end
            end
        end
    end
end

function info = reference_info(root)
camera = struct("name", "Orca Fusion", "ROI", [0 0 100 80], "bin", 1, ...
    "x_world_limits", [974 1074], "y_world_limits", [984 1064]);
info = struct("snapshot_name", "shared_controller_test", ...
    "snapshot_directory", string(root), ...
    "snapshot_path", string(fullfile(root, "snapshot.mat")), ...
    "metadata", struct("rig_name", "Virtual_Upright", "voltage_camera", camera));
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder, "s"); end
end
