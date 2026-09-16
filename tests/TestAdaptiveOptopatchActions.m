classdef TestAdaptiveOptopatchActions < matlab.unittest.TestCase
    %TESTADAPTIVEOPTOPATCHACTIONS The write surface a non-MATLAB frontend has.
    %   adaptive_optopatch.apply_controller_action is the production dispatch
    %   the Luminos endpoint adaptive_optopatch_action_js calls. Every test
    %   here goes through it rather than through the controller directly,
    %   because the thing under test is the CONTRACT: what a browser may ask
    %   for, what it may not, what happens when it asks with a stale view of
    %   the session, and what comes back.
    %
    %   Luminos's half - Rig_Control_App's accessor and the endpoint file - is
    %   not exercised here: Rig_Control_App cannot be constructed on Linux.
    %   That endpoint is three lines of resolve-and-delegate for exactly this
    %   reason; what it delegates to is all of this.
    %
    %   Nothing here drives hardware. runNext and runAll are recorded by
    %   ControllerCallRecorder and not executed.

    methods (Test)
        % ---------------------------------------------------------------
        % The allowlist is a list, not a bridge
        % ---------------------------------------------------------------
        function anUnknownActionIsRefusedAndChangesNothing(testCase)
            controller = testCase.emptyController();
            before = controller.getState();

            response = testCase.act(controller, "polish_the_objective");

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.status, "unknown_action");
            testCase.verifyEqual(response.state, before);
        end

        function aRealControllerMethodIsStillNotAnAction(testCase)
            % The failure this guards against is a dispatcher that reaches
            % controller.(action): every one of these is a genuine public
            % method, and none of them is offered.
            controller = testCase.loadedController();

            for name = ["clearSomata", "setCellBlueVoltage", "delete", ...
                    "setStatus", "loadSnapshot", "saveFov", "resumeRun", ...
                    "sendOrangeRecordingMask", "buildPlan"]
                response = testCase.act(controller, name);
                testCase.verifyEqual(response.status, "unknown_action", ...
                    sprintf("%s must not be reachable as an action.", name));
            end
        end

        function everyAllowlistedActionIsImplemented(testCase)
            % A name added to the allowlist and not wired up would otherwise
            % report success while doing nothing. Asking for each one with no
            % payload proves the switch has a branch for it: a missing branch
            % raises UnhandledAction, which classifies as validation_error
            % only because it is an adaptive_optopatch identifier - so the
            % identifier itself is what is checked.
            controller = testCase.emptyController();

            for action = testCase.allowlistedActions()
                response = testCase.act(controller, action);
                testCase.verifyNotEqual(response.identifier, ...
                    "adaptive_optopatch:UnhandledAction", ...
                    sprintf("%s is allowlisted but has no branch.", action));
                testCase.verifyNotEqual(response.status, "unknown_action", ...
                    sprintf("%s is allowlisted but was not recognised.", action));
            end
        end

        % ---------------------------------------------------------------
        % A. Cell eligibility
        % ---------------------------------------------------------------
        function eligibilityIsChangedThroughTheController(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "set_cell_eligibility", ...
                struct("cell_id", "cell_002", "stimulation_enabled", false));

            testCase.verifyTrue(response.ok);
            testCase.verifyEqual(response.status, "applied");
            testCase.verifyTrue(any(controller.Calls == "setCellEligibility"));
            testCase.verifyFalse(response.state.cells(2).stimulation_enabled);
            % Independent eligibilities: switching one must not move the other.
            testCase.verifyTrue(response.state.cells(2).recording_enabled);
        end

        function anOmittedEligibilityFlagLeavesThatDecisionAlone(testCase)
            controller = testCase.loadedController();
            testCase.act(controller, "set_cell_eligibility", ...
                struct("cell_id", "cell_001", "recording_enabled", false));

            response = testCase.act(controller, "set_cell_eligibility", ...
                struct("cell_id", "cell_001", "stimulation_enabled", false));

            testCase.verifyFalse(response.state.cells(1).recording_enabled);
            testCase.verifyFalse(response.state.cells(1).stimulation_enabled);
        end

        function anUnknownCellIsAValidationError(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "set_cell_eligibility", ...
                struct("cell_id", "cell_404", "recording_enabled", false));

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.status, "validation_error");
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:UnknownCellId");
        end

        % ---------------------------------------------------------------
        % F, G, H. Soma geometry
        % ---------------------------------------------------------------
        function aDrawnSomaBecomesACanonicalCell(testCase)
            controller = testCase.emptyControllerWithReference();
            vertices = [10 12; 24 12; 24 27; 10 27];

            response = testCase.act(controller, "add_soma", ...
                struct("vertices_xy", vertices));

            testCase.verifyTrue(response.ok);
            testCase.verifyTrue(any(controller.Calls == "addSomaPolygon"));
            testCase.verifyEqual(numel(response.state.cells), 1);
            % The identity is MATLAB's. Nothing in the request named it.
            testCase.verifyEqual(response.state.cells(1).cell_id, "cell_001");
        end

        function drawnVerticesAreStoredExactlyAsSent(testCase)
            % The coordinate contract: vertices_xy is snapshot-intrinsic
            % pixels, and nothing between the request and canonical geometry
            % rescales, rounds, flips or reorders them.
            controller = testCase.emptyControllerWithReference();
            vertices = [10.25 12.5; 24 12.5; 24 27.75; 10.25 27.75];

            response = testCase.act(controller, "add_soma", ...
                struct("vertices_xy", vertices));

            testCase.verifyEqual(response.state.soma_polygons{1}, vertices);
        end

        function anEditedSomaKeepsItsIdentity(testCase)
            controller = testCase.loadedController();
            moved = [30 30; 45 30; 45 45; 30 45];

            response = testCase.act(controller, "update_soma", ...
                struct("cell_id", "cell_001", "vertices_xy", moved));

            testCase.verifyTrue(response.ok);
            testCase.verifyTrue(any(controller.Calls == "updateSomaPolygon"));
            testCase.verifyEqual(response.state.cells(1).cell_id, "cell_001");
            testCase.verifyEqual(response.state.soma_polygons{1}, moved);
        end

        function aDeletedSomaDoesNotRenumberTheOthers(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "delete_soma", ...
                struct("cell_id", "cell_001"));

            testCase.verifyTrue(response.ok);
            testCase.verifyTrue(any(controller.Calls == "deleteCell"));
            testCase.verifyEqual(numel(response.state.cells), 1);
            testCase.verifyEqual(response.state.cells(1).cell_id, "cell_002", ...
                "The surviving cell must keep the identity it had.");
            testCase.verifyEqual(response.state.fov.next_cell_index, 3, ...
                "A deleted identity is retired, never recycled.");
        end

        function aDegeneratePolygonIsRefusedByTheController(testCase)
            controller = testCase.emptyControllerWithReference();

            response = testCase.act(controller, "add_soma", ...
                struct("vertices_xy", [10 10; 20 20]));

            testCase.verifyEqual(response.status, "validation_error");
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:InvalidCanonicalRoi");
            testCase.verifyEmpty(response.state.cells);
        end

        function aMalformedVertexListIsRefusedBeforeTheController(testCase)
            controller = testCase.emptyControllerWithReference();

            response = testCase.act(controller, "add_soma", ...
                struct("vertices_xy", [1 2 3; 4 5 6]));

            testCase.verifyEqual(response.status, "validation_error");
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:InvalidActionArgument");
            testCase.verifyEmpty(controller.Calls);
        end

        % ---------------------------------------------------------------
        % B. Protocol discovery and selection
        % ---------------------------------------------------------------
        function protocolsAreOfferedByIdentityNotByPath(testCase)
            controller = testCase.emptyController();
            controller.ProtocolRoot = testCase.protocolFolder();

            choices = controller.protocolChoices();

            testCase.verifyEqual(numel(choices), 2);
            testCase.verifyEqual(sort([choices.choice_id]), ...
                ["screen_a", "screen_b"]);
            testCase.verifyTrue(all([choices.loadable]));
            testCase.verifyFalse(any([choices.is_current]));
        end

        function anUnreadableFileIsListedAsUnloadableNotHidden(testCase)
            folder = testCase.protocolFolder();
            fid = fopen(fullfile(folder, "not_a_protocol.mat"), "w");
            fprintf(fid, "this is not a MAT file");
            fclose(fid);
            controller = testCase.emptyController();
            controller.ProtocolRoot = folder;

            choices = controller.protocolChoices();

            testCase.verifyEqual(numel(choices), 3, ...
                "One bad file must not hide the protocols beside it.");
            bad = choices([choices.choice_id] == "not_a_protocol");
            testCase.verifyFalse(bad.loadable);
            testCase.verifyNotEqual(bad.issue, "");
        end

        function aChosenProtocolIsLoadedAndBecomesCurrent(testCase)
            controller = testCase.loadedControllerWithoutProtocol();
            controller.ProtocolRoot = testCase.protocolFolder();
            controller.protocolChoices();

            response = testCase.act(controller, "load_protocol_choice", ...
                struct("choice_id", "screen_a"));

            testCase.verifyTrue(response.ok);
            testCase.verifyTrue(any(controller.Calls == "loadProtocolChoice"));
            testCase.verifyTrue(response.state.protocol.loaded);
            testCase.verifyEqual(response.state.protocol.summary.protocol_id, ...
                "screen_a_protocol");
            current = controller.protocolChoices();
            testCase.verifyTrue(current([current.choice_id] == "screen_a").is_current);
        end

        function anUnknownProtocolChoiceIsRefused(testCase)
            controller = testCase.loadedControllerWithoutProtocol();
            controller.ProtocolRoot = testCase.protocolFolder();

            response = testCase.act(controller, "load_protocol_choice", ...
                struct("choice_id", "/etc/passwd"));

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:UnknownProtocolChoice");
            testCase.verifyFalse(response.state.protocol.loaded);
        end

        % ---------------------------------------------------------------
        % C. Editable plan parameters
        % ---------------------------------------------------------------
        function anEditablePlanParameterIsChangedThroughTheController(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "set_plan_parameter", ...
                struct("name", "orange_expansion_pixels", "value", 4));

            testCase.verifyTrue(response.ok);
            testCase.verifyTrue(any(controller.Calls == "setPlanParameter"));
            testCase.verifyEqual( ...
                response.state.plan_parameters.orange_expansion_pixels, 4);
        end

        function anUnknownPlanParameterIsRefused(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "set_plan_parameter", ...
                struct("name", "mod488_voltage", "value", 3));

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:UnknownPlanParameter");
        end

        function anOutOfRangeEnumIsRefusedByTheController(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "set_plan_parameter", ...
                struct("name", "stimulation_mode", "value", "3p_sparkles"));

            testCase.verifyEqual(response.status, "validation_error");
            testCase.verifyEqual(response.state.plan_parameters.stimulation_mode, ...
                "1p_dmd", "A refused edit must leave the value alone.");
        end

        % ---------------------------------------------------------------
        % D, E, O. Lifecycle
        % ---------------------------------------------------------------
        function freezingProducesAFrozenRun(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "freeze_run");

            testCase.verifyTrue(response.ok);
            testCase.verifyTrue(any(controller.Calls == "freezeRun"));
            testCase.verifyEqual(response.state.plan_state, "FROZEN");
            testCase.verifyEqual(response.state.lifecycle, "frozen");
            testCase.verifyTrue(response.state.active_run.frozen);
            testCase.verifyTrue(response.state.legal_actions.return_to_editing);
        end

        function returningToEditingReportsTheEditableState(testCase)
            controller = testCase.loadedController();
            testCase.act(controller, "freeze_run");

            response = testCase.act(controller, "return_to_editing");

            testCase.verifyTrue(response.ok);
            testCase.verifyTrue(any(controller.Calls == "returnToEditing"));
            testCase.verifyEqual(response.state.plan_state, "EDITABLE");
            testCase.verifyEqual(response.state.lifecycle, "editing");
            testCase.verifyFalse(response.state.active_run.frozen);
        end

        function freezingWithoutAProtocolIsNotLegal(testCase)
            controller = testCase.loadedControllerWithoutProtocol();

            response = testCase.act(controller, "freeze_run");

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.status, "not_legal");
            testCase.verifyEqual(response.state.plan_state, "EDITABLE");
            testCase.verifyFalse(response.state.legal_actions.freeze_run);
        end

        function startingABatchWithoutAFrozenRunIsNotLegal(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "start_new_batch");

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.status, "not_legal");
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:FrozenRunRequired");
            testCase.verifyFalse(response.state.legal_actions.start_new_batch);
        end

        function startingABatchBeforeTheCurrentOneCompletesIsNotLegal(testCase)
            controller = testCase.loadedController();
            testCase.act(controller, "freeze_run");

            response = testCase.act(controller, "start_new_batch");

            testCase.verifyEqual(response.status, "not_legal");
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:CompletedBatchRequired");
        end

        function noActionButStoppingIsAcceptedWhileRunning(testCase)
            % Issued from inside a real simulated acquisition, on a timer,
            % which is the situation this guard exists for: MATLAB services
            % the interface's socket during a run, so a request genuinely can
            % arrive while the controller is RUNNING. Poking the lifecycle
            % property instead would test a state the controller cannot
            % actually be put into from outside.
            controller = testCase.frozenSimulationController();
            observed = struct("lifecycle", "", "actions", strings(0, 1), ...
                "statuses", strings(0, 1), "cells", NaN);

            testCase.probeDuringRun(controller, @probe);

            testCase.verifyEqual(observed.lifecycle, "running", ...
                "The probe did not run during the acquisition.");
            testCase.verifyNotEmpty(observed.actions);
            for k = 1:numel(observed.actions)
                testCase.verifyEqual(observed.statuses(k), "not_legal", ...
                    sprintf("%s must be refused during an acquisition.", ...
                        observed.actions(k)));
            end
            testCase.verifyEqual(observed.cells, 2, ...
                "Nothing must have been changed by the refused actions.");

            function probe()
                observed.lifecycle = controller.getState().lifecycle;
                for action = setdiff(testCase.allowlistedActions(), ...
                        "stop_after_current")
                    response = adaptive_optopatch.apply_controller_action( ...
                        controller, action, struct(), controller.Revision);
                    observed.actions(end + 1, 1) = action;
                    observed.statuses(end + 1, 1) = response.status;
                end
                observed.cells = numel(controller.getState().cells);
            end
        end

        % ---------------------------------------------------------------
        % N. Run controls delegate rather than reimplement
        % ---------------------------------------------------------------
        function runControlsCallTheControllerAndNothingElse(testCase)
            controller = testCase.loadedController();
            testCase.act(controller, "freeze_run");
            controller.Calls = strings(0, 1);

            testCase.act(controller, "run_next");
            testCase.act(controller, "run_all");

            testCase.verifyEqual(controller.Calls, ["runNext"; "runAll"], ...
                "Run controls must delegate, in order, and do nothing else.");
        end

        function stoppingIsTheOneActionARunningSessionAccepts(testCase)
            controller = testCase.frozenSimulationController();
            observed = struct("ok", false, "lifecycle", "", "requested", false);

            testCase.probeDuringRun(controller, @probe);

            testCase.verifyTrue(observed.ok);
            testCase.verifyTrue(observed.requested);
            testCase.verifyEqual(observed.lifecycle, "stopping_after_current", ...
                "The controller must report the pending stop, not leave a " + ...
                "frontend to infer it from a button.");

            function probe()
                response = adaptive_optopatch.apply_controller_action( ...
                    controller, "stop_after_current", struct(), ...
                    controller.Revision);
                observed.ok = response.ok;
                observed.requested = response.state.stop_after_current_requested;
                observed.lifecycle = response.state.lifecycle;
            end
        end

        function stoppingIsAcceptedWithAStaleRevision(testCase)
            % A run bumps the revision continuously as it reports progress, so
            % a browser's revision is stale almost by definition by the time
            % somebody reaches for Stop. Refusing it then would be refusing it
            % exactly when it is wanted.
            controller = testCase.frozenSimulationController();
            observed = struct("ok", false, "status", "", "requested", false);

            testCase.probeDuringRun(controller, @probe);

            testCase.verifyTrue(observed.ok, ...
                "A stale revision must not stop a stop.");
            testCase.verifyEqual(observed.status, "applied");
            testCase.verifyTrue(observed.requested);

            function probe()
                response = adaptive_optopatch.apply_controller_action( ...
                    controller, "stop_after_current", struct(), 0);
                observed.ok = response.ok;
                observed.status = response.status;
                observed.requested = response.state.stop_after_current_requested;
            end
        end

        function stoppingWhenNothingIsRunningIsNotLegal(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "stop_after_current");

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.status, "not_legal");
            testCase.verifyFalse(response.state.stop_after_current_requested);
        end

        % ---------------------------------------------------------------
        % I, J. Revisions
        % ---------------------------------------------------------------
        function aStaleRequestIsRefusedAndMutatesNothing(testCase)
            controller = testCase.loadedController();
            stale = controller.Revision;
            controller.setStatus("somebody used the MATLAB GUI");
            before = controller.getState();

            response = adaptive_optopatch.apply_controller_action( ...
                controller, "delete_soma", struct("cell_id", "cell_001"), stale);

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.status, "stale_revision");
            testCase.verifyEmpty(controller.Calls, ...
                "A stale request must not reach the controller at all.");
            testCase.verifyEqual(controller.getState(), before);
            testCase.verifyEqual(response.state, before, ...
                "The refusal must carry the state that is actually true.");
            testCase.verifyEqual(response.expected_revision, stale);
            testCase.verifyEqual(response.revision, controller.Revision);
        end

        function aRequestWithNoRevisionIsRefused(testCase)
            controller = testCase.loadedController();

            response = adaptive_optopatch.apply_controller_action( ...
                controller, "delete_soma", struct("cell_id", "cell_001"), []);

            testCase.verifyEqual(response.status, "stale_revision");
            testCase.verifyEqual(numel(response.state.cells), 2);
        end

        function everySuccessfulActionAdvancesTheRevision(testCase)
            controller = testCase.loadedControllerWithoutProtocol();
            controller.ProtocolRoot = testCase.protocolFolder();

            requests = { ...
                "add_soma", struct("vertices_xy", [50 50; 62 50; 62 62; 50 62]); ...
                "set_cell_eligibility", struct("cell_id", "cell_001", ...
                    "recording_enabled", false); ...
                "update_soma", struct("cell_id", "cell_002", ...
                    "vertices_xy", [61 41; 76 41; 76 56; 61 56]); ...
                "set_plan_parameter", struct("name", "repeat_batch_count", ...
                    "value", 2); ...
                "load_protocol_choice", struct("choice_id", "screen_a"); ...
                "freeze_run", struct(); ...
                "return_to_editing", struct(); ...
                "delete_soma", struct("cell_id", "cell_003")};

            for k = 1:size(requests, 1)
                before = controller.Revision;
                response = testCase.act(controller, requests{k, 1}, requests{k, 2});
                testCase.verifyTrue(response.ok, ...
                    sprintf("%s: %s", requests{k, 1}, response.message));
                testCase.verifyGreaterThan(response.revision, before, ...
                    sprintf("%s must advance the revision.", requests{k, 1}));
                testCase.verifyEqual(response.revision, controller.Revision);
                testCase.verifyEqual(response.state.revision, controller.Revision);
            end
        end

        function theReturnedRevisionIsTheOneToSendNext(testCase)
            % The loop a frontend actually runs: act, adopt the returned
            % revision, act again. It must never go stale against itself.
            controller = testCase.loadedController();
            revision = controller.Revision;

            for expansion = 1:5
                response = adaptive_optopatch.apply_controller_action( ...
                    controller, "set_plan_parameter", ...
                    struct("name", "orange_expansion_pixels", ...
                        "value", expansion), revision);
                testCase.verifyTrue(response.ok, response.message);
                revision = response.revision;
            end

            testCase.verifyEqual( ...
                controller.PlanParameters.orange_expansion_pixels, 5);
        end

        % ---------------------------------------------------------------
        % K. What crosses the wire
        % ---------------------------------------------------------------
        function everyResponseSurvivesTheJsonEncodingJsServerUses(testCase)
            controller = testCase.loadedController();
            responses = { ...
                testCase.act(controller, "set_cell_eligibility", ...
                    struct("cell_id", "cell_001", "recording_enabled", false)); ...
                testCase.act(controller, "polish_the_objective"); ...
                testCase.act(controller, "start_new_batch"); ...
                testCase.act(controller, "freeze_run")};

            for k = 1:numel(responses)
                decoded = testCase.verifyJsonSafe(responses{k});
                for field = ["schema_version", "ok", "action", "status", ...
                        "message", "identifier", "expected_revision", ...
                        "revision", "state"]
                    testCase.verifyTrue(isfield(decoded, field), ...
                        sprintf("The encoded response is missing %s.", field));
                end
                testCase.verifyTrue(isfield(decoded.state, "revision"));
            end
        end

        function noResponseCarriesAFieldNamedError(testCase)
            % The browser's MATLAB bridge reads a reply with `error` as a
            % thrown exception: red snackbar, result discarded. A refusal is
            % a result and must not look like a throw.
            controller = testCase.loadedController();

            for action = ["polish_the_objective", "start_new_batch", "freeze_run"]
                response = testCase.act(controller, action);
                testCase.verifyFalse(isfield(response, "error"), ...
                    sprintf("%s produced a reply with an error field.", action));
            end
        end

        function aRefusalStillCarriesUsableErrorText(testCase)
            controller = testCase.loadedController();

            response = testCase.act(controller, "set_cell_eligibility", ...
                struct("cell_id", "cell_404", "recording_enabled", false));

            testCase.verifyNotEqual(response.message, "");
            testCase.verifySubstring(char(response.message), "cell_404");
        end
    end

    % -------------------------------------------------------------------
    % Fixtures
    % -------------------------------------------------------------------
    methods (Access=private)
        function response = act(testCase, controller, action, payload)
            % The normal, non-stale call: whatever revision the caller would
            % have just read.
            arguments
                testCase %#ok<INUSA>
                controller
                action (1,1) string
                payload = struct()
            end
            response = adaptive_optopatch.apply_controller_action( ...
                controller, action, payload, controller.Revision);
        end

        function actions = allowlistedActions(~)
            % Mirrors action_names() in apply_controller_action. Written out
            % rather than read back from it, so that adding an action to the
            % production list without deciding what it does here is a test
            % failure and not a silent pass.
            actions = ["load_snapshot_choice", "set_cell_eligibility", ...
                "add_soma", "update_soma", "delete_soma", ...
                "load_protocol_choice", "set_plan_parameter", ...
                "freeze_run", "start_new_run", "return_to_editing", ...
                "start_new_batch", "run_next", "run_all", "stop_after_current"];
        end

        function probeDuringRun(testCase, controller, probe)
            % Run one simulated trial and call `probe` from the event queue
            % while it is in progress. This is the idiom the GUI's own
            % during-a-run tests use: a short-delay timer, started just
            % before the run, waited on just after.
            timerObject = timer("StartDelay", 0.01, "TimerFcn", @(~, ~) probe());
            cleanup = onCleanup(@() delete_timer(timerObject));
            start(timerObject);
            controller.runNext();
            wait(timerObject);
            testCase.verifyEqual(controller.LifecycleState, "FROZEN", ...
                "The run must have finished before these are checked.");
        end

        function controller = frozenSimulationController(testCase)
            % A real controller - not the call recorder - because these tests
            % need a genuine acquisition to be in progress. The simulated
            % Luminos backend is the one the controller tests use; nothing
            % here touches hardware.
            root = testCase.temporaryFolder();
            controller = adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp", simulatedLuminosApp("CameraRoi", [974 100 984 80]), ...
                "RunRoot", root);
            testCase.addTeardown(@() delete(controller));
            controller.setReferenceData(ones(80, 100), reference_info(root), ...
                {[25 25; 40 25; 40 40; 25 40], [60 40; 75 40; 75 55; 60 55]});
            controller.setPlanParameter("mode", "1p_dmd");
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount", 1, "ModulatorVoltage", 1));
            controller.freezeRun();
        end

        function controller = emptyController(testCase)
            controller = ControllerCallRecorder();
            testCase.addTeardown(@() delete(controller));
        end

        function controller = emptyControllerWithReference(testCase)
            root = testCase.temporaryFolder();
            controller = ControllerCallRecorder( ...
                "LuminosApp", simulatedLuminosApp("CameraRoi", [974 100 984 80]), ...
                "RunRoot", root);
            testCase.addTeardown(@() delete(controller));
            controller.setReferenceData(ones(80, 100), reference_info(root), {});
            controller.Calls = strings(0, 1);
        end

        function controller = loadedControllerWithoutProtocol(testCase)
            controller = testCase.emptyControllerWithReference();
            controller.setSomaPolygons({[25 25; 40 25; 40 40; 25 40], ...
                [60 40; 75 40; 75 55; 60 55]});
            controller.setPlanParameter("mode", "1p_dmd");
            controller.Calls = strings(0, 1);
        end

        function controller = loadedController(testCase)
            controller = testCase.loadedControllerWithoutProtocol();
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount", 1, "ModulatorVoltage", 1));
            controller.Calls = strings(0, 1);
        end

        function folder = protocolFolder(testCase)
            % Two saved protocols with distinct identities, in a folder of
            % their own, so choice_id can be asserted on.
            folder = testCase.temporaryFolder();
            for name = ["screen_a", "screen_b"]
                protocol = adaptive_optopatch.generate_screen_protocol( ...
                    "PulseCount", 1, "ModulatorVoltage", 1);
                protocol.protocol_id = name + "_protocol";
                adaptive_optopatch.save_protocol( ...
                    fullfile(folder, name + ".mat"), protocol);
            end
        end

        function root = temporaryFolder(testCase)
            root = string(tempname);
            mkdir(root);
            testCase.addTeardown(@() remove_if_present(root));
        end

        function decoded = verifyJsonSafe(testCase, value)
            encoded = "";
            testCase.verifyWarningFree(@() assign_encoded());
            decoded = jsondecode(encoded);

            function assign_encoded()
                encoded = jsonencode(value);
            end
        end
    end
end

function info = reference_info(root)
camera = struct("ROI", [0 0 100 80], "bin", 1, ...
    "x_world_limits", [974 1074], "y_world_limits", [984 1064]);
info = struct("snapshot_name", "action_contract_test", ...
    "snapshot_directory", string(root), ...
    "snapshot_path", string(fullfile(root, "snapshot.mat")), ...
    "metadata", struct("rig_name", "Virtual_Upright", "voltage_camera", camera));
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder, "s"); end
end

function delete_timer(timerObject)
if ~isempty(timerObject) && isvalid(timerObject)
    stop(timerObject);
    delete(timerObject);
end
end
