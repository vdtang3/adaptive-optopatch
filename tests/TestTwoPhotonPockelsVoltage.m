classdef TestTwoPhotonPockelsVoltage < matlab.unittest.TestCase
%TESTTWOPHOTONPOCKELSVOLTAGE The 2P Chameleon/Pockels command is owned by the
%protocol artifact. It can never come from the per-cell 488 nm calibration
%selected_blue_voltage_v, and it can never come from a GUI default.
    methods (Test)
        function explicitEventVoltageBeatsBlueCalibrationAndGui(testCase)
            [fovState,targets]=calibrated_fixture(0.8);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"ModulatorVoltage",2.7);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(3.3),"Mode","2p_spiral");
            events=resolved{1}.events;
            testCase.verifyEqual(events.command_voltage_v,[2.7;2.7]);
            testCase.verifyEqual(unique(events.command_voltage_source),"event");
            testCase.verifyFalse(any(events.command_voltage_v==0.8));
            testCase.verifyFalse(any(events.command_voltage_v==3.3));
        end

        function explicitAcquisitionAndProtocolScopesAreAccepted(testCase)
            [fovState,targets]=calibrated_fixture(0.8);

            acquisitionScope=adaptive_optopatch.generate_screen_protocol("PulseCount",1);
            acquisitionScope.acquisitions.parameters.command_voltage_v=2.7;
            resolved=adaptive_optopatch.resolve_protocol(acquisitionScope, ...
                fovState,targets,gui_defaults(3.3),"Mode","2p_spiral");
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,2.7);
            testCase.verifyEqual(resolved{1}.events.command_voltage_source, ...
                "acquisition");

            protocolScope=adaptive_optopatch.generate_screen_protocol("PulseCount",1);
            protocolScope.parameters.command_voltage_v=2.7;
            resolved=adaptive_optopatch.resolve_protocol(protocolScope, ...
                fovState,targets,gui_defaults(3.3),"Mode","2p_spiral");
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,2.7);
            testCase.verifyEqual(resolved{1}.events.command_voltage_source, ...
                "protocol");
        end

        function changingTheGuiVoltageCannotSupplyATwoPhotonCommand(testCase)
            [fovState,targets]=calibrated_fixture(0.8);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",2.7);
            for guiVoltage=[0.5 3.3 5]
                resolved=adaptive_optopatch.resolve_protocol(definition, ...
                    fovState,targets,gui_defaults(guiVoltage),"Mode","2p_spiral");
                testCase.verifyEqual(resolved{1}.events.command_voltage_v,2.7);
            end
        end

        function missingTwoPhotonVoltageFailsExplicitly(testCase)
            [fovState,targets]=calibrated_fixture(0.8);
            definition=adaptive_optopatch.generate_screen_protocol("PulseCount",1);
            testCase.verifyError(@()adaptive_optopatch.resolve_protocol( ...
                definition,fovState,targets,gui_defaults(3.3),"Mode","2p_spiral"), ...
                "adaptive_optopatch:MissingTwoPhotonPockelsVoltage");
            try
                adaptive_optopatch.resolve_protocol(definition,fovState,targets, ...
                    gui_defaults(3.3),"Mode","2p_spiral");
                testCase.verifyFail("Expected an explicit 2P Pockels error.");
            catch exception
                testCase.verifyTrue(contains(exception.message,"Pockels"));
                testCase.verifyTrue(contains(exception.message, ...
                    "selected_blue_voltage_v"));
            end

            % The same definition is reported as mode-incompatible before a
            % plan is built, so the operator sees it at protocol load.
            report=adaptive_optopatch.validate_protocol_for_mode( ...
                definition,"2p_spiral");
            testCase.verifyFalse(report.passed);
            testCase.verifyTrue(any(contains(report.issues,"Pockels")));

            % Building a manifest, the path the GUI freezes through, fails
            % for the same reason rather than resolving to something.
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                fovState.reference,targets,definition,"Mode","2p_spiral", ...
                "FovState",fovState,"GuiDefaults",gui_defaults(3.3)), ...
                "adaptive_optopatch:ProtocolModeIncompatible");
        end

        function aProtocolCannotWidenTheTwoPhotonSourcesBackOpen(testCase)
            [fovState,targets]=calibrated_fixture(0.8);
            definition=adaptive_optopatch.generate_screen_protocol("PulseCount",1);
            definition.parameter_sources=struct("command_voltage_v", ...
                ["event","acquisition","protocol","fov_cell","gui"]);
            testCase.verifyError(@()adaptive_optopatch.resolve_protocol( ...
                definition,fovState,targets,gui_defaults(3.3),"Mode","2p_spiral"), ...
                "adaptive_optopatch:MissingTwoPhotonPockelsVoltage");
        end

        function nullOnlyTwoPhotonAcquisitionsNeedNoCommand(testCase)
            [fovState,targets]=calibrated_fixture(0.8);
            definition=adaptive_optopatch.generate_screen_protocol("PulseCount",2);
            definition.acquisitions.events.is_null(:)=true;
            definition=adaptive_optopatch.normalize_protocol(definition);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(3.3),"Mode","2p_spiral");
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,[0;0]);
            testCase.verifyEqual(unique(resolved{1}.events.command_voltage_source), ...
                "null");
        end

        function unifiedGuiCannotSupplyOrOverrideATwoPhotonCommand(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_folder(root)); %#ok<NASGU>
            [app,~]=launch_simulated_adaptive_optopatch_gui( ...
                "CameraRoi",[974 100 984 80],"Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            app.setReferenceData(ones(80,100),unified_info(root), ...
                {[40 30;60 30;60 50;40 50]});
            app.setCellCalibration("cell_001",0.8);
            app.setPlanParameter("modulator_voltage",3.3);

            app.setPulseProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",2.7));
            plan=app.buildCurrentPlan();
            testCase.verifyEqual(unique( ...
                string(plan.manifest.trials.stimulation_mode)),"2p_spiral");
            frozen=plan.manifest.trials.pulse_schedule{1};
            testCase.verifyEqual(frozen.events.command_voltage_v,2.7);
            testCase.verifyEqual(frozen.events.command_voltage_source,"event");

            % The control that supplies the 1P mod488 default is disabled in
            % 2P mode, because nothing typed there can reach the Pockels
            % command.
            testCase.verifyEqual(string(app.commandVoltageEnabled()),"off");

            % A 2P protocol with no explicit command cannot be planned.
            app.setPulseProtocol( ...
                adaptive_optopatch.generate_screen_protocol("PulseCount",1));
            testCase.verifyError(@()app.buildCurrentPlan(), ...
                "adaptive_optopatch:ProtocolModeIncompatible");
        end

        function onePhotonStillResolvesThePerCellBlueVoltage(testCase)
            % The 2P rule must not disturb 1P, where the per-cell Blue
            % calibration is exactly the intended source.
            [fovState,targets]=calibrated_fixture(0.8);
            definition=adaptive_optopatch.generate_screen_protocol("PulseCount",1);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(3.3),"Mode","1p_dmd");
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,0.8);
            testCase.verifyEqual(resolved{1}.events.command_voltage_source, ...
                "fov_cell");

            % A round robin, whose parameter_sources already exclude the GUI,
            % keeps resolving from the FOV cell too.
            roundRobin=adaptive_optopatch.generate_round_robin_protocol( ...
                "PulsesPerCell",1);
            resolved=adaptive_optopatch.resolve_protocol(roundRobin,fovState, ...
                targets,gui_defaults(3.3),"Mode","1p_dmd");
            testCase.verifyEqual(unique(resolved{1}.events.command_voltage_v),0.8);

            % With no per-cell calibration a 1P screen still falls through to
            % the GUI default, which remains intentional for 1P.
            uncalibrated=calibrated_fixture(NaN);
            resolved=adaptive_optopatch.resolve_protocol(definition,uncalibrated, ...
                targets,gui_defaults(3.3),"Mode","1p_dmd");
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,3.3);
            testCase.verifyEqual(resolved{1}.events.command_voltage_source,"gui");
        end
    end
end

function [fovState,targets]=calibrated_fixture(blueVoltage)
image=zeros(40,40); masks=false(40,40);
masks(14:25,14:25)=true;
polygons={[14 14;25 14;25 25;14 25]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","pockels_test","CellIds","cell_001","RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons);
if isfinite(blueVoltage)
    fovState=adaptive_optopatch.update_cell_calibration( ...
        fovState,"cell_001","CommandVoltageV",blueVoltage);
end
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
end

function defaults=gui_defaults(commandVoltage)
defaults=struct("command_voltage_v",commandVoltage,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end

function info=unified_info(root)
camera=struct("ROI",[0 0 100 80],"bin",1, ...
    "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
metadata=struct("rig_name","Virtual_Upright","voltage_camera",camera);
info=struct("snapshot_name","pockels_gui_test", ...
    "snapshot_directory",string(root), ...
    "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
    "metadata",metadata);
end

function remove_folder(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
