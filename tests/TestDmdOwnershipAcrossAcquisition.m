classdef TestDmdOwnershipAcrossAcquisition < matlab.unittest.TestCase
    % Whether the DMD state AO programmed is the state the acquisition
    % starts with.
    %
    % The failure being regressed: AO programs the Blue DMD (a static
    % target, or a mask bank with a FLUT playlist over it) and the Orange
    % recording mask, verifies both, and hands over to Luminos. Luminos
    % acquisition startup then reloads each DMD's retained generic
    % pattern_stack for every DMD whose auto_write_stack is set - after the
    % programming and before the first trigger. Every AO artifact is
    % correct; the mirrors show something else. It explains why a
    % standalone DMD or FLUT diagnostic passes while a real acquisition
    % does not, because the diagnostic never goes through acquisition
    % startup.
    %
    % So every test here begins from the state that produced it:
    %
    %   auto_write_stack = true, a nonempty stale pattern_stack, and an AO
    %   target that is nothing like it.
    %
    % and the acquisition path they run through is Luminos's own
    % Write_Pending_Dmd_Stacks and Verify_Owned_Dmd_Patterns, reached
    % through the simulated backend, not an AO-side paraphrase of them. A
    % paraphrase would have kept agreeing with itself.

    properties
        OutputRoot string
    end

    methods (TestMethodSetup)
        function makeOutputRoot(testCase)
            testCase.OutputRoot=string(tempname);
            mkdir(testCase.OutputRoot);
            testCase.addTeardown(@()rmdir(testCase.OutputRoot,"s"));
        end
    end

    methods (Test)

        % --- 1: Blue, static target ---------------------------------------

        function blueStaticTargetSurvivesAcquisitionStartup(testCase)
            [app,manifest,targets]=testCase.staleStackRig();
            blue=app.getDevice("DMD","name","DMD_Blue");

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "BlankDmdAfterTrial",false, ...
                "OutputDirectory",testCase.OutputRoot);

            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            configuration=run.trials.target_configuration{1};
            testCase.verifyEqual(logical(blue.Target), ...
                logical(configuration.dmd_reference_mask), ...
                "The generic stack replaced the AO target.");
            testCase.verifyEqual(blue.StackWriteCount,0);
            testCase.verifyEqual(testCase.startupAction(app,"DMD_Blue"), ...
                "skipped_owned");
            % Localized, not the field-wide stale frame: a check that would
            % still fail if the pattern had been replaced by something of
            % the right class but the wrong content.
            testCase.verifyLessThan(nnz(blue.Target)/numel(blue.Target),0.5);
        end

        % --- 2: Blue, FLUT / sequenced target -----------------------------

        function blueSequencedPlaylistSurvivesAcquisitionStartup(testCase)
            [app,manifest,targets]=testCase.staleStackRig("Sequenced",true);
            blue=app.getDevice("DMD","name","DMD_Blue");

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "BlankDmdAfterTrial",false, ...
                "OutputDirectory",testCase.OutputRoot);

            configuration=run.trials.target_configuration{1};
            testCase.verifyEqual(configuration.execution_mode,"flut_playlist", ...
                "This fixture no longer exercises the sequenced path.");
            testCase.verifyEqual(blue.StackWriteCount,0, ...
                "The generic stack was written over the FLUT playlist.");
            testCase.verifyEqual(numel(blue.playlist), ...
                configuration.playlist_entry_count);
            testCase.verifyEqual(blue.playlist_mode,"slave");
            testCase.verifyEqual(testCase.startupAction(app,"DMD_Blue"), ...
                "skipped_owned");
        end

        % --- 3: Orange recording mask -------------------------------------

        function orangeRecordingMaskSurvivesAcquisitionStartup(testCase)
            [app,manifest,targets]=testCase.staleStackRig();
            orange=app.getDevice("DMD","name","DMD_Orange");

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "BlankDmdAfterTrial",false, ...
                "OutputDirectory",testCase.OutputRoot);

            configuration=run.trials.orange_configuration{1};
            testCase.verifyTrue(configuration.loaded);
            testCase.verifyEqual(logical(orange.Target), ...
                logical(configuration.dmd_reference_mask));
            testCase.verifyEqual(orange.StackWriteCount,0);
            testCase.verifyEqual(testCase.startupAction(app,"DMD_Orange"), ...
                "skipped_owned");
        end

        % --- 4: restored after success ------------------------------------

        function autoWriteStackIsRestoredAfterASuccessfulRun(testCase)
            [app,manifest,targets]=testCase.staleStackRig();
            blue=app.getDevice("DMD","name","DMD_Blue");
            orange=app.getDevice("DMD","name","DMD_Orange");

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "OutputDirectory",testCase.OutputRoot);

            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyTrue(blue.auto_write_stack);
            testCase.verifyTrue(orange.auto_write_stack);
            testCase.verifyEqual(blue.pattern_owner,"");
            testCase.verifyEqual(orange.pattern_owner,"");
            % The operator's stack is still there to be written next time.
            testCase.verifyEqual(size(blue.pattern_stack,3),3);
            % And the run archives what it suspended.
            testCase.verifyTrue(all([run.dmd_ownership.claimed]));
            testCase.verifyTrue(all([run.dmd_ownership.previous_auto_write_stack]));
        end

        function anUnsetAutoWriteStackIsNotTurnedOnByTheRun(testCase)
            % Restoring means restoring. A rig that never had the toggle set
            % must not come back with it set.
            [app,manifest,targets]=testCase.staleStackRig("AutoWriteStack",false);
            blue=app.getDevice("DMD","name","DMD_Blue");

            adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "OutputDirectory",testCase.OutputRoot);

            testCase.verifyFalse(blue.auto_write_stack);
        end

        % --- 5: restored after failure ------------------------------------

        function autoWriteStackIsRestoredAfterAFailedAcquisition(testCase)
            [app,manifest,targets]=testCase.staleStackRig();
            blue=app.getDevice("DMD","name","DMD_Blue");
            orange=app.getDevice("DMD","name","DMD_Orange");
            app.FailOnAcquisitionNumber=1;

            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:SimulatedAcquisitionFailure");

            testCase.verifyTrue(blue.auto_write_stack);
            testCase.verifyTrue(orange.auto_write_stack);
            testCase.verifyEqual(blue.pattern_owner,"");
            testCase.verifyEqual(orange.pattern_owner,"");
        end

        function ownershipIsReleasedWhenTheRunFailsBeforeArming(testCase)
            % The pre-arm failure path, which happens before
            % app.acquisition_active is ever set and so before most cleanup
            % has anything to key off.
            [app,manifest,targets]=testCase.staleStackRig();
            blue=app.getDevice("DMD","name","DMD_Blue");
            laser=app.getDevice("Laser_Device");
            laser.FailOnStart=true;

            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:SimulatedLaserStartFailure");

            testCase.verifyEqual(blue.pattern_owner,"");
            testCase.verifyTrue(blue.auto_write_stack);
        end

        % --- 6: generic acquisitions are unchanged ------------------------

        function anUnownedDmdStillLoadsItsStackAtStartup(testCase)
            % The same Luminos function, on a device nobody claimed: the
            % behaviour a non-AO acquisition depends on.
            adaptive_optopatch.require_luminos_acquisition_helpers();
            app=testCase.rigWithStaleStacks();
            blue=app.getDevice("DMD","name","DMD_Blue");

            report=Write_Pending_Dmd_Stacks(app.getDevice("DMD"));

            testCase.verifyEqual(blue.StackWriteCount,1);
            testCase.verifyEqual(blue.StackMode,"slave");
            testCase.verifyTrue(all(string({report.action})=="wrote_stack"));
        end

        function aClaimOnOneDmdDoesNotSuppressAnother(testCase)
            adaptive_optopatch.require_luminos_acquisition_helpers();
            app=testCase.rigWithStaleStacks();
            blue=app.getDevice("DMD","name","DMD_Blue");
            orange=app.getDevice("DMD","name","DMD_Orange");
            record=adaptive_optopatch.claim_dmd_pattern_ownership(blue);

            Write_Pending_Dmd_Stacks(app.getDevice("DMD"));

            testCase.verifyEqual(blue.StackWriteCount,0);
            testCase.verifyEqual(orange.StackWriteCount,1);
            adaptive_optopatch.release_dmd_pattern_ownership(record);
        end

        % --- The final-state check is real --------------------------------

        function aPatternReplacedAfterProgrammingStopsTheAcquisition(testCase)
            % What the check at the end of acquisition preparation is for.
            % A successful, verified write is not the invariant; "still the
            % same immediately before the trigger" is.
            adaptive_optopatch.require_luminos_acquisition_helpers();
            app=testCase.rigWithStaleStacks();
            blue=app.getDevice("DMD","name","DMD_Blue");
            record=adaptive_optopatch.claim_dmd_pattern_ownership(blue);
            testCase.addTeardown( ...
                @()adaptive_optopatch.release_dmd_pattern_ownership(record));

            blue.Target=testCase.asymmetricMask(blue);
            blue.Write_Static();
            adaptive_optopatch.record_owned_dmd_pattern(blue);

            testCase.verifyWarningFree(@()Verify_Owned_Dmd_Patterns(blue));

            % Something else writes to the device before the trigger.
            blue.Target=~blue.Target;
            blue.Write_Static();

            testCase.verifyError(@()Verify_Owned_Dmd_Patterns(blue), ...
                "Luminos:DMD:OwnedPatternChanged");
        end

        function programmingOutsideARunRecordsNoExpectation(testCase)
            % prepare_* called on its own, with no claim: programming is
            % legitimate, acquiring an expectation nothing will check is
            % not.
            app=testCase.rigWithStaleStacks();
            blue=app.getDevice("DMD","name","DMD_Blue");
            blue.Target=testCase.asymmetricMask(blue);
            blue.Write_Static();
            fingerprint=adaptive_optopatch.record_owned_dmd_pattern(blue);
            testCase.verifyEqual(fingerprint,"");
            testCase.verifyEqual(blue.pattern_owner_fingerprint,"");
        end
    end

    methods
        function action=startupAction(~,app,deviceName)
            report=app.DmdStartupReport;
            match=string({report.device})==string(deviceName);
            action=string(report(match).action);
        end

        function app=rigWithStaleStacks(testCase,options)
            arguments
                testCase
                options.AutoWriteStack (1,1) logical = true
            end
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot);
            for dmd=app.getDevice("DMD")
                testCase.loadStaleStack(dmd,options.AutoWriteStack);
            end
        end

        function [app,manifest,targets]=staleStackRig(testCase,options)
            arguments
                testCase
                options.Sequenced (1,1) logical = false
                options.AutoWriteStack (1,1) logical = true
            end
            [manifest,targets]=one_photon_manifest(options.Sequenced);
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot, ...
                "CameraRoi",targets.reference_camera.roi);
            for dmd=app.getDevice("DMD")
                testCase.loadStaleStack(dmd,options.AutoWriteStack);
            end
        end

        function loadStaleStack(~,dmd,autoWriteStack)
            % Whatever the operator last built in the DMD tab: field-wide,
            % multi-frame, and deliberately nothing like a cell mask, so
            % "the AO target survived" and "something plausible is loaded"
            % cannot be confused.
            canvas=adaptive_optopatch.dmd_pattern_canvas_size(dmd);
            stack=false([canvas 3]);
            stack(1:round(canvas(1)/2),:,1)=true;
            stack(:,1:round(canvas(2)/2),2)=true;
            stack(:,:,3)=true;
            dmd.pattern_stack=stack;
            dmd.auto_write_stack=autoWriteStack;
        end

        function mask=asymmetricMask(~,dmd)
            canvas=adaptive_optopatch.dmd_pattern_canvas_size(dmd);
            mask=false(canvas);
            mask(round(canvas(1)*0.2)+(1:9),round(canvas(2)*0.7)+(1:23))=true;
        end
    end
end

function [manifest,targets]=one_photon_manifest(sequenced)
% A single-cell 1P fixture. With sequenced=true the protocol varies the
% blue mask adjustment between events, which is what makes the runner take
% the FLUT/sequenced path rather than writing one static target.
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","dmd_ownership_test","CellIds","cell_001","RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1.25);
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
defaults=struct("command_voltage_v",1.25,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
if sequenced
    protocol=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
        [-1 0 1],"EventOrder","ordered","RandomSeed",5);
else
    protocol=adaptive_optopatch.generate_screen_protocol( ...
        "PulseCount",2,"PulseDurationMs",5,"DarkIntervalMs",[50 50], ...
        "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1.25);
end
manifest=adaptive_optopatch.build_manifest(reference,targets,protocol, ...
    "Mode","1p_dmd","FovState",fovState,"GuiDefaults",defaults);
end
