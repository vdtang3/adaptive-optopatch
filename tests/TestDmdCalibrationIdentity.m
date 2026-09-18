classdef TestDmdCalibrationIdentity < matlab.unittest.TestCase
    % Refusing to project through a calibration that belongs to a different
    % camera.
    %
    % Luminos keeps one camera-to-DMD calibration per patterning-device /
    % camera pair, but projection goes through one active transform.
    % Selecting a camera that has no stored calibration leaves the previous
    % camera's transform in place, so this state is reachable:
    %
    %   the AO reference belongs to camera A; the DMD is projecting through
    %   camera B's calibration; the reference geometry checks pass, because
    %   dimensions, origin and binning are unchanged; and the preview is
    %   right, because it is drawn in camera coordinates before the
    %   transform is applied.
    %
    % Nothing AO could previously look at distinguished that from a correct
    % rig: the transform is nonidentity, well conditioned and the right
    % shape, and the dropdown reads whatever was selected. So the check is
    % on identity - which pair the active transform was measured for - and
    % it fails closed, because AO cannot tell a missing calibration from a
    % wrong one by looking at the projection and the experimenter can.

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

        % --- 1: the correct pair is allowed -------------------------------

        function theCorrectCameraDmdPairIsAccepted(testCase)
            [app,targets]=testCase.rig();
            blue=app.getDevice("DMD","name","DMD_Blue");

            report=adaptive_optopatch.validate_dmd_calibration_identity( ...
                blue,targets.reference_camera,"DMD_Blue");

            testCase.verifyTrue(report.passed);
            testCase.verifyEqual(report.camera,"Orca Fusion");
            testCase.verifyTrue(report.identity.has_pair_calibration);
            testCase.verifyTrue(report.identity.active_transform_is_pair_transform);
        end

        % --- 2: a wrong-camera transform on compatible geometry -----------

        function aWrongCameraTransformIsRejectedDespiteMatchingGeometry(testCase)
            [app,targets]=testCase.rig();
            blue=app.getDevice("DMD","name","DMD_Blue");
            % Calibrated against the behaviour camera and nothing else.
            % The reference image, its origin and its binning are untouched,
            % so every geometric check still passes.
            testCase.recalibrateOnlyAgainst(blue,"Behaviour Camera", ...
                affinetform2d([1.4 0.05 31;-0.04 1.37 -19;0 0 1]));

            geometry=adaptive_optopatch.validate_dmd_reference_geometry( ...
                blue,targets.reference_camera,"DMD_Blue");
            testCase.verifyTrue(geometry.passed, ...
                "The geometry check must still pass, or this proves nothing.");
            testCase.verifyNotEmpty(blue.tform);

            testCase.verifyError(@() ...
                adaptive_optopatch.validate_dmd_calibration_identity( ...
                    blue,targets.reference_camera,"DMD_Blue"), ...
                "adaptive_optopatch:MissingDmdCameraCalibration");
        end

        % --- 3: camera switched, old transform still loaded ---------------

        function switchingToAnUncalibratedCameraIsRejected(testCase)
            [app,targets]=testCase.rig();
            blue=app.getDevice("DMD","name","DMD_Blue");
            calibrated=blue.tform;
            % The selector moves; the transform does not.
            blue.use_calibration_camera("Behaviour Camera");
            testCase.verifyEqual(blue.tform,calibrated, ...
                "The fixture no longer reproduces the state under test.");

            % Asked about the camera the plan's reference came from, the
            % pair is still calibrated and still active, so this is allowed
            % - the selector is not what makes a projection right.
            report=adaptive_optopatch.validate_dmd_calibration_identity( ...
                blue,targets.reference_camera,"DMD_Blue");
            testCase.verifyTrue(report.passed);

            % But a plan whose reference belongs to the camera now selected,
            % which has no calibration, is refused.
            behaviourReference=targets.reference_camera;
            behaviourReference.name="Behaviour Camera";
            testCase.verifyError(@() ...
                adaptive_optopatch.validate_dmd_calibration_identity( ...
                    blue,behaviourReference,"DMD_Blue"), ...
                "adaptive_optopatch:MissingDmdCameraCalibration");
        end

        function aPairWhoseTransformIsNoLongerActiveIsRejected(testCase)
            % Both cameras calibrated, the other one selected. The pair the
            % plan needs exists, and the device is not using it.
            [app,targets]=testCase.rig();
            blue=app.getDevice("DMD","name","DMD_Blue");
            adaptive_optopatch.testing.calibrate_simulated_dmd(blue, ...
                struct("name","Behaviour Camera","bin",1), ...
                affinetform2d([1.4 0.05 31;-0.04 1.37 -19;0 0 1]));
            blue.use_calibration_camera("Behaviour Camera");
            testCase.verifyTrue(blue.calibration_identity("Orca Fusion") ...
                .has_pair_calibration, ...
                "This case is about a pair that exists but is not active.");

            testCase.verifyError(@() ...
                adaptive_optopatch.validate_dmd_calibration_identity( ...
                    blue,targets.reference_camera,"DMD_Blue"), ...
                "adaptive_optopatch:DmdCalibrationCameraMismatch");
        end

        function anIdentityPairTransformIsNotACalibration(testCase)
            [app,targets]=testCase.rig();
            blue=app.getDevice("DMD","name","DMD_Blue");
            blue.set_calibration_entry("Orca Fusion",affinetform2d(eye(3)));
            blue.use_calibration_camera("Orca Fusion");

            testCase.verifyError(@() ...
                adaptive_optopatch.validate_dmd_calibration_identity( ...
                    blue,targets.reference_camera,"DMD_Blue"), ...
                "adaptive_optopatch:UncalibratedDmd");
        end

        function aReferenceThatNamesNoCameraIsRejected(testCase)
            [app,targets]=testCase.rig();
            blue=app.getDevice("DMD","name","DMD_Blue");
            anonymous=rmfield(targets.reference_camera,"name");
            testCase.verifyError(@() ...
                adaptive_optopatch.validate_dmd_calibration_identity( ...
                    blue,anonymous,"DMD_Blue"), ...
                "adaptive_optopatch:ReferenceCameraNotIdentified");
        end

        % --- 4: Blue and Orange are independent ---------------------------

        function blueAndOrangeAreValidatedSeparately(testCase)
            [app,targets]=testCase.rig();
            orange=app.getDevice("DMD","name","DMD_Orange");
            % Only the Orange calibration is wrong.
            testCase.recalibrateOnlyAgainst(orange,"Behaviour Camera", ...
                affinetform2d([1.2 0 9;0 1.2 4;0 0 1]));

            blue=app.getDevice("DMD","name","DMD_Blue");
            testCase.verifyTrue( ...
                adaptive_optopatch.validate_dmd_calibration_identity( ...
                    blue,targets.reference_camera,"DMD_Blue").passed);
            testCase.verifyError(@() ...
                adaptive_optopatch.validate_dmd_calibration_identity( ...
                    orange,targets.reference_camera,"DMD_Orange"), ...
                "adaptive_optopatch:MissingDmdCameraCalibration");
        end

        function anUncalibratedOrangeStopsTheRunBeforeAnyLight(testCase)
            [app,manifest,targets]=testCase.runnableRig();
            orange=app.getDevice("DMD","name","DMD_Orange");
            testCase.recalibrateOnlyAgainst(orange,"Behaviour Camera", ...
                affinetform2d([1.2 0 9;0 1.2 4;0 0 1]));
            laser=app.getDevice("Laser_Device");
            laser.EmissionOn=false;

            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:MissingDmdCameraCalibration");
            testCase.verifyFalse(laser.EmissionOn, ...
                "The run raised the laser before checking the calibration.");
        end

        % --- 5: the valid workflow is unaffected --------------------------

        function aCorrectlyCalibratedRunStillCompletes(testCase)
            [app,manifest,targets]=testCase.runnableRig();
            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "OutputDirectory",testCase.OutputRoot);

            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            % The identity that was used is archived with the run, on both
            % devices, so a finished acquisition can say which calibration
            % projected its masks.
            testCase.verifyTrue(run.dmd_calibration.identity.blue.passed);
            testCase.verifyTrue(run.dmd_calibration.identity.orange.passed);
            testCase.verifyEqual(run.dmd_calibration.identity.blue.camera, ...
                "Orca Fusion");
            configuration=run.trials.target_configuration{1};
            testCase.verifyTrue(configuration.calibration_identity.passed);
            orangeConfiguration=run.trials.orange_configuration{1};
            testCase.verifyTrue(orangeConfiguration.calibration_identity.passed);
        end

        function theSequencedPathValidatesBeforeTransformingAnyMask(testCase)
            [app,targets]=testCase.rig();
            blue=app.getDevice("DMD","name","DMD_Blue");
            blue.calibrations=struct();
            blue.calibration_camera="";

            plan=sequence_plan(targets);
            testCase.verifyError(@() ...
                adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                    blue,plan,"DryRun",false), ...
                "adaptive_optopatch:MissingDmdCameraCalibration");
            testCase.verifyEqual(blue.slot_write_count,0, ...
                "Masks were uploaded before the calibration was checked.");
            testCase.verifyEqual(blue.reserved_slot_count,0);
        end
    end

    methods
        function [app,targets]=rig(testCase)
            [~,targets]=one_photon_manifest();
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot, ...
                "CameraRoi",targets.reference_camera.roi);
        end

        function recalibrateOnlyAgainst(~,dmd,cameraName,transform)
            % A rig where the ONLY stored calibration belongs to another
            % camera, as opposed to one where the right pair exists but is
            % not selected. The two are different failures with different
            % remedies, so they get different errors.
            dmd.calibrations=struct();
            dmd.calibration_camera="";
            adaptive_optopatch.testing.calibrate_simulated_dmd(dmd, ...
                struct("name",cameraName,"bin",1),transform);
        end

        function [app,manifest,targets]=runnableRig(testCase)
            [manifest,targets]=one_photon_manifest();
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot, ...
                "CameraRoi",targets.reference_camera.roi);
        end
    end
end

function plan=sequence_plan(targets)
masks=targets.dmd_camera_masks;
imageSize=size(masks,1,2);
second=false(imageSize); second(3:6,3:9)=true;
stack=cat(3,logical(masks(:,:,1)),second);
plan=struct("schema_version","2.0.0","unique_camera_masks",stack, ...
    "reference_camera",targets.reference_camera,"pattern_count",2, ...
    "event_count",2,"unique_mask_count",2,"pulse_id",[1;2], ...
    "event_slot_indices",[1;2],"stack_pattern_number",[1;2], ...
    "target_cell_id",["cell_001";"cell_001"],"dmd_pattern_index",[1;2], ...
    "pattern_activation_s",[0;0.1],"dmd_trigger_s",[0;0.1], ...
    "trigger_associated_pulse_id",[1;2], ...
    "trigger_target_cell_id",["cell_001";"cell_001"], ...
    "initialization_trigger_s",0,"advance_onset_s",0.1, ...
    "no_artificial_settle_interval",true);
end

function [manifest,targets]=one_photon_manifest()
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","calibration_identity_test","CellIds","cell_001", ...
    "RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1.25);
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
protocol=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",2,"PulseDurationMs",5,"DarkIntervalMs",[50 50], ...
    "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1.25);
defaults=struct("command_voltage_v",1.25,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
manifest=adaptive_optopatch.build_manifest(reference,targets,protocol, ...
    "Mode","1p_dmd","FovState",fovState,"GuiDefaults",defaults);
end
