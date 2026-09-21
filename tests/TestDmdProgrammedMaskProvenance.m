classdef TestDmdProgrammedMaskProvenance < matlab.unittest.TestCase
    % What the archive can say, afterwards, about the pattern a DMD was
    % programmed with.
    %
    % NOT whether the right pattern reached the mirrors. That is three
    % other suites: TestDmdCameraMaskRemapping builds the camera-space
    % mask, TestDmdCalibrationIdentity checks the transform it is warped
    % through belongs to this camera, and TestDmdOwnershipAcrossAcquisition
    % checks the programmed pattern survives to the trigger. Those are
    % about the experiment. This one is about the RECORD of it, which is
    % what anybody reading the data months later actually has.
    %
    % The failure being regressed: Orange's archived `device_mask` was the
    % return value of
    %
    %     dmd.setPatterningROI(mask, "write_when_complete", true)
    %
    % and Patterning_Device returns the warped mask only when it is asked
    % NOT to write. Once it has written, the mask is in Target and the
    % return value is the scalar 1 - so `device_mask` was `true`, and the
    % one field whose job is to say what Orange received could say nothing
    % at all. The illumination was unaffected, which is why it survived:
    % every other artifact - the camera mask, the remapping, the transform,
    % the fingerprint - was correct, and nothing reads this field, so
    % nothing complained. A provenance field that silently holds a scalar
    % is worse than one that is missing, because it looks answered.
    %
    % Blue never had the bug: prepare_luminos_target discards the return
    % value and reads Target back through summarize_dmd_device_pattern.
    % The last group here pins the two devices to the same meaning, so a
    % future change to one has to face the other.

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
        % ---------------------------------------------------------------
        % The device API this is all downstream of
        % ---------------------------------------------------------------

        function writingLeavesTheMaskInTargetAndReturnsAScalar(testCase)
            % Patterning_Device.setPatterningROI: `tmask = 1` after a
            % write, the warped mask otherwise. Asserted against the
            % simulated device so that it cannot drift back into returning
            % the mask either way - which is exactly why every existing
            % test agreed with a caller that archived the return value.
            app=adaptive_optopatch.testing.make_simulated_luminos();
            dmd=app.getDevice("DMD","name","DMD_Orange");
            mask=false(dmd.Pattern_Canvas_Size()); mask(5:9,5:9)=true;

            written=dmd.setPatterningROI(mask,"write_when_complete",true);
            notWritten=dmd.setPatterningROI(mask,"write_when_complete",false);

            testCase.verifyEqual(written,1, ...
                "A write returns a success scalar, not the device mask.");
            testCase.verifySize(notWritten,size(mask));
            testCase.verifyEqual(logical(dmd.Target),mask);
        end

        % ---------------------------------------------------------------
        % Orange: the archived mask is the programmed mask
        % ---------------------------------------------------------------

        function orangeDeviceMaskIsAMaskAndNotScalarTrue(testCase)
            [app,targets]=orange_fixture();

            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app,targets,"DryRun",false);

            testCase.verifyTrue(configuration.loaded);
            testCase.verifyClass(configuration.device_mask,"logical");
            testCase.verifyNotEqual(numel(configuration.device_mask),1, ...
                "device_mask is the scalar the write returned, not a mask.");
            testCase.verifyGreaterThan(ndims(configuration.device_mask),1);
        end

        function orangeDeviceMaskHasTheDevicesOwnDimensions(testCase)
            [app,targets]=orange_fixture();
            dmd=app.getDevice("DMD","name","DMD_Orange");

            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app,targets,"DryRun",false);

            % The device's own grid, whatever that is - read off Target
            % rather than asserted as a constant. On a rig
            % setPatterningROI warps into imref2d(Pattern_Canvas_Size);
            % the simulated device does not model the warp, so pinning a
            % number here would be pinning the simulator. What has to hold
            % either way is that the archived mask is the same array the
            % device is holding, and that it is device space rather than
            % the camera-space mask AO started from.
            testCase.verifyEqual(size(configuration.device_mask), ...
                size(dmd.Target));
            testCase.verifyNotEqual(size(configuration.device_mask), ...
                size(configuration.camera_mask), ...
                "Device space, not camera space.");
        end

        function orangeDeviceMaskMatchesTheAuthoritativeTarget(testCase)
            [app,targets]=orange_fixture();
            dmd=app.getDevice("DMD","name","DMD_Orange");

            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app,targets,"DryRun",false);

            % Pixel for pixel, against the device property that IS the
            % programmed pattern - not against the mask AO sent, which
            % would only prove AO agrees with itself.
            testCase.verifyEqual(configuration.device_mask, ...
                logical(dmd.Target>.5));
            testCase.verifyEqual(nnz(configuration.device_mask), ...
                nnz(dmd.Target>.5));
            testCase.verifyGreaterThan(nnz(configuration.device_mask),0, ...
                "A recording mask with no illuminated pixels records nothing.");
        end

        function orangeDeviceMaskIsTheMaskThatWasAskedFor(testCase)
            % The remapping is TestDmdCameraMaskRemapping's; what this adds
            % is that the thing archived as "what the device got" is the
            % thing the device was told to take.
            [app,targets]=orange_fixture();

            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app,targets,"DryRun",false);

            testCase.verifyEqual(configuration.device_mask, ...
                logical(configuration.dmd_reference_mask));
        end

        function aDryRunArchivesNoProgrammedMaskAtAll(testCase)
            % Nothing was programmed, so there is nothing to have a
            % provenance of. An absent field is honest; a stale one is not.
            [app,targets]=orange_fixture();

            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app,targets,"DryRun",true);

            testCase.verifyFalse(configuration.loaded);
            testCase.verifyFalse(isfield(configuration,"device_mask"));
            testCase.verifyFalse(isfield(configuration,"device_mask_summary"));
        end

        % ---------------------------------------------------------------
        % It reaches the archive
        % ---------------------------------------------------------------

        function afullOnePhotonRunArchivesTheProgrammedOrangeMask(testCase)
            % Through the runner, which is where orange_configuration is
            % actually written: a provenance field that is right in a unit
            % test and absent from the run table records nothing.
            [manifest,targets]=one_photon_manifest();
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot, ...
                "CameraRoi",targets.reference_camera.roi);

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "BlankDmdAfterTrial",false, ...
                "OutputDirectory",testCase.OutputRoot);

            orange=app.getDevice("DMD","name","DMD_Orange");
            configuration=run.trials.orange_configuration{1};
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyClass(configuration.device_mask,"logical");
            testCase.verifyEqual(size(configuration.device_mask), ...
                size(orange.Target));
            testCase.verifyEqual(configuration.device_mask, ...
                logical(orange.Target>.5));
        end

        function theArchivedOrangeMaskSurvivesASaveAndLoad(testCase)
            % A logical array of device size is what a MAT file has to
            % carry unchanged for the record to be worth keeping.
            [app,targets]=orange_fixture();
            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app,targets,"DryRun",false);
            path=fullfile(testCase.OutputRoot,"orange_configuration.mat");

            save(path,"configuration");
            restored=load(path).configuration;

            testCase.verifyEqual(restored.device_mask, ...
                configuration.device_mask);
            testCase.verifyEqual(restored.device_mask_summary.target_on_pixels, ...
                configuration.device_mask_summary.target_on_pixels);
        end

        % ---------------------------------------------------------------
        % Blue and Orange mean the same thing by "programmed"
        % ---------------------------------------------------------------

        function orangeCarriesTheSameDevicePatternSummaryBlueDoes(testCase)
            [app,targets]=orange_fixture();

            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app,targets,"DryRun",false);

            summary=configuration.device_mask_summary;
            testCase.verifyTrue(summary.available);
            testCase.verifyEqual(summary.size, ...
                size(configuration.device_mask));
            testCase.verifyEqual(summary.target_on_pixels, ...
                nnz(configuration.device_mask));
        end

        function bothDevicesReportTheProgrammedPatternFromTargetNotFromAReturnValue(testCase)
            % One claim, both devices. Blue reads Target back through
            % summarize_dmd_device_pattern and Orange now does the same, at
            % the same >.5 threshold, so "what the DMD was programmed with"
            % means one thing across the archive.
            [manifest,targets]=one_photon_manifest();
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot, ...
                "CameraRoi",targets.reference_camera.roi);

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "BlankDmdAfterTrial",false, ...
                "OutputDirectory",testCase.OutputRoot);

            blue=run.trials.target_configuration{1};
            orange=run.trials.orange_configuration{1};
            blueDevice=app.getDevice("DMD","name","DMD_Blue");
            orangeDevice=app.getDevice("DMD","name","DMD_Orange");

            testCase.verifyEqual(blue.dmd_device_mask_summary.target_on_pixels, ...
                nnz(blueDevice.Target>.5));
            testCase.verifyEqual(orange.device_mask_summary.target_on_pixels, ...
                nnz(orangeDevice.Target>.5));
            % Neither reports a scalar, which is what a return value would
            % have made of either of them.
            testCase.verifyNotEqual(prod(blue.dmd_device_mask_summary.size),1);
            testCase.verifyNotEqual(prod(orange.device_mask_summary.size),1);
        end

        function programmingOrangeStillTakesItsOwnCalibrationIdentity(testCase)
            % Handoff 1's guard, asserted here only to show this change did
            % not displace it: provenance and identity validation are two
            % fields side by side, not one replacing the other.
            [app,targets]=orange_fixture();

            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app,targets,"DryRun",false);

            testCase.verifyTrue(isfield(configuration,"calibration_identity"));
            testCase.verifyTrue(isfield(configuration,"owned_pattern_fingerprint"));
        end
    end
end

% ---------------------------------------------------------------------------
% Fixtures
% ---------------------------------------------------------------------------

function [app,targets]=orange_fixture()
%ORANGE_FIXTURE A two-cell FOV on the simulated rig, one cell recorded.
[fovState,~]=AoFixtures.fovState();
fovState.cells(2).recording_enabled=false;
fovState.reference.cells=fovState.cells;
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "OrangeExpansionPixels",4);
app=adaptive_optopatch.testing.make_simulated_luminos();
end

function [manifest,targets]=one_photon_manifest()
%ONE_PHOTON_MANIFEST The smallest complete 1P run, as the runners take it.
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","orange_provenance_test","CellIds","cell_001", ...
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
