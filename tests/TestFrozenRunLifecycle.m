classdef TestFrozenRunLifecycle < matlab.unittest.TestCase
    %TESTFROZENRUNLIFECYCLE Freeze, run, resume - and what editing cannot reach.
    %   Freezing writes an immutable plan to a run folder and every later
    %   acquisition of that run comes from it. The invariant this suite exists
    %   to hold is that nothing an operator does to the EDITABLE session
    %   afterwards can change what the frozen run executes: not a parameter
    %   edit, not a different protocol, not a different modality, and not a
    %   recalibration of the rig itself.
    %
    %   Driven through AdaptiveOptopatchApp because the failure being guarded
    %   against is a GUI one - the planning window and the archived plan
    %   drifting apart. TestExecutionBatchWorkflow owns what happens AFTER a
    %   frozen run completes; TestFrozenExecutionInvariants owns the
    %   hardware-timing invariants a frozen plan must still satisfy.

    methods (Test)
        function unifiedOnePhotonRunFreezesAllArtifacts(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            snapsRoot=fullfile(root,"Snaps"); mkdir(snapsRoot);
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",snapsRoot); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            app.setReferenceData(ones(80,100),AoFixtures.unifiedInfo(root), ...
                {[40 30;60 30;60 50;40 50]});
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1.3);
            app.setPulseProtocol(protocol);
            app.setPlanParameter("mode","1p_dmd");
            run=app.runNext();
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyTrue(run.simulation);
            for filename=["reference_model.mat","pattern_bundle.mat", ...
                    "pulse_protocol.mat","trial_manifest.mat", ...
                    "planning_session.mat","fov_state.mat","run_checkpoint.mat"]
                testCase.verifyTrue(isfile(fullfile(app.ActiveRunFolder,filename)), ...
                    "Missing frozen run artifact "+filename);
            end
            frozenProtocol=adaptive_optopatch.load_protocol( ...
                fullfile(app.ActiveRunFolder,"pulse_protocol.mat"));
            frozenFov=adaptive_optopatch.load_fov_state( ...
                fullfile(app.ActiveRunFolder,"fov_state.mat"));
            savedManifest=load(fullfile(app.ActiveRunFolder,"trial_manifest.mat"),"manifest");
            savedTargets=load(fullfile(app.ActiveRunFolder,"pattern_bundle.mat"),"targets");
            testCase.verifyEqual(frozenProtocol.events.target_cell_id, ...
                savedManifest.manifest.trials.pulse_schedule{1}.events.target_cell_id);
            testCase.verifyEqual(frozenProtocol.events.command_voltage_v,1.3);
            testCase.verifyEqual(string({frozenFov.cells.cell_id}),"cell_001");
            testCase.verifyTrue(isfield(savedManifest.manifest,"advisories"));
            testCase.verifyTrue(isfield(savedManifest.manifest,"software"));
            testCase.verifyEqual(savedTargets.targets.parameters.orange_expansion_pixels, ...
                frozenFov.orange_expansion_pixels);
            testCase.verifyEqual(savedTargets.targets.parameters.blue_mask_adjustment_pixels, ...
                frozenFov.blue_mask_adjustment_pixels);
            testCase.verifyEqual(savedTargets.targets.orange_combined_mask, ...
                any(savedTargets.targets.orange_camera_masks,3));
            acquisition=load(fullfile(run.trials.experiment_directory, ...
                "output_data.mat"),"adaptive_optopatch_record");
            testCase.verifyEqual( ...
                acquisition.adaptive_optopatch_record.run_directory, ...
                app.ActiveRunFolder);
            [~,runName]=fileparts(app.ActiveRunFolder);
            expectedReference="Snaps/"+string(runName)+"/reference_model.mat";
            testCase.verifyEqual( ...
                acquisition.adaptive_optopatch_record.reference_model_path, ...
                expectedReference);
            testCase.verifyFalse(app.ControlsLocked);
        end

        function unifiedTwoPhotonPreviewAndRunComplete(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            snapsRoot=fullfile(root,"Snaps"); mkdir(snapsRoot);
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",snapsRoot); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            image=ones(80,100); image(10:15,10:15)=0;
            app.setReferenceData(image,AoFixtures.unifiedInfo(root), ...
                {[40 30;60 30;60 50;40 50]});
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1,"ModulatorVoltage",1.5, ...
                "StimulationSource","2p_spiral");
            app.setPulseProtocol(protocol);
            plan=app.previewCurrentPlan();
            testCase.verifyEqual(unique( ...
                string(plan.manifest.trials.stimulation_mode)),"2p_spiral");
            run=app.runNext();
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyTrue(isfile(fullfile( ...
                run.trials.experiment_directory, ...
                "adaptive_optopatch_2p_waveforms.mat")));
            acquisition=load(fullfile(run.trials.experiment_directory, ...
                "output_data.mat"),"adaptive_optopatch_record");
            testCase.verifyEqual( ...
                acquisition.adaptive_optopatch_record.run_directory, ...
                app.ActiveRunFolder);
            [~,runName]=fileparts(app.ActiveRunFolder);
            expectedReference="Snaps/"+string(runName)+"/reference_model.mat";
            testCase.verifyEqual( ...
                acquisition.adaptive_optopatch_record.reference_model_path, ...
                expectedReference);
        end

        function unifiedMixedAcquisitionExecutesExactlyOnce(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            image=ones(80,100); image(10:15,10:15)=0;
            app.setReferenceData(image,AoFixtures.unifiedInfo(root), ...
                {[40 30;60 30;60 50;40 50]});
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"PulseDurationMs",10, ...
                "DarkIntervalMs",[400 400],"PreDelayMs",200, ...
                "PostDelayMs",200,"ModulatorVoltage",0.2);
            protocol.acquisitions.events.stimulation_source=["1p_dmd";"2p_spiral"];
            protocol=adaptive_optopatch.normalize_protocol(protocol);
            app.setPulseProtocol(protocol);
            plan=app.buildCurrentPlan();
            testCase.verifyTrue(plan.manifest.trials.has_mixed_sources(1));
            run=app.runAll();
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyEqual(numel(sim.AcquisitionHistory),1, ...
                "One mixed manifest row must issue one DAQ acquisition.");
            testCase.verifyTrue(run.trials.waveform_summary{1}.has_mixed_sources);
        end

        function unifiedResumeUsesFrozenManifest(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            rois={[25 25;40 25;40 40;25 40], ...
                [60 40;75 40;75 55;60 55]};
            app.setReferenceData(ones(80,100),AoFixtures.unifiedInfo(root),rois);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            app.setPulseProtocol(protocol);
            app.setPlanParameter("mode","1p_dmd");
            first=app.runNext();
            frozenFolder=app.ActiveRunFolder;
            testCase.verifyEqual(sum(first.trials.acquisition_status=="completed"),1);
            changedProtocol=adaptive_optopatch.generate_screen_protocol("PulseCount",7);
            app.setPulseProtocol(changedProtocol);
            app.setPlanParameter("mode","2p_spiral");
            app.resumeRun(frozenFolder);
            frozen=app.ActiveRunPlan;
            testCase.verifyTrue(all(frozen.manifest.trials.stimulation_mode=="1p_dmd"));
            testCase.verifyEqual( ...
                height(frozen.manifest.trials.pulse_schedule{1}.events),1);
            app.resumeRun(frozenFolder);
            resumed=app.runAll();
            testCase.verifyEqual(sum(resumed.trials.acquisition_status=="completed"),2);
        end

        function frozenRunContinuesAfterEditableCalibrationChange(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            rois={[25 25;40 25;40 40;25 40], ...
                [60 40;75 40;75 55;60 55]};
            app.setReferenceData(ones(80,100),AoFixtures.unifiedInfo(root),rois);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            app.setPulseProtocol(protocol);
            app.setPlanParameter("mode","1p_dmd");
            first=app.runNext();
            testCase.verifyEqual(sum(first.trials.acquisition_status=="completed"),1);
            frozenFolder=app.ActiveRunFolder;
            frozenPlan=app.ActiveRunPlan;
            testCase.verifyEqual(app.PlanState,"FROZEN");

            % Ordinary per-cell calibration edit to the editable FOV after the
            % first acquisition of a multi-cell frozen run has completed.
            app.setPlanParameter("blue_mask_adjustment_pixels",3);

            testCase.verifyTrue(app.EditableStateChanged);
            testCase.verifyEqual(app.PlanState,"FROZEN");
            testCase.verifyEqual(app.ActiveRunFolder,frozenFolder);
            testCase.verifyEqual(app.ActiveRunPlan,frozenPlan);

            second=app.runNext();
            testCase.verifyEqual(app.ActiveRunFolder,frozenFolder, ...
                "Run next must continue the original frozen folder, not freeze a new one.");
            testCase.verifyEqual(sum(second.trials.acquisition_status=="completed"),2);
            testCase.verifyEqual( ...
                second.trials.pulse_schedule{1}.events.blue_mask_adjustment_pixels, ...
                first.trials.pulse_schedule{1}.events.blue_mask_adjustment_pixels, ...
                "The next acquisition must come from the original frozen manifest.");
        end

        function resumedFrozenRunContinuesAfterEditableChange(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            rois={[25 25;40 25;40 40;25 40], ...
                [60 40;75 40;75 55;60 55]};
            app.setReferenceData(ones(80,100),AoFixtures.unifiedInfo(root),rois);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            app.setPulseProtocol(protocol);
            app.setPlanParameter("mode","1p_dmd");
            first=app.runNext();
            testCase.verifyEqual(sum(first.trials.acquisition_status=="completed"),1);
            frozenFolder=app.ActiveRunFolder;

            app.resumeRun(frozenFolder);
            resumedPlan=app.ActiveRunPlan;

            % An editable FOV/GUI change made after resuming must not silently
            % replace or forget the archived frozen run.
            app.setPlanParameter("mode","2p_spiral");
            app.setPlanParameter("blue_mask_adjustment_pixels",3);

            testCase.verifyTrue(app.EditableStateChanged);
            testCase.verifyEqual(app.PlanState,"FROZEN");
            testCase.verifyEqual(app.ActiveRunFolder,frozenFolder);
            testCase.verifyEqual(app.ActiveRunPlan,resumedPlan);

            resumed=app.runAll();
            testCase.verifyEqual(app.ActiveRunFolder,frozenFolder);
            testCase.verifyTrue(all(resumed.trials.stimulation_mode=="1p_dmd"), ...
                "Continuation must consume the archived frozen manifest, not the edited mode.");
            testCase.verifyEqual(sum(resumed.trials.acquisition_status=="completed"),2);
        end

        function frozenTwoPhotonRunIgnoresLaterActiveCalibrationChange(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            image=ones(80,100); image(10:15,10:15)=0;
            app.setReferenceData(image,AoFixtures.unifiedInfo(root), ...
                {[40 30;60 30;60 50;40 50]});
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1,"ModulatorVoltage",1.5, ...
                "StimulationSource","2p_spiral");
            app.setPulseProtocol(protocol);
            app.freezeCurrentPlan();
            plan=app.ActiveRunPlan;
            testCase.verifyEqual(unique( ...
                string(plan.manifest.trials.stimulation_mode)),"2p_spiral");
            tformA=plan.reference.scanner.tform;
            target=plan.targets.targets(1);
            expectedParkVA=adaptive_optopatch.camera_to_galvo_volts( ...
                tformA,target.parking_point_xy);

            % Recalibrate the rig after the run was frozen: distinctly different
            % scale/offset from A, applied to both the "active calibration" the
            % simulator reports and the live scanner device (as a real
            % recalibration workflow would leave it).
            profile=adaptive_optopatch.virtual_upright_2p_profile();
            calibrationB=AoFixtures.galvoCalibration(profile,"CALIBRATION_B", ...
                affinetform2d([400 0 2048;0 400 2048;0 0 1]));
            sim.applyGalvoCalibration(calibrationB);
            expectedParkVB=adaptive_optopatch.camera_to_galvo_volts( ...
                calibrationB.calibration.tform,target.parking_point_xy);
            testCase.verifyGreaterThan(max(abs(expectedParkVA-expectedParkVB)),1e-3);

            run=app.runNext();
            testCase.verifyEqual(sum(run.trials.acquisition_status=="completed"),1);
            saved=load(fullfile(run.trials.experiment_directory(1), ...
                "adaptive_optopatch_2p_waveforms.mat"),"actual_waveforms");
            testCase.verifyEqual(saved.actual_waveforms.parking_v,expectedParkVA,"AbsTol",1e-9);
            testCase.verifyGreaterThan( ...
                max(abs(saved.actual_waveforms.parking_v-expectedParkVB)),1e-3, ...
                "The executed waveform must not have used the newly active calibration.");
        end

        function resumedTwoPhotonRunAlsoUsesFrozenCalibration(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            image=ones(80,100); image(10:15,10:15)=0;
            rois={[25 25;40 25;40 40;25 40], ...
                [60 40;75 40;75 55;60 55]};
            app.setReferenceData(image,AoFixtures.unifiedInfo(root),rois);
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1,"ModulatorVoltage",1.5, ...
                "StimulationSource","2p_spiral");
            app.setPulseProtocol(protocol);
            first=app.runNext();
            testCase.verifyEqual(sum(first.trials.acquisition_status=="completed"),1);
            frozenFolder=app.ActiveRunFolder;
            plan=app.ActiveRunPlan;
            tformA=plan.reference.scanner.tform;
            secondTarget=plan.targets.targets( ...
                plan.manifest.trials.target_index(2));
            expectedParkVA=adaptive_optopatch.camera_to_galvo_volts( ...
                tformA,secondTarget.parking_point_xy);

            profile=adaptive_optopatch.virtual_upright_2p_profile();
            calibrationB=AoFixtures.galvoCalibration(profile,"CALIBRATION_B", ...
                affinetform2d([400 0 2048;0 400 2048;0 0 1]));
            sim.applyGalvoCalibration(calibrationB);
            expectedParkVB=adaptive_optopatch.camera_to_galvo_volts( ...
                calibrationB.calibration.tform,secondTarget.parking_point_xy);

            % Close/reopen the frozen run before continuing the acquisition.
            app.resumeRun(frozenFolder);
            resumed=app.runNext();
            testCase.verifyEqual(sum(resumed.trials.acquisition_status=="completed"),2);
            saved=load(fullfile(resumed.trials.experiment_directory(2), ...
                "adaptive_optopatch_2p_waveforms.mat"),"actual_waveforms");
            testCase.verifyEqual(saved.actual_waveforms.parking_v,expectedParkVA,"AbsTol",1e-9);
            testCase.verifyGreaterThan( ...
                max(abs(saved.actual_waveforms.parking_v-expectedParkVB)),1e-3, ...
                "The resumed acquisition must not have used the newly active calibration.");
        end

        function hardwareDiscoveryDoesNotOverwriteFrozenScannerTransform(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            image=ones(80,100); image(10:15,10:15)=0;
            app.setReferenceData(image,AoFixtures.unifiedInfo(root), ...
                {[40 30;60 30;60 50;40 50]});
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1,"ModulatorVoltage",1.5, ...
                "StimulationSource","2p_spiral");
            app.setPulseProtocol(protocol);

            profile=adaptive_optopatch.virtual_upright_2p_profile();
            scanner=sim.getDevice("Scanning_Device","name",profile.scanner.name);
            beforeTform=scanner.tform;

            app.previewCurrentPlan();
            testCase.verifyEqual(scanner.tform,beforeTform, ...
                "Preview must not mutate the live scanner's targeting transform.");

            report=app.preflightCurrentPlan(); %#ok<NASGU>
            testCase.verifyEqual(scanner.tform,beforeTform, ...
                "Configuration check must not mutate the live scanner's targeting transform.");
        end

        function explicitFreezeReplacesActiveFrozenRun(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            rois={[25 25;40 25;40 40;25 40], ...
                [60 40;75 40;75 55;60 55]};
            app.setReferenceData(ones(80,100),AoFixtures.unifiedInfo(root),rois);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            app.setPulseProtocol(protocol);
            app.setPlanParameter("mode","1p_dmd");
            first=app.runNext();
            testCase.verifyEqual(sum(first.trials.acquisition_status=="completed"),1);
            firstFolder=app.ActiveRunFolder;

            app.setPlanParameter("blue_mask_adjustment_pixels",3);
            testCase.verifyEqual(app.ActiveRunFolder,firstFolder);

            % The operator's explicit "Freeze new run" action is the only
            % way to replace the active frozen run, and it must be reachable
            % from the GUI rather than only programmatically.
            newRunButton=findall(app.Figure,"Text","Freeze new run");
            testCase.verifyNotEmpty(newRunButton);
            newRunButton.ButtonPushedFcn(newRunButton,[]);

            testCase.verifyNotEqual(app.ActiveRunFolder,firstFolder);
            testCase.verifyTrue(any(contains(app.statusText(),firstFolder)), ...
                "The replaced run must be named so it can still be resumed.");
            testCase.verifyEqual(app.PlanState,"FROZEN");
            testCase.verifyFalse(app.EditableStateChanged);
            secondManifest=load(fullfile(app.ActiveRunFolder,"trial_manifest.mat"),"manifest");
            testCase.verifyEqual( ...
                secondManifest.manifest.trials.pulse_schedule{1}.events.blue_mask_adjustment_pixels,3);
            testCase.verifyTrue(isfile(fullfile(firstFolder,"trial_manifest.mat")), ...
                "The previously frozen run's artifacts must remain on disk.");
        end

        function threadsUnifiedGuiStopRequestIntoTwoPhotonRunner(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            rois={[40 30;60 30;60 50;40 50], ...
                [40 55;60 55;60 75;40 75]};
            app.setReferenceData(ones(80,100),AoFixtures.unifiedInfo(root),rois);
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1,"ModulatorVoltage",1.5, ...
                "StimulationSource","2p_spiral");
            app.setPulseProtocol(protocol);
            testCase.verifyEqual(unique( ...
                string(app.buildCurrentPlan().manifest.trials.stimulation_mode)),"2p_spiral");

            app.freezeCurrentPlan();
            plan=app.ActiveRunPlan;
            stopButton=findall(app.Figure,"Text","Stop after current");
            stopButton.ButtonPushedFcn(stopButton,[]);
            testCase.verifyEqual(string(stopButton.Text),"Stop requested");

            run=adaptive_optopatch.run_2p_manifest(plan.manifest,plan.targets,sim, ...
                "ReleaseLevel","standard","OutputDirectory",app.ActiveRunFolder, ...
                "Resume",true, ...
                "StopRequestedFcn",@()string(stopButton.Text)=="Stop requested");
            testCase.verifyEqual(sum(run.trials.acquisition_status=="completed"),1);
            testCase.verifyEqual(sum(run.trials.acquisition_status=="planned"),1);

            resumed=app.runAll();
            testCase.verifyEqual(sum(resumed.trials.acquisition_status=="completed"),2);
            testCase.verifyEqual(string(stopButton.Text),"Stop after current");
        end
    end
end
