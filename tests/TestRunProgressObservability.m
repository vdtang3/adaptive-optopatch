classdef TestRunProgressObservability < matlab.unittest.TestCase
    %TESTRUNPROGRESSOBSERVABILITY How far a run has got, while it is running.
    %   The interface showed 0 of 10 for a whole batch and then 10 of 10.
    %   Three separate defects produced that, and they are tested apart
    %   because each can come back on its own:
    %
    %     1. The controller had no per-acquisition knowledge of its own. It
    %        reconstructed the count by load()ing the run checkpoint, so the
    %        answer existed only on disk and cost a -v7.3 read to get.
    %
    %     2. The checkpoint could not always be FOUND. Its path was chosen
    %        by a rule that required every trial to declare one of exactly
    %        two stimulation_mode strings, while build_manifest also emits
    %        "mixed" and "none" - so an ordinary 1P protocol with a null
    %        control acquisition had no locatable checkpoint at all, and the
    %        count stayed 0 forever.
    %
    %     3. Nothing told a frontend. There was no push, and a poll cannot
    %        be answered while a synchronous run holds MATLAB.
    %
    %   The transport half of (3) is tested in luminos-private
    %   (TestJsRequestQueue); what is tested here is that the controller
    %   knows, and says.
    %
    %   Runs use the packaged simulator. Nothing touches hardware.

    methods (Test)
        % ---------------------------------------------------------------
        % A. Progress advances DURING the run, not only after it
        % ---------------------------------------------------------------
        function completedAcquisitionsAdvanceWhileTheRunIsStillGoing(testCase)
            % The assertion the previous during-a-run tests never made. They
            % checked `running` and the TOTAL, both of which were already
            % right while the count that mattered sat at zero.
            controller=testCase.simulationController();
            controller.updatePlan();
            perRepeat=controller.planSummary().acquisitions_per_repeat;
            testCase.assertGreaterThanOrEqual(perRepeat,2, ...
                "This test needs a batch of at least two acquisitions.");

            seen=[];
            controller.ProgressChangedFcn=@record;

            controller.runPreparedPlan();

            testCase.verifyNotEmpty(seen, ...
                "The runner must report progress at acquisition boundaries.");
            testCase.verifyTrue(any(seen>0 & seen<perRepeat), ...
                sprintf("Progress must pass through an intermediate count. Saw: %s (per repeat %d).", ...
                    mat2str(seen),perRepeat));
            testCase.verifyTrue(issorted(seen), ...
                "The completed count must never go backwards.");

            function record(progress)
                seen(end+1)=progress.completed_acquisitions; %#ok<AGROW>
            end
        end

        function progressIsKnownWithoutReadingTheCheckpoint(testCase)
            % The in-memory answer must be complete on its own: with the
            % checkpoint file deleted, the controller still knows where the
            % run got to. Before, that number lived only on disk.
            controller=testCase.simulationController();
            controller.updatePlan();
            controller.runPreparedPlan();
            expected=controller.planSummary().total_acquisitions;

            delete(fullfile(controller.ActiveRunFolder,"run_checkpoint.mat"));

            progress=controller.runProgress();
            testCase.verifyEqual(progress.completed_acquisitions,expected);
        end

        function progressFinishesAtTheFullCount(testCase)
            controller=testCase.simulationController();
            controller.updatePlan();
            controller.runPreparedPlan();

            state=controller.getState();
            testCase.verifyEqual(state.run_progress.completed_acquisitions, ...
                state.run_progress.total_acquisitions);
            testCase.verifyFalse(state.run_progress.running);
            testCase.verifyTrue(state.active_run.batch_complete);
        end

        function aFailedAcquisitionIsReportedAsFailed(testCase)
            % The simulator's own failure hook, so the status the observer
            % sees is the one the runner actually wrote to the trial.
            [controller,app]=testCase.simulationController();
            controller.updatePlan();
            app.FailOnAcquisitionNumber=1;
            statuses=strings(0,1);
            controller.ProgressChangedFcn=@collect;

            testCase.verifyError(@()controller.runPreparedPlan(), ...
                ?MException);

            testCase.verifyTrue(any(statuses=="acquiring"), ...
                "The acquisition must be reported as started.");
            testCase.verifyTrue(any(statuses=="failed"), ...
                "And reported as failed, rather than simply stopping.");
            testCase.verifyEqual(controller.getState().run_progress.completed_acquisitions,0, ...
                "A failed acquisition is not a completed one.");

            function collect(progress)
                statuses(end+1,1)=string(progress.current_status); %#ok<AGROW>
            end
        end

        % ---------------------------------------------------------------
        % B. The checkpoint is findable for every manifest the runner runs
        % ---------------------------------------------------------------
        function anOrdinaryOnePhotonBatchCompletes(testCase)
            controller=testCase.simulationController();
            testCase.verifyBatchCompletes(controller);
        end

        % NOTE ON THE NULL-CONTROL CASE. The manifest shape that broke
        % checkpoint lookup - trials whose stimulation_mode is not all one
        % of two strings - is pinned by theCheckpointIsRoutedLikeTheRunner
        % below, directly against the routing rule, rather than by
        % fabricating a protocol here. Building one by hand produced an
        % acquisition whose events had no stimulation source at all, which
        % the preflight ownership audit correctly refuses for unrelated
        % reasons, so the fixture would have been testing the wrong thing
        % and would have been fragile besides. The unit test states the
        % rule exactly; the end-to-end tests either side of it prove the
        % shared helper is the one the controller and the runner both use.

        function theCheckpointIsRoutedLikeTheRunner(testCase)
            % One decision, not two. manifest_execution_route is what
            % run_mixed_manifest picks a runner with, so the controller
            % cannot look for a file the runner did not write.
            trials=table(["1p_dmd";"none"],[1;0],[0;0], ...
                'VariableNames',{'stimulation_mode', ...
                'onephoton_event_count','twophoton_event_count'});
            route=adaptive_optopatch.manifest_execution_route(trials);
            testCase.verifyEqual(route.runner,"1p_dmd");
            testCase.verifyEqual(route.checkpoint_file,"run_checkpoint.mat");

            twoPhoton=table(["2p_spiral";"none"],[0;0],[1;0], ...
                'VariableNames',{'stimulation_mode', ...
                'onephoton_event_count','twophoton_event_count'});
            route=adaptive_optopatch.manifest_execution_route(twoPhoton);
            testCase.verifyEqual(route.runner,"2p_spiral");
            testCase.verifyEqual(route.checkpoint_file,"run_2p_checkpoint.mat");

            mixed=table(["mixed";"1p_dmd"],[1;1],[1;0], ...
                'VariableNames',{'stimulation_mode', ...
                'onephoton_event_count','twophoton_event_count'});
            route=adaptive_optopatch.manifest_execution_route(mixed);
            testCase.verifyEqual(route.runner,"1p_dmd", ...
                "Any 1P event sends the batch to the 1P runner.");
            testCase.verifyEqual(route.checkpoint_file,"run_checkpoint.mat");
        end

        function rerunningACompletedBatchStartsANewOne(testCase)
            % The silent no-op. With no locatable checkpoint the batch never
            % looked complete, so runPreparedPlan skipped startNewBatch and
            % handed the same folder back to the runner - which resumed a
            % finished checkpoint and returned immediately.
            controller=testCase.simulationController();
            controller.updatePlan();
            controller.runPreparedPlan();
            firstFolder=controller.ActiveRunFolder;
            testCase.assertTrue(controller.getState().active_run.batch_complete, ...
                "The first batch must be complete before rerunning it.");

            controller.runPreparedPlan();

            testCase.verifyNotEqual(controller.ActiveRunFolder,firstFolder, ...
                "Run on a completed batch must start a new batch.");
            testCase.verifyTrue(isfolder(firstFolder), ...
                "The previous batch stays on disk.");
            state=controller.getState();
            testCase.verifyEqual(state.run_progress.completed_acquisitions, ...
                state.run_progress.total_acquisitions, ...
                "The new batch must actually have executed.");
        end

        % ---------------------------------------------------------------
        % C. The push channel is separate from the GUI's callback
        % ---------------------------------------------------------------
        function progressDoesNotStealTheStateChangedCallback(testCase)
            % StateChangedFcn belongs to the MATLAB planning window. If
            % progress used it, installing one would stop that window
            % refreshing.
            controller=testCase.simulationController();
            controller.updatePlan();
            stateChanges=0;
            progressChanges=0;
            controller.StateChangedFcn=@()countState();
            controller.ProgressChangedFcn=@(~)countProgress();

            controller.runPreparedPlan();

            testCase.verifyGreaterThan(progressChanges,0);
            testCase.verifyGreaterThan(stateChanges,0, ...
                "The planning window must still be told to redraw.");

            function countState(), stateChanges=stateChanges+1; end
            function countProgress(), progressChanges=progressChanges+1; end
        end

        function progressDoesNotBumpTheRevision(testCase)
            % A revision bump per acquisition would make every browser's
            % uncommitted draft look stale for the length of a run, and
            % would move the revision under a stop_after_current the
            % operator had already pressed.
            %
            % What is asserted is the ACQUISITION boundary specifically.
            % The repeat loop's own status line ("Running repeat 1 of 1")
            % does bump the revision, and always has - that is a state
            % change a view should redraw for. Reporting where an
            % acquisition got to is not.
            controller=testCase.simulationController();
            controller.updatePlan();
            seen=struct("status",{},"revision",{});
            controller.ProgressChangedFcn=@record;

            controller.runPreparedPlan();

            statuses=string({seen.status});
            revisions=[seen.revision];
            acquiring=find(statuses=="acquiring");
            testCase.assertNotEmpty(acquiring, ...
                "The runner must report the start of an acquisition.");
            for k=reshape(acquiring,1,[])
                if k+1>numel(revisions), continue; end
                testCase.verifyEqual(revisions(k+1),revisions(k), ...
                    sprintf("The revision moved between the start and the end of acquisition %d (%g -> %g).", ...
                        k,revisions(k),revisions(k+1)));
            end

            function record(progress)
                seen(end+1)=struct("status",string(progress.current_status), ...
                    "revision",progress.revision); %#ok<AGROW>
            end
        end

        function aBrokenProgressObserverCannotStopTheRun(testCase)
            controller=testCase.simulationController();
            controller.updatePlan();
            controller.ProgressChangedFcn=@(~)error("Test:Boom","boom");

            warningState=warning("off","adaptive_optopatch:ProgressObserverFailed");
            restore=onCleanup(@()warning(warningState)); %#ok<NASGU>
            controller.runPreparedPlan();

            state=controller.getState();
            testCase.verifyEqual(state.run_progress.completed_acquisitions, ...
                state.run_progress.total_acquisitions, ...
                "The acquisitions still happened.");
        end
    end

    % -------------------------------------------------------------------
    methods (Access=private)
        function verifyBatchCompletes(testCase,controller)
            if controller.planStatus()~="ready", controller.updatePlan(); end
            controller.runPreparedPlan();
            state=controller.getState();
            total=state.run_progress.total_acquisitions;
            testCase.assertGreaterThan(total,0);
            testCase.verifyEqual(state.run_progress.completed_acquisitions,total, ...
                "Every acquisition of the batch must be counted.");
            testCase.verifyTrue(state.active_run.batch_complete);
            testCase.verifyTrue(state.legal_actions.start_new_batch);
        end

        function [controller,app]=emptyController(testCase)
            app=simulatedLuminosApp("CameraRoi",[974 100 984 80]);
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",app,"RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
        end

        function [controller,app]=configuredController(testCase)
            [controller,app]=testCase.emptyController();
            controller.setReferenceData(testCase.referenceImage(), ...
                testCase.referenceInfo(),testCase.somaPolygons());
            controller.setPlanParameter("mode","1p_dmd");
            controller.setProtocol(testCase.protocol());
        end

        function [controller,app]=simulationController(testCase)
            [controller,app]=testCase.configuredController();
        end

        function image=referenceImage(~)
            image=uint16(reshape(mod(1:80*100,4096),80,100));
        end

        function polygons=somaPolygons(~)
            polygons={[25 25; 40 25; 40 40; 25 40], ...
                [60 40; 75 40; 75 55; 60 55]};
        end

        function info=referenceInfo(testCase)
            camera=struct("name","Orca Fusion","ROI",[0 0 100 80],"bin",1, ...
                "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
            root=testCase.temporaryFolder();
            info=struct("snapshot_name","run_progress_test", ...
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
