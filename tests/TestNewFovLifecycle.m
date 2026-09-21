classdef TestNewFovLifecycle < matlab.unittest.TestCase
    %TESTNEWFOVLIFECYCLE The boundary between one field of view and the next.
    %   With the MATLAB-only planning window an experimenter closed Adaptive
    %   Optopatch and reopened it between fields of view. The useful property
    %   of that habit was never that it restarted anything - it was that each
    %   new field began from a clean EXPERIMENT-SPECIFIC state. A React
    %   session keeps one controller alive for hours, so that boundary has to
    %   be an operation, and startNewFov is it.
    %
    %   THE INVARIANT, stated once and asserted from both sides below:
    %
    %       After a new FOV, nothing whose meaning is "the previous
    %       biological field of view" can influence targeting, cell
    %       selection, plan generation, preview or execution of the next
    %       one - and everything whose meaning is "this rig" or "this
    %       session" is untouched.
    %
    %   The two halves are equally important. A reset that also forgot the
    %   camera/DMD calibration would be a factory reset wearing a lifecycle
    %   operation's name, and would cost an experimenter the part of the
    %   afternoon that is genuinely expensive to redo.
    %
    %   WHAT IS ASSERTED ELSEWHERE.
    %     - that `start_new_fov` is on the action allowlist, is refused
    %       during an acquisition along with every other non-stop action,
    %       and cannot be reached under its method spelling:
    %       TestAdaptiveOptopatchActions.
    %     - that a browser discards its own FOV-scoped drafts when the
    %       reference identity moves: the React suites, which is the other
    %       half of the same contract.
    %
    %   Nothing here drives hardware. One test runs a SIMULATED acquisition,
    %   because "may a new FOV be started while one is in progress" cannot
    %   honestly be asked of a poked lifecycle property.

    methods (Test)
        % ---------------------------------------------------------------
        % A. What a new FOV forgets
        % ---------------------------------------------------------------
        function aNewFovClearsTheReferenceAndItsCells(testCase)
            controller = testCase.populatedSession();
            before = controller.getState();
            testCase.assertTrue(before.fov.loaded);
            testCase.assertEqual(numel(before.cells), 3);

            controller.startNewFov();

            state = controller.getState();
            testCase.verifyFalse(state.fov.loaded, ...
                "No reference may remain loaded.");
            testCase.verifyEmpty(state.cells, ...
                "The previous FOV's cells must be gone.");
            testCase.verifyEmpty(state.soma_polygons);
            testCase.verifyEqual(state.fov.cell_count, 0);
            testCase.verifyEqual(state.fov.fov_id, "");
            testCase.verifyEqual(state.fov.snapshot_path, "");
            testCase.verifyEqual(state.fov.source_kind, "", ...
                "The chooser must stop reporting an entry as loaded.");
            testCase.verifyEqual(state.fov.source_path, "");
            testCase.verifyEqual(state.fov.image_size, [0 0]);
            testCase.verifyEmpty(controller.referenceDisplayImage(), ...
                "There must be no picture left to hand to a frontend.");
        end

        function aNewFovClearsEveryPerCellDecisionAndCalibration(testCase)
            % Decisions and calibrations are keyed by cell_id, and cell ids
            % are local to a FOV. They cannot be allowed to outlive the
            % cells they were made about, whatever the next FOV calls its
            % own somata.
            controller = testCase.populatedSession();
            before = controller.getState();
            testCase.assertFalse(before.cells(2).recording_enabled);
            testCase.assertFalse(before.cells(3).stimulation_enabled);
            testCase.assertEqual(before.cells(1).selected_blue_voltage_v, 1.4);

            controller.startNewFov();

            testCase.verifyEmpty(controller.getState().cells);
            testCase.verifyEmpty(controller.CellState, ...
                "The per-cell record itself must be discarded, not emptied " + ...
                "of rows while keeping the old FOV's identity.");
            testCase.verifyEmpty(controller.cellSummary());
            testCase.verifyEmpty(controller.somaMasks(), ...
                "No cached ROI mask of a cell that no longer exists.");
        end

        function aNewFovDiscardsThePreparedPlanAndItsRunAssociation(testCase)
            controller = testCase.populatedSession();
            testCase.assertEqual(controller.getState().plan_status, "ready");
            testCase.assertTrue(controller.getState().active_run.frozen);

            controller.startNewFov();

            state = controller.getState();
            testCase.verifyEmpty(controller.ActiveRunPlan, ...
                "The prepared plan targets somata that no longer exist.");
            testCase.verifyEqual(controller.ActiveRunFolder, "");
            testCase.verifyFalse(state.active_run.frozen);
            testCase.verifyEqual(state.active_run.folder, "");
            testCase.verifyFalse(state.plan_readiness.prepared, ...
                "A new FOV must report nothing prepared, not a stale plan.");
            testCase.verifyFalse(state.plan_summary.prepared);
            testCase.verifyEmpty(state.plan_summary.stimulating_cell_ids);
            testCase.verifyEqual(state.plan_state, "EDITABLE");
            testCase.verifyEqual(state.lifecycle, "editing");
            testCase.verifyFalse(state.run_progress.running);
            testCase.verifyEqual(state.run_progress.completed_acquisitions, 0);
        end

        function runAndUpdatePlanAreUnavailableAfterANewFov(testCase)
            % The controller's own answer, and the endpoint's, have to agree:
            % a frontend renders legal_actions, and a request that ignores
            % them is refused by the same rule.
            controller = testCase.populatedSession();

            controller.startNewFov();

            state = controller.getState();
            testCase.verifyEqual(state.plan_status, "not_ready");
            testCase.verifyFalse(state.legal_actions.run);
            testCase.verifyFalse(state.legal_actions.update_plan);
            testCase.verifyFalse(state.legal_actions.save_fov);
            testCase.verifyFalse(state.legal_actions.edit_cells);
            testCase.verifyTrue(state.legal_actions.load_fov, ...
                "Loading a reference is how the next FOV begins.");
            testCase.verifyTrue(state.legal_actions.load_protocol);
            testCase.verifyTrue(state.legal_actions.start_new_fov);
            testCase.verifyEqual(string(state.plan_readiness.blocking_issues), ...
                ["Load a reference FOV."; "Draw at least one soma."], ...
                "The lifecycle must read as 'no current FOV', not as an error.");

            response = testCase.act(controller, "run");
            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.status, "not_legal");
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:PlanNotReady");
        end

        function aNewFovAdvancesTheRevisionExactlyOnce(testCase)
            % One atomic transition, not a cascade of individually visible
            % clears. A frontend polls this number, and a reset that moved
            % it eight times would have eight intermediate states in which
            % half a field of view was on screen.
            controller = testCase.populatedSession();
            revisionBefore = controller.Revision;
            referenceBefore = controller.ReferenceRevision;

            controller.startNewFov();

            testCase.verifyEqual(controller.Revision, revisionBefore + 1);
            testCase.verifyEqual(controller.ReferenceRevision, ...
                referenceBefore + 1, ...
                "One new reference identity: the token every frontend " + ...
                "invalidates its FOV-scoped state on.");
        end

        function aNewFovNotifiesAViewExactlyOnce(testCase)
            % The MATLAB planning window redraws from StateChangedFcn. It
            % must be told, and told once.
            controller = testCase.populatedSession();
            notifications = 0;
            controller.StateChangedFcn = @() count();

            controller.startNewFov();

            testCase.verifyEqual(notifications, 1);

            function count()
                notifications = notifications + 1;
            end
        end

        function theNextFovsCellsCarryNothingFromTheOldOnesOfTheSameName(testCase)
            % The cross-FOV failure, from MATLAB's side. `cell_001` is
            % whichever soma was drawn first, so every field of view has
            % one; they are different neurons.
            controller = testCase.populatedSession();
            testCase.assertEqual(controller.getState().cells(1).cell_id, ...
                "cell_001");
            testCase.assertEqual( ...
                controller.getState().cells(1).selected_blue_voltage_v, 1.4);

            controller.startNewFov();
            controller.setReferenceData(ones(70, 90), testCase.plainInfo(), {});
            cellId = controller.addSomaPolygon([20 20; 35 20; 35 35; 20 35]);

            testCase.verifyEqual(cellId, "cell_001", ...
                "Numbering restarts, because the FOV does.");
            cells = controller.getState().cells;
            testCase.verifyEqual(numel(cells), 1);
            testCase.verifyTrue(cells(1).recording_enabled, ...
                "A new cell starts from the defaults, not from the old " + ...
                "cell_001's decisions.");
            testCase.verifyTrue(cells(1).stimulation_enabled);
            testCase.verifyTrue(isnan(cells(1).selected_blue_voltage_v), ...
                "The old cell_001's Blue calibration must not be inherited.");
        end

        % ---------------------------------------------------------------
        % B. What a new FOV keeps
        % ---------------------------------------------------------------
        function theLoadedProtocolSurvivesANewFov(testCase)
            % THE POLICY, asserted rather than left to be inferred. A pulse
            % protocol is a reusable experimental definition and names no
            % cell; what depends on the cells is its RESOLUTION against
            % them, which lives in the prepared plan and is discarded. So
            % "same protocol, next field" stays one step.
            controller = testCase.populatedSession();
            protocolBefore = controller.Protocol;
            pathBefore = controller.ProtocolPath;

            controller.startNewFov();

            state = controller.getState();
            testCase.verifyTrue(state.protocol.loaded, ...
                "The loaded protocol is session state, not FOV state.");
            testCase.verifyEqual(state.protocol.path, pathBefore);
            testCase.verifyEqual(state.protocol.summary.protocol_id, ...
                "screen_demo");
            testCase.verifyEqual(controller.Protocol, protocolBefore, ...
                "The definition itself must be byte-for-byte what it was.");
        end

        function noResolvedScheduleFromTheOldCellsSurvives(testCase)
            % The other half of the protocol policy, and the half that
            % matters for safety: the DEFINITION survives, everything
            % resolved against the old somata does not.
            controller = testCase.populatedSession();
            prepared = controller.ActiveRunPlan;
            testCase.assertNotEmpty(prepared.resolved_protocols);
            testCase.assertNotEmpty(prepared.targets.targets);
            testCase.assertTrue(any( ...
                string(prepared.manifest.trials.target_cell_id) == "cell_001"));

            controller.startNewFov();

            testCase.verifyEmpty(controller.ActiveRunPlan, ...
                "The resolved schedule, the target bundle, the preflight " + ...
                "result and the batch identity go with the plan.");
            summary = controller.planSummary();
            testCase.verifyFalse(summary.prepared);
            testCase.verifyEmpty(summary.stimulating_cell_ids);
            testCase.verifyEqual(summary.total_acquisitions, 0);
        end

        function everyPlanParameterSurvivesANewFov(testCase)
            % THE PLAN-PARAMETER POLICY. A new FOV states no values of its
            % own - it is the absence of a field of view - so every
            % parameter is carried across, exactly as loading a fresh camera
            % snapshot carries them. The FOV-scoped six are restated only by
            % a saved bundle, which is applyFovPlanParameters' job and is
            % asserted in TestAdaptiveOptopatchPlanWorkflow.
            controller = testCase.populatedSession();
            controller.setPlanParameter("blue_mask_adjustment_pixels", -1);
            controller.setPlanParameter("orange_expansion_pixels", 4);
            controller.setPlanParameter("maximum_velocity_v_per_s", 750);
            controller.setPlanParameter("repeat_batch_count", 3);
            before = controller.PlanParameters;

            controller.startNewFov();

            testCase.verifyEqual(controller.PlanParameters, before, ...
                "Deliberately set session and spatial settings are not " + ...
                "the previous FOV's property, and losing them would be a " + ...
                "quieter way of losing intent.");
        end

        function theRigAndItsCalibrationSurviveANewFov(testCase)
            % A FOV/session reset, not a hardware factory reset. Asserted
            % against the real simulated devices this controller holds, not
            % against a stub that would agree with anything.
            [controller, app] = testCase.populatedSession();
            devices = app.Devices;
            blue = testCase.deviceNamed(app, "DMD_Blue");
            orange = testCase.deviceNamed(app, "DMD_Orange");
            camera = testCase.deviceNamed(app, "Orca Fusion");
            scanner = testCase.deviceNamed(app, "Chameleon (To friends: Ben)");
            blueIdentity = blue.calibration_identity("Orca Fusion");
            orangeIdentity = orange.calibration_identity("Orca Fusion");
            scannerTransform = scanner.tform.A;
            cameraRoi = camera.ROI;
            cameraBin = camera.bin;
            cameraId = camera.cam_id;
            runRoot = controller.RunRoot;
            snapshotRoot = controller.SnapshotRoot;
            protocolRoot = controller.ProtocolRoot;

            controller.startNewFov();

            % That the controller still reads THROUGH this app, rather
            % than that it holds a handle equal to it: a device is changed
            % and the controller is asked, which is the only form of the
            % question a private binding can answer honestly.
            laser = testCase.deviceNamed(app, "488");
            laser.SetPower = 0.0123;
            testCase.verifyEqual(controller.currentObisPowerW(), 0.0123, ...
                "The Luminos session and its device bindings survive.");
            testCase.verifyEqual(numel(app.Devices), numel(devices));
            for k = 1:numel(devices)
                testCase.verifyTrue(app.Devices(k) == devices(k), ...
                    "Device bindings must be the same instances.");
            end
            testCase.verifyEqual(blue.calibration_identity("Orca Fusion"), ...
                blueIdentity, ...
                "The Blue camera/DMD calibration identity must survive.");
            testCase.verifyEqual(orange.calibration_identity("Orca Fusion"), ...
                orangeIdentity);
            testCase.verifyEqual(scanner.tform.A, scannerTransform, ...
                "The scanner calibration must survive.");
            testCase.verifyEqual(camera.ROI, cameraRoi);
            testCase.verifyEqual(camera.bin, cameraBin);
            testCase.verifyEqual(camera.cam_id, cameraId);
            testCase.verifyEqual(controller.RunRoot, runRoot, ...
                "The output root is a session setting.");
            testCase.verifyEqual(controller.SnapshotRoot, snapshotRoot);
            testCase.verifyEqual(controller.ProtocolRoot, protocolRoot);
            testCase.verifyNotEmpty(controller.protocolChoices(), ...
                "The protocol library must still be reachable.");
        end

        function aNewFovWritesNoHardwareAtAll(testCase)
            % NO REDUNDANT NEUTRALISATION. Adaptive Optopatch owns a DMD
            % pattern only for the length of a run: run_1p_manifest claims
            % ownership, blanks Blue and releases it in its cleanup, on
            % success and on failure alike. An idle session is therefore
            % already not emitting, and a Reset that issued its own writes
            % would be commanding hardware for a state change that happened
            % entirely in MATLAB memory.
            %
            % Counted rather than argued: getDevice is logged, so "did not
            % write" and "did not even look" are distinguishable.
            [controller, app] = testCase.populatedSession();
            blue = testCase.deviceNamed(app, "DMD_Blue");
            orange = testCase.deviceNamed(app, "DMD_Orange");
            % An operator's own generic stack, and Luminos's autoload
            % toggle, which the DMD ownership work is careful with.
            blue.pattern_stack = true(4, 4, 2);
            blue.auto_write_stack = true;
            blue.Target = false(size(blue.Target));
            blue.Target(1:3, 1:3) = true;
            before = struct( ...
                "target", blue.Target, "stack", blue.pattern_stack, ...
                "autoWrite", blue.auto_write_stack, ...
                "owner", blue.pattern_owner, ...
                "staticWrites", blue.StaticWriteCount, ...
                "stackWrites", blue.StackWriteCount, ...
                "slotWrites", blue.slot_write_count, ...
                "orangeTarget", orange.Target, ...
                "orangeStatic", orange.StaticWriteCount);
            app.DeviceLookupLog = strings(0, 1);

            controller.startNewFov();

            testCase.verifyEmpty(app.DeviceLookupLog, ...
                "A new FOV must not resolve a device, let alone write one.");
            testCase.verifyEqual(blue.Target, before.target);
            testCase.verifyEqual(blue.pattern_stack, before.stack, ...
                "The operator's DMD-tab stack is not Adaptive Optopatch's.");
            testCase.verifyEqual(blue.auto_write_stack, before.autoWrite, ...
                "auto_write_stack is Luminos's toggle and stays as it is.");
            testCase.verifyEqual(blue.pattern_owner, before.owner);
            testCase.verifyEqual(blue.StaticWriteCount, before.staticWrites);
            testCase.verifyEqual(blue.StackWriteCount, before.stackWrites);
            testCase.verifyEqual(blue.slot_write_count, before.slotWrites);
            testCase.verifyEqual(orange.Target, before.orangeTarget);
            testCase.verifyEqual(orange.StaticWriteCount, before.orangeStatic);
        end

        function aNewFovLeavesNoExecutableTargetBehind(testCase)
            % The physical claim, from the side that can actually be
            % checked in software: whatever is still programmed into a DMD,
            % nothing in this session can be made to run the old field of
            % view's targets, because there is no plan to run and no cell to
            % resolve one against.
            controller = testCase.populatedSession();

            controller.startNewFov();

            testCase.verifyError(@() controller.assertRunnable(), ...
                "adaptive_optopatch:PlanNotReady");
            testCase.verifyError(@() controller.runPreparedPlan(), ...
                "adaptive_optopatch:PlanNotReady");
            testCase.verifyError(@() controller.updatePlan(), ...
                "adaptive_optopatch:PlanNotReady");
        end

        % ---------------------------------------------------------------
        % C. Nothing on disk is touched
        % ---------------------------------------------------------------
        function aNewFovDeletesNothingFromDisk(testCase)
            % The controller discards a live association, never an artifact.
            % An experimenter who has just finished a field of view and
            % pressed New FOV has to still have its data.
            controller = testCase.populatedSession();
            fovPath = controller.saveNextFov();
            runFolder = controller.ActiveRunFolder;
            snapshotPath = string(controller.ReferenceInfo.snapshot_path);
            protocolPath = controller.ProtocolPath;
            runFiles = dir(fullfile(runFolder, "*"));
            testCase.assertNotEmpty(runFiles);
            testCase.assertTrue(isfile(fovPath));

            controller.startNewFov();

            testCase.verifyTrue(isfile(fovPath), ...
                "A saved FOV bundle is data, not session state.");
            testCase.verifyTrue(isfolder(runFolder), ...
                "Archived run artifacts must survive.");
            testCase.verifyEqual(numel(dir(fullfile(runFolder, "*"))), ...
                numel(runFiles));
            testCase.verifyTrue(isfile(snapshotPath));
            testCase.verifyTrue(isfile(protocolPath));
        end

        function aSavedFovCanStillBeReloadedAfterANewFov(testCase)
            % The strongest statement that nothing was destroyed: the field
            % of view that was cleared comes back, with its cells, their
            % decisions and their calibration.
            controller = testCase.populatedSession();
            fovPath = controller.saveNextFov();

            controller.startNewFov();
            testCase.assertEmpty(controller.getState().cells);
            controller.loadFov(fovPath);

            state = controller.getState();
            testCase.verifyEqual(numel(state.cells), 3);
            testCase.verifyEqual(state.cells(1).selected_blue_voltage_v, 1.4);
            testCase.verifyFalse(state.cells(2).recording_enabled);
            testCase.verifyFalse(state.cells(3).stimulation_enabled);
            testCase.verifyEqual(state.fov.source_kind, "ao_fov");
        end

        % ---------------------------------------------------------------
        % D. Legal states
        % ---------------------------------------------------------------
        function aNewFovIsRefusedWhileAnAcquisitionIsActive(testCase)
            % Issued from inside a real simulated acquisition, on a timer,
            % which is the only honest way to ask this: MATLAB services the
            % interface's socket during a run, so the request genuinely can
            % arrive while the controller is RUNNING. An acquisition is
            % never implicitly stopped to change field - the experimenter
            % uses stop-after-current first.
            controller = testCase.runningSession();
            observed = struct("lifecycle", "", "legal", true, ...
                "status", "", "identifier", "", "direct", "", ...
                "cells", NaN, "referenceRevision", NaN);
            referenceBefore = controller.ReferenceRevision;

            testCase.probeDuringRun(controller, @probe);

            testCase.verifyEqual(observed.lifecycle, "running", ...
                "The probe did not run during the acquisition.");
            testCase.verifyFalse(observed.legal, ...
                "start_new_fov must not be offered while running.");
            testCase.verifyEqual(observed.status, "not_legal");
            testCase.verifyEqual(observed.direct, ...
                "adaptive_optopatch:AcquisitionActive", ...
                "A direct call must be refused by the controller itself, " + ...
                "not only by the endpoint.");
            testCase.verifyEqual(observed.cells, 2, ...
                "The current FOV must be untouched by the refusal.");
            testCase.verifyEqual(observed.referenceRevision, referenceBefore, ...
                "A refused reset must not advance the reference identity.");
            testCase.verifyEqual(numel(controller.getState().cells), 2);

            function probe()
                observed.lifecycle = controller.getState().lifecycle;
                observed.legal = controller.legalActions().start_new_fov;
                response = adaptive_optopatch.apply_controller_action( ...
                    controller, "start_new_fov", struct(), controller.Revision);
                observed.status = response.status;
                try
                    controller.startNewFov();
                    observed.direct = "not refused";
                catch exception
                    observed.direct = string(exception.identifier);
                end
                observed.cells = numel(controller.getState().cells);
                observed.referenceRevision = controller.ReferenceRevision;
            end
        end

        function aPreparedButUnrunPlanIsDeliberatelyAbandoned(testCase)
            % The frozen case. A plan is prepared and has never run; the
            % experimenter has moved the stage. The plan describes somata
            % that are no longer under the objective, so it is abandoned
            % rather than carried - and the bundle it wrote stays on disk.
            controller = testCase.populatedSession();
            runFolder = controller.ActiveRunFolder;
            testCase.assertEqual(controller.LifecycleState, "FROZEN");
            testCase.assertTrue(controller.legalActions().start_new_fov);

            response = testCase.act(controller, "start_new_fov");

            testCase.verifyTrue(response.ok);
            testCase.verifyEqual(response.status, "applied");
            testCase.verifyEqual(response.state.plan_state, "EDITABLE");
            testCase.verifyFalse(response.state.active_run.frozen);
            testCase.verifyFalse(response.state.legal_actions.return_to_editing);
            testCase.verifyFalse(response.state.legal_actions.start_new_batch);
            testCase.verifyTrue(isfolder(runFolder), ...
                "Abandoning the association must not delete the archive.");
        end

        function aCompletedRunIsFollowedByACleanFov(testCase)
            % The ordinary end of a field of view: the experimenter ran the
            % plan, it finished, and they move on.
            controller = testCase.runningSession();
            controller.runPreparedPlan();
            testCase.assertEqual(controller.LifecycleState, "FROZEN");
            testCase.assertTrue(controller.legalActions().start_new_fov);

            controller.startNewFov();

            state = controller.getState();
            testCase.verifyFalse(state.fov.loaded);
            testCase.verifyEmpty(state.cells);
            testCase.verifyFalse(state.active_run.frozen);
            testCase.verifyEqual(state.plan_status, "not_ready");
            testCase.verifyEmpty(controller.LastRun, ...
                "The previous run's in-memory record belongs to that FOV.");
            testCase.verifyFalse(state.run_progress.running);
        end

        function aNewFovOnAnAlreadyEmptySessionIsLegalAndHarmless(testCase)
            % Idempotent on purpose: "start a new FOV" from nothing is
            % nothing, and making it conditional would give a frontend a
            % second rule to get wrong.
            controller = adaptive_optopatch.AdaptiveOptopatchController();
            testCase.addTeardown(@() delete(controller));
            testCase.assertTrue(controller.legalActions().start_new_fov);
            revisionBefore = controller.Revision;

            response = testCase.act(controller, "start_new_fov");

            testCase.verifyTrue(response.ok);
            testCase.verifyEqual(controller.Revision, revisionBefore + 1);
            testCase.verifyFalse(response.state.fov.loaded);
            testCase.verifyEmpty(response.state.cells);
        end

        % ---------------------------------------------------------------
        % E. One primitive, three ways of replacing a field of view
        % ---------------------------------------------------------------
        function loadingAFreshSnapshotDiscardsTheOldPreparedPlanToo(testCase)
            % THE SHARED-CLEANUP CLAIM. Loading another reference and
            % pressing New FOV are both FOV replacement, and both go
            % through clearFovOwnedState, so neither can come to mean
            % something the other does not.
            controller = testCase.populatedSession();
            testCase.assertTrue(controller.getState().active_run.frozen);
            second = testCase.secondSnapshot(controller);

            controller.loadSnapshot(second);

            state = controller.getState();
            testCase.verifyTrue(state.fov.loaded);
            testCase.verifyEmpty(state.cells, ...
                "A camera snapshot starts a fresh FOV.");
            testCase.verifyEmpty(controller.ActiveRunPlan, ...
                "The old FOV's prepared plan must go with the old FOV, " + ...
                "however the replacement happened.");
            testCase.verifyEqual(controller.ActiveRunFolder, "");
            testCase.verifyFalse(state.active_run.frozen);
            testCase.verifyEqual(state.plan_status, "not_ready");
        end

        function restoringASavedFovReplacesRatherThanMergesTheCurrentOne(testCase)
            % The third path, and the one that is DIFFERENT: it restores
            % the saved FOV's own cells and decisions. What it shares is
            % the cleanup - nothing of the FOV it replaced survives it.
            controller = testCase.populatedSession();
            fovPath = controller.saveNextFov();
            controller.startNewFov();
            controller.setReferenceData(ones(70, 90), testCase.plainInfo(), ...
                {[20 20; 35 20; 35 35; 20 35]});
            controller.setCellBlueVoltage("cell_001", 2.9);
            identityBefore = controller.ReferenceRevision;

            controller.loadFov(fovPath);

            state = controller.getState();
            testCase.verifyEqual(numel(state.cells), 3, ...
                "The saved FOV's own cells come back.");
            testCase.verifyEqual(state.cells(1).selected_blue_voltage_v, 1.4, ...
                "Its own calibration, not the one in between.");
            testCase.verifyEqual(controller.ReferenceRevision, ...
                identityBefore + 1, ...
                "Restoring a saved FOV is a reference replacement like " + ...
                "any other, so every frontend invalidates on it.");
            testCase.verifyEmpty(controller.ActiveRunPlan);
        end

        % ---------------------------------------------------------------
        % F. The endpoint delegates
        % ---------------------------------------------------------------
        function theEndpointDelegatesToTheOneControllerOperation(testCase)
            % The behaviour is the controller's and the endpoint reproduces
            % none of it, so a MATLAB frontend adding a New FOV button
            % later gets exactly these semantics.
            controller = ControllerCallRecorder();
            testCase.addTeardown(@() delete(controller));
            controller.setReferenceData(ones(70, 90), testCase.plainInfo(), ...
                {[20 20; 35 20; 35 35; 20 35]});
            controller.Calls = strings(0, 1);

            response = testCase.act(controller, "start_new_fov");

            testCase.verifyTrue(response.ok);
            testCase.verifyEqual(controller.Calls, "startNewFov", ...
                "One controller operation, and nothing else.");
            testCase.verifyFalse(response.state.fov.loaded);
        end

        function aStaleNewFovRequestIsRefusedAndMutatesNothing(testCase)
            % The ordinary revision guard, asserted for this action too: a
            % reset means what the operator saw when they asked for it.
            controller = testCase.populatedSession();
            stale = controller.Revision;
            controller.setStatus("Something else happened.");
            before = controller.getState();

            response = adaptive_optopatch.apply_controller_action( ...
                controller, "start_new_fov", struct(), stale);

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.status, "stale_revision");
            testCase.verifyEqual(response.state, before, ...
                "A refused reset must leave the field of view alone.");
            testCase.verifyTrue(controller.getState().fov.loaded);
        end
    end

    % -------------------------------------------------------------------
    % Fixtures
    % -------------------------------------------------------------------
    methods (Access=private)
        function response = act(~, controller, action, payload)
            % The normal, non-stale call: whatever revision a caller would
            % have just read.
            arguments
                ~
                controller
                action (1,1) string
                payload = struct()
            end
            response = adaptive_optopatch.apply_controller_action( ...
                controller, action, payload, controller.Revision);
        end

        function [controller, app] = populatedSession(testCase)
            % A COMPLETE FIELD OF VIEW, which is what a reset has to be
            % asked about: a real camera snapshot read from disk, three
            % somata drawn on it, a recording decision and a stimulation
            % decision turned off, a per-cell Blue calibration, a protocol
            % loaded from a file, and a plan prepared and archived.
            %
            % The simulated Luminos app is built HERE rather than reached
            % for afterwards, because the controller keeps it private - and
            % the rig-survives-a-reset assertions have to hold the real
            % device objects, not a summary of them.
            folder = testCase.temporaryFolder();
            testCase.writeSnapshot(fullfile(folder, ...
                "120000newfov_cam-OrcaFusion.mat"), 40);
            app = simulatedLuminosApp("CameraRoi", [974 160 984 128]);
            controller = adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp", app, "RunRoot", testCase.temporaryFolder());
            testCase.addTeardown(@() delete(controller));
            controller.SnapshotRoot = folder;
            controller.loadSnapshotChoice("120000newfov_cam-OrcaFusion");
            controller.setSomaPolygons({ ...
                [30 32; 46 32; 46 48; 30 48], ...
                [96 48; 112 48; 112 64; 96 64], ...
                [120 95; 136 95; 136 111; 120 111]});
            controller.setCellEligibility("cell_002", "RecordingEnabled", false);
            controller.setCellEligibility("cell_003", "StimulationEnabled", false);
            controller.setCellBlueVoltage("cell_001", 1.4);
            controller.ProtocolRoot = testCase.protocolFolder();
            choices = controller.protocolChoices();
            controller.loadProtocolChoice(choices(1).choice_id);
            controller.updatePlan();
            testCase.assertEqual(controller.getState().plan_status, "ready");
        end

        function writeSnapshot(~, path, level)
            % One Luminos camera snap, in the shape read_reference_snapshot
            % reads: a 128x160 frame with the DMD transform the snap was
            % taken under recorded beside it.
            snap = struct; %#ok<NASGU>
            snap.img = uint16(level * ones(128, 160));
            snap.name = "Orca Fusion";
            snap.bin = 1;
            snap.ref2d = imref2d([128 160], [0 160], [0 128]);
            snap.timestamp = datetime("now");
            snap.tform = struct("name", "DMD_Blue", "tform", affine2d());
            save(path, "snap");
        end

        function controller = runningSession(testCase)
            % A session that can actually acquire. Two somata on a plain
            % reference and a one-pulse screen protocol, frozen, so a
            % simulated run is short. Nothing here touches hardware.
            root = testCase.temporaryFolder();
            controller = adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp", simulatedLuminosApp("CameraRoi", [974 100 984 80]), ...
                "RunRoot", root);
            testCase.addTeardown(@() delete(controller));
            controller.setReferenceData(ones(80, 100), testCase.plainInfo(root), ...
                {[25 25; 40 25; 40 40; 25 40], [60 40; 75 40; 75 55; 60 55]});
            controller.setPlanParameter("mode", "1p_dmd");
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount", 1, "ModulatorVoltage", 1));
            controller.freezeRun();
        end

        function probeDuringRun(testCase, controller, probe)
            % Run one simulated trial and call `probe` from the event queue
            % while it is in progress. The idiom TestAdaptiveOptopatchActions
            % uses for the same question: a short-delay timer, started just
            % before the run and waited on just after.
            timerObject = timer("StartDelay", 0.01, ...
                "TimerFcn", @(~, ~) probe());
            cleanup = onCleanup(@() delete_timer(timerObject)); %#ok<NASGU>
            start(timerObject);
            controller.runNext();
            wait(timerObject);
            testCase.verifyEqual(controller.LifecycleState, "FROZEN", ...
                "The run must have finished before these are checked.");
        end

        function folder = protocolFolder(testCase)
            folder = testCase.temporaryFolder();
            protocol = adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount", 1, "ModulatorVoltage", 1);
            protocol.protocol_id = "screen_demo";
            adaptive_optopatch.save_protocol( ...
                fullfile(folder, "screen_demo.mat"), protocol);
        end

        function path = secondSnapshot(testCase, controller)
            % Another camera snap in the same folder, THE SAME SIZE as the
            % first - which is the case a reference identity exists for.
            folder = string(controller.ReferenceInfo.snapshot_directory);
            path = fullfile(folder, "130000second_cam-OrcaFusion.mat");
            testCase.writeSnapshot(path, 200);
        end

        function info = plainInfo(testCase, root)
            % Reference metadata for a directly installed 80x100 image.
            arguments
                testCase
                root (1,1) string = testCase.temporaryFolder()
            end
            camera = struct("name", "Orca Fusion", "ROI", [0 0 100 80], ...
                "bin", 1, "x_world_limits", [974 1074], ...
                "y_world_limits", [984 1064]);
            info = struct("snapshot_name", "plain_test", ...
                "snapshot_directory", root, ...
                "snapshot_path", fullfile(root, "snapshot.mat"), ...
                "camera_name", "Orca Fusion", "camera_bin", 1, ...
                "metadata", struct("rig_name", "Virtual_Upright", ...
                    "voltage_camera", camera));
        end

        function device = deviceNamed(testCase, app, name)
            % Read straight off the device array rather than through
            % getDevice, which is LOGGED - a fixture must not write the
            % lookup log a test is about to assert on.
            match = arrayfun(@(d) d.name == name, app.Devices);
            testCase.assertEqual(sum(match), 1, ...
                sprintf("The simulated rig has no unique %s.", name));
            device = app.Devices(match);
        end

        function root = temporaryFolder(testCase)
            root = string(tempname);
            mkdir(root);
            testCase.addTeardown(@() AoFixtures.removeFolder(root));
        end
    end
end

function delete_timer(timerObject)
if isvalid(timerObject)
    stop(timerObject);
    delete(timerObject);
end
end
