classdef TestPreviewMatchesExecution < matlab.unittest.TestCase
%TESTPREVIEWMATCHESEXECUTION The operator preview must show the experiment
%that will actually run: resolved per-event Blue masks, the resolved Orange
%expansion, and the resolved 2P spiral geometry, all derived through the same
%canonical helpers execution uses.
    methods (Test)
        function bluePreviewShowsResolvedEventMasksNotTheBundleDefault(testCase)
            [fovState,targets]=single_cell_fixture(0);
            adjustments=[-1 0 2];
            definition=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                adjustments,"EventOrder","ordered");
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","1p_dmd");

            bundlePreview=adaptive_optopatch.build_target_preview(targets,"1p_dmd");
            testCase.verifyEqual(bundlePreview.source,"bundle_default");
            testCase.verifyNumElements(bundlePreview.blue,1);

            preview=adaptive_optopatch.build_target_preview(targets,"1p_dmd", ...
                "ResolvedProtocols",resolved);
            testCase.verifyEqual(preview.source,"resolved_plan");
            testCase.verifyEqual(sort([preview.blue.adjustment_pixels]), ...
                sort(double(adjustments)));

            % Each previewed mask is exactly the pattern the DMD sequence
            % builder will project for that event.
            plan=adaptive_optopatch.build_dmd_sequence_plan(resolved{1},targets);
            events=resolved{1}.events;
            for k=1:height(events)
                adjustment=events.blue_mask_adjustment_pixels(k);
                index=find([preview.blue.adjustment_pixels]==adjustment,1);
                testCase.verifyNotEmpty(index);
                testCase.verifyEqual(preview.blue(index).mask, ...
                    plan.camera_pattern_stack(:,:,k));
            end

            % The bundle default is only one of them, so the old preview
            % showed a mask that two of the three pulses never use.
            defaultMask=bundlePreview.blue(1).mask;
            differing=arrayfun(@(entry)~isequal(entry.mask,defaultMask), ...
                preview.blue);
            testCase.verifyGreaterThan(sum(differing),0);
        end

        function orangePreviewShowsTheResolvedExpansion(testCase)
            [fovState,targets]=single_cell_fixture(0);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            definition.parameters.orange_expansion_pixels=5;
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","1p_dmd");
            preview=adaptive_optopatch.build_target_preview(targets,"1p_dmd", ...
                "ResolvedProtocols",resolved);
            executed=adaptive_optopatch.apply_acquisition_parameters( ...
                targets,resolved{1});
            testCase.verifyEqual([preview.orange.expansion_pixels],5);
            testCase.verifyEqual(preview.orange(1).mask, ...
                executed.orange_camera_masks(:,:,1));
            testCase.verifyNotEqual(nnz(preview.orange(1).mask), ...
                nnz(targets.orange_camera_masks(:,:,1)));
        end

        function spiralPreviewUsesResolvedRadiusDensityAndDuration(testCase)
            [fovState,targets]=single_cell_fixture(0);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"PulseDurationMs",8,"ModulatorVoltage",1);
            definition.parameters.spiral_radius_um=5;
            definition.parameters.spiral_density_points_per_volt=17;
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","2p_spiral");
            preview=adaptive_optopatch.build_target_preview(targets,"2p_spiral", ...
                "ResolvedProtocols",resolved);
            executed=adaptive_optopatch.apply_acquisition_parameters( ...
                targets,resolved{1});

            testCase.verifyNumElements(preview.spiral,1);
            testCase.verifyEqual(preview.spiral.radius_pixels, ...
                executed.targets(1).spiral_preview_radius_pixels);
            testCase.verifyEqual(preview.spiral.density_points_per_volt,17);
            testCase.verifyEqual(preview.spiral.pulse_duration_ms,8,"AbsTol",1e-9);

            bundlePreview=adaptive_optopatch.build_target_preview( ...
                targets,"2p_spiral");
            testCase.verifyNotEqual(bundlePreview.spiral.radius_pixels, ...
                preview.spiral.radius_pixels);
            testCase.verifyNotEqual(bundlePreview.spiral.density_points_per_volt, ...
                preview.spiral.density_points_per_volt);
        end

        function unifiedPreviewDerivesFromTheResolvedPlan(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_folder(root)); %#ok<NASGU>
            [app,~]=open_simulated_test_gui( ...
                "CameraRoi",[974 100 984 80],"Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            app.setReferenceData(ones(80,100),unified_info(root), ...
                {[40 30;60 30;60 50;40 50]});
            app.setPlanParameter("mode","1p_dmd");
            app.setPlanParameter("blue_mask_adjustment_pixels",0);
            % A mask titration deliberately runs at the cell's calibrated
            % voltage, so its parameter_sources exclude the GUI default.
            app.setCellCalibration("cell_001",1);
            app.setPulseProtocol( ...
                adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                [-2 0],"EventOrder","ordered"));

            resolved=app.buildCurrentPlan().resolved_protocols;
            testCase.verifyNumElements(resolved,1);
            testCase.verifyEqual( ...
                sort(unique(resolved{1}.events.blue_mask_adjustment_pixels))', ...
                [-2 0]);

            app.previewCurrentPlan();
            status=string(app.statusText());
            testCase.verifyTrue(any(contains(status,"resolved acquisition values")), ...
                char(strjoin(status,newline)));
            testCase.verifyTrue(any(contains(status,"-2")), ...
                char(strjoin(status,newline)));
        end
    end
end

function [fovState,targets]=single_cell_fixture(defaultAdjustment)
image=zeros(40,40); masks=false(40,40);
masks(14:25,14:25)=true;
polygons={[14 14;25 14;25 25;14 25]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","preview_test","CellIds","cell_001","RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons);
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1);
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"SpiralDensityPointsPerVolt",10, ...
    "ParkingClearancePixels",1,"OrangeExpansionPixels",2, ...
    "BlueMaskAdjustmentPixels",defaultAdjustment);
end

function defaults=gui_defaults()
defaults=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end

function info=unified_info(root)
camera=struct("ROI",[0 0 100 80],"bin",1, ...
    "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
metadata=struct("rig_name","Virtual_Upright","voltage_camera",camera);
info=struct("snapshot_name","preview_test", ...
    "snapshot_directory",string(root), ...
    "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
    "metadata",metadata);
end

function remove_folder(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
