classdef TestAdaptiveOptopatchPlanWorkflow < matlab.unittest.TestCase
    %TESTADAPTIVEOPTOPATCHPLANWORKFLOW configure -> Update plan -> Run.
    %   The experimenter-facing lifecycle, and the two properties that make
    %   it safe to put in front of an operator:
    %
    %     GATING IS AUTHORITATIVE. Whether a plan may run is decided by the
    %     controller, from the plan itself, and the action endpoint inherits
    %     that decision. A direct call cannot run something a greyed-out
    %     button would not.
    %
    %     STALENESS IS SPECIFIC. A plan is out of date when an input that
    %     can change what executes has moved, and only then. Revision is not
    %     the test: it advances for a status line, for a poll that re-reads
    %     a checkpoint, and for saving a FOV, none of which changes what
    %     would be acquired.
    %
    %   Runs here use the packaged simulator. Nothing touches hardware.

    methods (Test)
        % ---------------------------------------------------------------
        % A. The states
        % ---------------------------------------------------------------
        function aFreshSessionIsNotReadyAndSaysWhy(testCase)
            controller=testCase.emptyController();

            readiness=controller.planReadiness();

            testCase.verifyEqual(controller.planStatus(),"not_ready");
            testCase.verifyFalse(readiness.can_run);
            testCase.verifyFalse(readiness.can_update_plan);
            testCase.verifyEqual(readiness.blocking_issues,[ ...
                "Load a reference FOV."
                "Draw at least one soma."
                "Load a pulse protocol."]);
        end

        function eachMissingPrerequisiteIsReportedUntilItIsMet(testCase)
            controller=testCase.emptyController();
            testCase.verifyEqual(numel(controller.planReadiness().blocking_issues),3);

            controller.setReferenceData(testCase.referenceImage(), ...
                testCase.referenceInfo(),{});
            testCase.verifyEqual(controller.planReadiness().blocking_issues, [ ...
                "Draw at least one soma.";"Load a pulse protocol."]);

            controller.setSomaPolygons(testCase.somaPolygons());
            testCase.verifyEqual(controller.planReadiness().blocking_issues, ...
                "Load a pulse protocol.");

            controller.setProtocol(testCase.protocol());
            testCase.verifyEqual(controller.planStatus(),"update_required");
        end

        function aFovWithNoStimulatingCellIsNotReady(testCase)
            % Otherwise resolution fails with NoAcceptedTargets at Update
            % plan, which is a true answer given too late.
            controller=testCase.configuredController();
            for cellId=["cell_001","cell_002"]
                controller.setCellEligibility(cellId,"StimulationEnabled",false);
            end

            testCase.verifyEqual(controller.planStatus(),"not_ready");
            testCase.verifyEqual(controller.planReadiness().blocking_issues, ...
                "Enable Stim on at least one cell.");
        end

        function aValidEditableExperimentRequiresAnUpdate(testCase)
            controller=testCase.configuredController();

            readiness=controller.planReadiness();

            testCase.verifyEqual(readiness.status,"update_required");
            testCase.verifyTrue(readiness.can_update_plan);
            testCase.verifyFalse(readiness.can_run);
            testCase.verifyFalse(readiness.prepared);
            testCase.verifyEmpty(readiness.blocking_issues);
            testCase.verifySubstring(char(readiness.message),"Update plan");
        end

        function updatingThePlanMakesItReady(testCase)
            controller=testCase.configuredController();

            controller.updatePlan();

            readiness=controller.planReadiness();
            testCase.verifyEqual(readiness.status,"ready");
            testCase.verifyTrue(readiness.can_run);
            testCase.verifyTrue(readiness.prepared);
            testCase.verifyEmpty(readiness.stale_inputs);
            testCase.verifyEqual(readiness.message,"Ready to run.");
        end

        function theLifecycleIsReportedInTheStateSnapshot(testCase)
            controller=testCase.configuredController();
            testCase.verifyEqual(controller.getState().plan_status, ...
                "update_required");

            controller.updatePlan();
            state=controller.getState();

            testCase.verifyEqual(state.plan_status,"ready");
            testCase.verifyTrue(state.legal_actions.run);
            testCase.verifyTrue(state.legal_actions.update_plan);
            testCase.verifyTrue(state.plan_summary.prepared);
        end

        % ---------------------------------------------------------------
        % B. Gating, at the controller and through the endpoint
        % ---------------------------------------------------------------
        function runningIsRefusedWhileTheExperimentIsIncomplete(testCase)
            controller=testCase.emptyController();

            testCase.verifyError(@()controller.runPreparedPlan(), ...
                "adaptive_optopatch:PlanNotReady");
            response=testCase.act(controller,"run");
            testCase.verifyEqual(response.status,"not_legal");
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:PlanNotReady");
        end

        function runningIsRefusedWhenNothingIsPrepared(testCase)
            % The behaviour this replaces: run_all froze a plan implicitly,
            % so pressing Run with nothing prepared ran whatever the
            % editable state happened to be at that instant.
            controller=testCase.configuredController();

            testCase.verifyError(@()controller.runPreparedPlan(), ...
                "adaptive_optopatch:PlanUpdateRequired");
            testCase.verifyFalse(controller.getState().active_run.frozen, ...
                "A refused run must not have prepared anything.");
        end

        function aStaleDirectApiRunIsRejected(testCase)
            controller=testCase.configuredController();
            controller.updatePlan();
            controller.setCellEligibility("cell_002", ...
                "StimulationEnabled",false);

            % Freshest possible revision: the caller is up to date about the
            % session and still wrong about the plan, which is the whole
            % reason plan validity is not the revision.
            response=adaptive_optopatch.apply_controller_action( ...
                controller,"run",struct(),controller.Revision);

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:PlanUpdateRequired");
            testCase.verifyEqual(response.state.plan_status,"update_required");
        end

        function updatingAgainRestoresReady(testCase)
            controller=testCase.configuredController();
            controller.updatePlan();
            controller.setPlanParameter("orange_expansion_pixels",4);
            testCase.assertEqual(controller.planStatus(),"update_required");

            controller.updatePlan();

            testCase.verifyEqual(controller.planStatus(),"ready");
            testCase.verifyEmpty(controller.stalePlanInputs());
        end

        % ---------------------------------------------------------------
        % C. Staleness: what does and does not invalidate a plan
        % ---------------------------------------------------------------
        function executionAffectingEditsStaleThePlan(testCase)
            % The expected groups are exact sets, not "at least these":
            % attributing a spatial edit to the somata, or a moved vertex
            % to the cell decisions, would make the message that names them
            % misleading. Drawing or deleting a soma genuinely does both -
            % the geometry changes AND the list of cells to decide about
            % does - so those edits name two.
            edits={ ...
                ["somata" "cell_decisions"], ...
                    @(c)c.addSomaPolygon([10 10; 22 10; 22 22; 10 22]); ...
                "somata",@(c)c.updateSomaPolygon("cell_001", ...
                    [26 26; 41 26; 41 41; 26 41]); ...
                ["somata" "cell_decisions"],@(c)c.deleteCell("cell_002"); ...
                "cell_decisions",@(c)c.setCellEligibility("cell_001", ...
                    "StimulationEnabled",false); ...
                "cell_decisions",@(c)c.setCellEligibility("cell_001", ...
                    "RecordingEnabled",false); ...
                "cell_decisions",@(c)c.setCellBlueVoltage("cell_001",2.2); ...
                "protocol",@(c)c.setProtocol( ...
                    adaptive_optopatch.generate_screen_protocol( ...
                        "PulseCount",4,"ModulatorVoltage",1)); ...
                "spatial",@(c)c.setPlanParameter("blue_mask_adjustment_pixels",-3); ...
                "spatial",@(c)c.setPlanParameter("orange_expansion_pixels",5); ...
                "spatial",@(c)c.setPlanParameter("microns_per_pixel",0.4); ...
                "spatial",@(c)c.setPlanParameter("spiral_radius_um",9); ...
                "run_controls",@(c)c.setPlanParameter("repeat_batch_count",3); ...
                "run_controls",@(c)c.setPlanParameter( ...
                    "maximum_velocity_v_per_s",900); ...
                "run_controls",@(c)c.setPlanParameter( ...
                    "allow_camera_rate_override",true)};

            for k=1:size(edits,1)
                controller=testCase.configuredController();
                controller.updatePlan();
                testCase.assertEqual(controller.planStatus(),"ready");

                edits{k,2}(controller);

                testCase.verifyEqual(controller.planStatus(),"update_required", ...
                    sprintf("Edit %d must invalidate the plan.",k));
                testCase.verifyEqual(sort(controller.stalePlanInputs()), ...
                    sort(reshape(string(edits{k,1}),[],1)), ...
                    sprintf("Edit %d must be attributed correctly.",k));
            end
        end

        function loadingADifferentReferenceStalesThePlan(testCase)
            [controller,folder]=testCase.snapshotController();
            controller.setSomaPolygons(testCase.somaPolygons());
            controller.setProtocol(testCase.protocol());
            controller.setPlanParameter("mode","1p_dmd");
            controller.updatePlan();
            testCase.assertEqual(controller.planStatus(),"ready");

            % The same file again: a reload is still a new reference, and it
            % discards the somata the plan was built on.
            controller.loadReferenceChoice("120000plan_cam-OrcaFusion");

            testCase.verifyEqual(controller.planStatus(),"not_ready", ...
                "A reloaded reference has no somata to run.");
            testCase.verifyTrue(isfolder(folder));
        end

        function readOnlyOperationsDoNotStaleThePlan(testCase)
            % Everything a view does while looking at a session. Each of
            % these advances the revision or re-reads from disk; none of
            % them can change what would be acquired.
            controller=testCase.configuredController();
            controller.updatePlan();
            testCase.assertEqual(controller.planStatus(),"ready");

            controller.getState();
            controller.setStatus("polling says hello");
            controller.referenceChoices();
            controller.protocolChoices();
            controller.snapshotChoices();
            controller.referenceDisplayImage();
            controller.spatialPreview("1p_dmd");
            controller.spatialPreview("2p_spiral");
            controller.waveformPreview();
            controller.cellSummary();
            controller.planSummary();
            controller.runProgress();
            controller.saveNextFov();

            testCase.verifyEqual(controller.planStatus(),"ready", ...
                "Looking at a session must not invalidate its plan.");
            testCase.verifyEmpty(controller.stalePlanInputs());
        end

        function savingAFovDoesNotStaleThePlan(testCase)
            % Called out on its own because saveFov REPLACES the whole cell
            % state struct with a freshly built one. Only the decisions in
            % it are execution inputs; its calibration history, notes and
            % timestamps are not, and must not be compared.
            controller=testCase.configuredController();
            controller.setCellBlueVoltage("cell_001",1.6);
            controller.updatePlan();

            controller.saveNextFov();
            controller.saveNextFov();

            testCase.verifyEqual(controller.planStatus(),"ready");
        end

        function theRevisionAdvancesWithoutStalingThePlan(testCase)
            % The claim the design rests on: revision and plan validity are
            % different questions, so one must not be used to answer the
            % other.
            controller=testCase.configuredController();
            controller.updatePlan();
            before=controller.Revision;

            controller.setStatus("something happened");

            testCase.verifyGreaterThan(controller.Revision,before);
            testCase.verifyEqual(controller.planStatus(),"ready");
        end

        % ---------------------------------------------------------------
        % D. The authoritative summary
        % ---------------------------------------------------------------
        function theSummaryCountsAcquisitionsNotEvents(testCase)
            % A manifest row is one acquisition; an acquisition contains
            % many events. Conflating them is the arithmetic a frontend
            % must not be allowed to invent.
            controller=testCase.configuredController();
            controller.setProtocol( ...
                adaptive_optopatch.generate_screen_protocol( ...
                    "PulseCount",5,"ModulatorVoltage",1.2));
            controller.updatePlan();

            summary=controller.planSummary();

            testCase.verifyTrue(summary.prepared);
            testCase.verifyEqual(summary.stimulating_cell_count,2);
            testCase.verifyEqual(summary.acquisitions_per_repeat,2, ...
                "Two stimulating cells, one acquisition each.");
            testCase.verifyEqual(summary.light_event_count,10, ...
                "Five pulses in each of two acquisitions.");
            testCase.verifyEqual(summary.repeats,1);
            testCase.verifyEqual(summary.total_acquisitions,2);
        end

        function deselectingStimChangesTheAuthoritativePlan(testCase)
            controller=testCase.configuredController();
            controller.updatePlan();
            testCase.assertEqual( ...
                controller.planSummary().acquisitions_per_repeat,2);

            controller.setCellEligibility("cell_002", ...
                "StimulationEnabled",false);
            controller.updatePlan();

            summary=controller.planSummary();
            testCase.verifyEqual(summary.stimulating_cell_count,1);
            testCase.verifyEqual(summary.stimulating_cell_ids,"cell_001");
            testCase.verifyEqual(summary.acquisitions_per_repeat,1);
            testCase.verifyEqual(summary.total_acquisitions,1);
        end

        function repeatsMultiplyTheTotalWithoutChangingTheExperiment(testCase)
            controller=testCase.configuredController();
            controller.setPlanParameter("repeat_batch_count",4);
            controller.updatePlan();

            summary=controller.planSummary();

            testCase.verifyEqual(summary.repeats,4);
            testCase.verifyEqual(summary.acquisitions_per_repeat,2, ...
                "Repeats must not change what one repeat contains.");
            testCase.verifyEqual(summary.total_acquisitions,8);
        end

        function thePreparedRepeatCountIsTheOneThatExecutes(testCase)
            % Read from the plan, not from the editable field: the two can
            % only differ while the plan is stale, and a stale plan cannot
            % be run - but the summary must describe the plan either way.
            controller=testCase.configuredController();
            controller.setPlanParameter("repeat_batch_count",2);
            controller.updatePlan();
            controller.setPlanParameter("repeat_batch_count",7);

            testCase.verifyEqual(controller.planSummary().repeats,2, ...
                "The summary describes the prepared plan.");
            testCase.verifyEqual(controller.planStatus(),"update_required");
        end

        function anUnpreparedSummaryClaimsNothing(testCase)
            controller=testCase.configuredController();

            summary=controller.planSummary();

            testCase.verifyFalse(summary.prepared);
            testCase.verifyEqual(summary.total_acquisitions,0);
            testCase.verifyEqual(summary.acquisitions_per_repeat,0);
            testCase.verifyEmpty(summary.stimulating_cell_ids);
        end

        function theSummarySurvivesJsonEncoding(testCase)
            controller=testCase.configuredController();
            controller.updatePlan();

            decoded=jsondecode(jsonencode(controller.getState()));

            testCase.verifyEqual(string(decoded.plan_status),"ready");
            for field=["prepared","stimulating_cell_count", ...
                    "acquisitions_per_repeat","repeats","total_acquisitions"]
                testCase.verifyTrue(isfield(decoded.plan_summary,field), ...
                    sprintf("plan_summary is missing %s.",field));
            end
            for field=["status","can_run","can_update_plan", ...
                    "blocking_issues","stale_inputs","message"]
                testCase.verifyTrue(isfield(decoded.plan_readiness,field), ...
                    sprintf("plan_readiness is missing %s.",field));
            end
        end

        % ---------------------------------------------------------------
        % E. Running the prepared plan
        % ---------------------------------------------------------------
        function runExecutesEveryAcquisitionOfThePlan(testCase)
            controller=testCase.simulationController();
            controller.updatePlan();
            expected=controller.planSummary().acquisitions_per_repeat;
            testCase.assertGreaterThan(expected,1, ...
                "A one-acquisition plan would not prove this.");

            controller.runPreparedPlan();

            state=controller.getState();
            testCase.verifyEqual(state.active_run.completed_trial_count,expected);
            testCase.verifyTrue(state.active_run.batch_complete);
            testCase.verifyEqual(state.run_progress.completed_acquisitions, ...
                expected);
            testCase.verifyEqual(state.run_progress.total_acquisitions,expected);
            testCase.verifyFalse(state.run_progress.running);
        end

        function aCompletedRunLeavesAnUnchangedPlanReusable(testCase)
            controller=testCase.simulationController();
            controller.updatePlan();
            controller.runPreparedPlan();

            testCase.verifyEqual(controller.planStatus(),"ready", ...
                "Nothing changed, so the plan is still the right one.");
            testCase.verifyTrue(controller.legalActions().run);

            % And pressing Run again really runs it again, into its own
            % folder, rather than finding the batch complete and doing
            % nothing.
            before=controller.ActiveRunFolder;
            controller.runPreparedPlan();

            testCase.verifyNotEqual(controller.ActiveRunFolder,before);
            testCase.verifyTrue(controller.getState().active_run.batch_complete);
            testCase.verifyEqual(controller.planStatus(),"ready");
        end

        function repeatsRunTheWholeExperimentThatManyTimes(testCase)
            controller=testCase.simulationController();
            controller.setPlanParameter("repeat_batch_count",3);
            controller.updatePlan();
            perRepeat=controller.planSummary().acquisitions_per_repeat;

            controller.runPreparedPlan();

            progress=controller.runProgress();
            testCase.verifyEqual(progress.repeat_count,3);
            testCase.verifyEqual(progress.total_acquisitions,3*perRepeat);
            testCase.verifyEqual(progress.completed_acquisitions,3*perRepeat);
        end

        function aRunInProgressReportsWhereItHasGot(testCase)
            controller=testCase.simulationController();
            controller.updatePlan();
            observed=struct("status","","running",false,"total",0, ...
                "stopLegal",false,"runLegal",true,"updateLegal",true);

            testCase.probeDuringRun(controller,@probe);

            testCase.verifyEqual(observed.status,"running");
            testCase.verifyTrue(observed.running);
            testCase.verifyEqual(observed.total, ...
                controller.planSummary().acquisitions_per_repeat);
            testCase.verifyTrue(observed.stopLegal, ...
                "Stop after current is the one thing offered during a run.");
            testCase.verifyFalse(observed.runLegal);
            testCase.verifyFalse(observed.updateLegal, ...
                "Plan-changing controls stay protected while running.");

            function probe()
                state=controller.getState();
                observed.status=state.plan_status;
                observed.running=state.run_progress.running;
                observed.total=state.run_progress.total_acquisitions;
                observed.stopLegal=state.legal_actions.stop_after_current;
                observed.runLegal=state.legal_actions.run;
                observed.updateLegal=state.legal_actions.update_plan;
            end
        end

        function runningRefusesEverythingButStopping(testCase)
            controller=testCase.simulationController();
            controller.updatePlan();
            observed=struct("run","","update","","edit","");

            testCase.probeDuringRun(controller,@probe);

            testCase.verifyEqual(observed.run,"not_legal");
            testCase.verifyEqual(observed.update,"not_legal");
            testCase.verifyEqual(observed.edit,"not_legal");

            function probe()
                observed.run=testCase.act(controller,"run").status;
                observed.update=testCase.act(controller,"update_plan").status;
                observed.edit=testCase.act(controller,"set_plan_parameter", ...
                    struct("name","orange_expansion_pixels","value",6)).status;
            end
        end
    end

    % -------------------------------------------------------------------
    % Fixtures
    % -------------------------------------------------------------------
    methods (Access=private)
        function response=act(testCase,controller,action,payload)
            arguments
                testCase %#ok<INUSA>
                controller
                action (1,1) string
                payload = struct()
            end
            response=adaptive_optopatch.apply_controller_action( ...
                controller,action,payload,controller.Revision);
        end

        function probeDuringRun(testCase,controller,probe)
            % The idiom the other during-a-run tests use: a short-delay
            % timer, started just before the run and waited on just after.
            timerObject=timer("StartDelay",0.01,"TimerFcn",@(~,~)probe());
            cleanup=onCleanup(@()delete_timer(timerObject)); %#ok<NASGU>
            start(timerObject);
            controller.runPreparedPlan();
            wait(timerObject);
            testCase.verifyEqual(controller.LifecycleState,"FROZEN", ...
                "The run must have finished before these are checked.");
        end

        function controller=emptyController(testCase)
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp("CameraRoi",[974 100 984 80]), ...
                "RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
        end

        function controller=configuredController(testCase)
            %CONFIGUREDCONTROLLER A describable experiment, nothing prepared.
            controller=testCase.emptyController();
            controller.setReferenceData(testCase.referenceImage(), ...
                testCase.referenceInfo(),testCase.somaPolygons());
            controller.setPlanParameter("mode","1p_dmd");
            controller.setProtocol(testCase.protocol());
        end

        function controller=simulationController(testCase)
            %SIMULATIONCONTROLLER One that can actually execute, headlessly.
            controller=testCase.configuredController();
        end

        function [controller,folder]=snapshotController(testCase)
            folder=testCase.temporaryFolder();
            snap=struct; %#ok<NASGU>
            snap.img=uint16(reshape(mod(1:80*100,4096),80,100));
            snap.name="Orca Fusion";
            snap.bin=1;
            snap.ref2d=imref2d([80 100],[974 1074],[984 1064]);
            snap.timestamp=datetime("now");
            snap.tform=struct("name","DMD_Blue","tform",affine2d());
            save(fullfile(folder,"120000plan_cam-OrcaFusion.mat"),"snap");
            controller=testCase.emptyController();
            controller.SnapshotRoot=folder;
            controller.loadReferenceChoice("120000plan_cam-OrcaFusion");
        end

        function image=referenceImage(~)
            image=ones(80,100);
        end

        function polygons=somaPolygons(~)
            polygons={[25 25; 40 25; 40 40; 25 40], ...
                [60 40; 75 40; 75 55; 60 55]};
        end

        function info=referenceInfo(testCase)
            camera=struct("ROI",[0 0 100 80],"bin",1, ...
                "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
            root=testCase.temporaryFolder();
            info=struct("snapshot_name","plan_workflow_test", ...
                "snapshot_directory",string(root), ...
                "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
                "metadata",struct("rig_name","Virtual_Upright", ...
                    "voltage_camera",camera));
        end

        function value=protocol(~)
            value=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
        end

        function root=temporaryFolder(testCase)
            root=string(tempname);
            mkdir(root);
            testCase.addTeardown(@()remove_if_present(root));
        end
    end
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end

function delete_timer(timerObject)
if ~isempty(timerObject) && isvalid(timerObject)
    stop(timerObject);
    delete(timerObject);
end
end
