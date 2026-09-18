classdef TestFovWorkflowCleanup < matlab.unittest.TestCase
    methods (Test)
        function savesAndRestoresAllSpatialControls(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            [first,~]=open_simulated_test_gui("Visible","off","RunRoot",root);
            firstCleanup=onCleanup(@()delete(first));
            first.setReferenceData(ones(70,90),test_info(root),test_polygon());
            set_spatial_controls(first);
            path=fullfile(root,"spatial_fov.mat"); first.saveCurrentFov(path);
            saved=load(path,"fov_state"); verify_spatial_values(testCase,saved.fov_state);

            [second,~]=open_simulated_test_gui("Visible","off","RunRoot",root);
            secondCleanup=onCleanup(@()delete(second));
            second.loadFov(path);
            second.setPulseProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1));
            plan=second.buildCurrentPlan();
            verify_spatial_values(testCase,plan.fov_state);
            verify_spatial_values(testCase,plan.session.parameters);
            testCase.verifyEmpty(findall(second.Figure,"Text","Save plan…"));
            testCase.verifyEmpty(findall(second.Figure,"Text","Save planning bundle…"));
        end

        function rejectsObsoleteFovSchema(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            [source,~]=open_simulated_test_gui("Visible","off","RunRoot",root);
            sourceCleanup=onCleanup(@()delete(source));
            source.setReferenceData(ones(70,90),test_info(root),test_polygon());
            source.setPlanParameter("microns_per_pixel",0.44);
            current=source.saveCurrentFov(fullfile(root,"current.mat"));
            fov_state=current;
            fov_state.schema_version="1.0.0";
            oldPath=fullfile(root,"old_fov.mat"); save(oldPath,"fov_state");

            testCase.verifyError(@()adaptive_optopatch.load_fov_state(oldPath), ...
                "adaptive_optopatch:ObsoleteFovSchema");
        end

        function unifiedSnapshotLoadDoesNotRestoreLatestPlan(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            snapshotPath=write_snapshot(root);
            oldPlan=fullfile(root,"old_plan"); mkdir(oldPlan);
            reference=struct("source_snapshot",string(snapshotPath), ...
                "source_experiment",string(root));
            planning_session=struct("image_size",[30 40], ...
                "roi_positions",{{[10 10;15 10;15 15;10 15]}}, ...
                "parameters",struct("stimulation_mode","1p_dmd"));
            save(fullfile(oldPlan,"reference_model.mat"),"reference");
            save(fullfile(oldPlan,"planning_session.mat"),"planning_session");

            [app,~]=open_simulated_test_gui("Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app));
            app.setPulseProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1));
            app.loadSnapshot(snapshotPath);
            testCase.verifyError(@()app.buildCurrentPlan(),"adaptive_optopatch:NothingToSave");
        end

        function previewValidateAndFreezeNeedNoManualPlanSave(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            % Preflight compares the live camera grid with the frozen one,
            % so the simulated camera acquires on test_info's grid.
            [app,~]=open_simulated_test_gui( ...
                "CameraRoi",[979 90 989 70],"Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app));
            app.setReferenceData(ones(70,90),test_info(root),test_polygon());
            app.setPulseProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1.4));
            app.setPlanParameter("mode","1p_dmd");
            app.previewCurrentPlan();
            report=app.validateCurrentPlan();
            paths=app.freezeCurrentPlan(root);
            testCase.verifyTrue(report.passed);
            testCase.verifyEqual(app.PlanState,"FROZEN");
            savedSession=load(paths.session,"planning_session");
            testCase.verifyFalse(isfield( ...
                savedSession.planning_session.parameters,"modulator_voltage"));
            for path=[paths.fov_state paths.manifest paths.session paths.protocol]
                testCase.verifyTrue(isfile(path));
            end
            frozen=adaptive_optopatch.load_protocol(paths.protocol);
            testCase.verifyEqual(frozen.events.command_voltage_v,1.4);
        end

        function editableEligibilityIsIndependentAndPersistent(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            [app,~]=open_simulated_test_gui("Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app));
            app.setReferenceData(ones(70,90),test_info(root),test_polygon());

            app.setCellEligibility("cell_001","StimulationEnabled",false);
            state=app.setCellEligibility("cell_001","RecordingEnabled",false);
            testCase.verifyFalse(state.cells(1).recording_enabled);
            testCase.verifyFalse(state.cells(1).stimulation_enabled);
            testCase.verifyTrue(isnan(state.cells(1).selected_blue_voltage_v));
            state=app.setCellEligibility("cell_001","StimulationEnabled",true);
            testCase.verifyFalse(state.cells(1).recording_enabled);
            testCase.verifyTrue(state.cells(1).stimulation_enabled);
            app.setCellCalibration("cell_001",1,"manual selection");
            state=app.saveCurrentFov(fullfile(root,"eligibility_fov.mat"));
            testCase.verifyFalse(state.cells(1).recording_enabled);
            testCase.verifyTrue(state.cells(1).stimulation_enabled);

            path=fullfile(root,"eligibility_fov.mat");
            [loadedApp,~]=open_simulated_test_gui( ...
                "Visible","off","RunRoot",root);
            loadedCleanup=onCleanup(@()delete(loadedApp));
            loadedApp.loadFov(path);
            loaded=loadedApp.saveCurrentFov(fullfile(root,"roundtrip.mat"));
            testCase.verifyFalse(loaded.cells(1).recording_enabled);
            testCase.verifyTrue(loaded.cells(1).stimulation_enabled);
        end

        function qcCheckboxesAreCanonicalAndLegacyControlsAreGone(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            [app,~]=open_simulated_test_gui("Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app));
            app.setReferenceData(ones(70,90),test_info(root),test_polygon());
            tables=findall(app.Figure,"Type","uitable");
            qc=tables(arrayfun(@(value)numel(value.ColumnName)==9,tables));
            testCase.verifyNumElements(qc,1);
            testCase.verifyEqual(logical(qc.ColumnEditable), ...
                [false true true true false false false false false]);
            testCase.verifyEmpty(findall(app.Figure, ...
                "Text","Set selected Blue calibration…"));
            callback=qc.CellEditCallback;
            callback(qc,struct("Indices",[1 3],"NewData",false));
            state=app.saveCurrentFov(fullfile(root,"table_edit_fov.mat"));
            testCase.verifyTrue(state.cells(1).recording_enabled);
            testCase.verifyFalse(state.cells(1).stimulation_enabled);
            for text=["Exclude selected from stimulation","Override OBIS", ...
                    "ARM live output","ARM simulated 488 output", ...
                    "Release level","Trajectory reviewed"]
                testCase.verifyEmpty(findall(app.Figure,"Text",text));
            end
        end

        function blueVoltageTableEditsAreValidatedAndPersistent(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            [app,~]=open_simulated_test_gui("Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app));
            polygons=test_polygon();
            polygons{2}=[55 25;75 25;75 45;55 45];
            app.setReferenceData(ones(70,90),test_info(root),polygons);
            tables=findall(app.Figure,"Type","uitable");
            qc=tables(arrayfun(@(value)numel(value.ColumnName)==9,tables));
            callback=qc.CellEditCallback;

            callback(qc,struct("Indices",[1 4],"NewData",1.35));
            state=app.saveCurrentFov(fullfile(root,"blue_v_fov.mat"));
            testCase.verifyEqual(state.cells(1).selected_blue_voltage_v,1.35);
            testCase.verifyTrue(isnan(state.cells(2).selected_blue_voltage_v));
            callback(qc,struct("Indices",[2 2],"NewData",false));
            state=app.saveCurrentFov(fullfile(root,"other_column_fov.mat"));
            testCase.verifyEqual(state.cells(1).selected_blue_voltage_v,1.35);

            callback(qc,struct("Indices",[1 4],"NewData","not a voltage"));
            testCase.verifyEqual(qc.Data{1,4},1.35);
            state=app.saveCurrentFov(fullfile(root,"after_invalid_fov.mat"));
            testCase.verifyEqual(state.cells(1).selected_blue_voltage_v,1.35);

            [reloaded,~]=open_simulated_test_gui("Visible","off","RunRoot",root);
            reloadCleanup=onCleanup(@()delete(reloaded));
            reloaded.loadFov(fullfile(root,"after_invalid_fov.mat"));
            reloadTable=findall(reloaded.Figure,"Type","uitable");
            reloadTable=reloadTable(arrayfun(@(value)numel(value.ColumnName)==9,reloadTable));
            testCase.verifyEqual(reloadTable.Data{1,4},1.35);
        end

        function failedMandatoryPreflightDoesNotFreezeRun(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            sim=adaptive_optopatch.testing.make_simulated_luminos( ...
                "MissingDevice","DMD_Blue");
            app=launch_adaptive_optopatch_gui(sim,"Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app));
            app.setReferenceData(ones(70,90),test_info(root),test_polygon());
            app.setPulseProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1));
            app.setPlanParameter("mode","1p_dmd");
            testCase.verifyError(@()app.freezeCurrentPlan(root), ...
                "adaptive_optopatch:RequiredDeviceMissing");
            testCase.verifyEmpty(dir(fullfile(root,"adaptive_optopatch_run_*")));
        end

        % ---------------------------------------------------------------
        % Canonical identity survives saving, reloading and editing
        % ---------------------------------------------------------------
        function persistsCanonicalFovAndIndependentDerivedMasks(testCase)
            [fovState,polygons]=AoFixtures.fovState();
            folder=tempname; mkdir(folder);
            cleanup=onCleanup(@()AoFixtures.removeFolder(folder)); %#ok<NASGU>
            path=fullfile(folder,"fov_state.mat");
            adaptive_optopatch.save_fov_state(path,fovState);
            loaded=adaptive_optopatch.load_fov_state(path);
            testCase.verifyEqual(string({loaded.cells.cell_id}), ...
                ["cell_001","cell_002","cell_003"]);
            testCase.verifyEqual(loaded.canonical_roi_polygons,polygons(:));
            before=loaded.canonical_roi_masks;
            first=adaptive_optopatch.build_target_bundle(loaded.reference, ...
                "OrangeExpansionPixels",1,"BlueMaskAdjustmentPixels",-1, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1);
            second=adaptive_optopatch.build_target_bundle(loaded.reference, ...
                "OrangeExpansionPixels",4,"BlueMaskAdjustmentPixels",2, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1);
            testCase.verifyEqual(loaded.canonical_roi_masks,before);
            testCase.verifyGreaterThan(nnz(second.orange_combined_mask), ...
                nnz(first.orange_combined_mask));
            testCase.verifyGreaterThan(nnz(second.blue_camera_masks), ...
                nnz(first.blue_camera_masks));
        end

        function guiReloadsFovWithStableIdsAndCalibration(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [first,~]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root);
            cleanupFirst=onCleanup(@()delete(first)); %#ok<NASGU>
            polygons={[15 15;25 15;25 25;15 25], ...
                [45 30;55 30;55 40;45 40]};
            first.setReferenceData(ones(70,90),AoFixtures.unifiedInfo(root),polygons);
            first.setCellCalibration("cell_002",1.25,"manual");
            path=fullfile(root,"persistent_fov.mat");
            first.saveCurrentFov(path);
            [second,~]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root);
            cleanupSecond=onCleanup(@()delete(second)); %#ok<NASGU>
            second.loadFov(path);
            second.setPulseProtocol(adaptive_optopatch.generate_single_cell_ramp_protocol( ...
                [0.75 1.25],"RepeatsPerVoltage",1));
            second.setPlanParameter("mode","1p_dmd");
            plan=second.buildCurrentPlan();
            testCase.verifyEqual(string({plan.fov_state.cells.cell_id}), ...
                ["cell_001","cell_002"]);
            testCase.verifyEqual(plan.fov_state.cells(2).selected_blue_voltage_v,1.25);
            testCase.verifyEqual(plan.fov_state.canonical_roi_polygons,polygons(:));
        end

        function preservesStableIdsAcrossEditDeleteAddAndReload(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,~]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(),"Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            [~,polygons]=AoFixtures.fovState();
            app.setReferenceData(ones(70,90),AoFixtures.unifiedInfo(root),polygons);
            app.setCellCalibration("cell_003",1.1,"manual");
            firstPath=fullfile(root,"first_fov.mat"); app.saveCurrentFov(firstPath);
            app.loadFov(firstPath);
            moved=polygons{3}+[1 0]; app.setCanonicalRoi("cell_003",moved);
            app.deleteCell("cell_002");
            newId=app.addCanonicalRoi([40 30;49 30;49 39;40 39]);
            testCase.verifyEqual(newId,"cell_004");
            secondPath=fullfile(root,"second_fov.mat"); app.saveCurrentFov(secondPath);
            loaded=adaptive_optopatch.load_fov_state(secondPath);
            testCase.verifyEqual(string({loaded.cells.cell_id}), ...
                ["cell_001","cell_003","cell_004"]);
            testCase.verifyEqual(loaded.cells(2).selected_blue_voltage_v,1.1);
            testCase.verifyEqual(loaded.canonical_roi_polygons{2},moved);
            testCase.verifyEqual(loaded.next_cell_index,5);
        end

        function buildsFreshUnifiedPlansWithoutValidationInvalidation(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()AoFixtures.removeFolder(root)); %#ok<NASGU>
            [app,sim]=open_simulated_test_gui("CameraRoi",AoFixtures.unifiedCameraRoi(), ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            app.setReferenceData(ones(80,100),AoFixtures.unifiedInfo(root), ...
                {[40 30;60 30;60 50;40 50]});
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1,"ModulatorVoltage",1.5, ...
                "StimulationSource","2p_spiral");
            app.setPulseProtocol(protocol);
            twoPhoton=app.buildCurrentPlan();
            testCase.verifyEqual(unique( ...
                string(twoPhoton.manifest.trials.stimulation_mode)),"2p_spiral");
            app.setPlanParameter("mode","1p_dmd");
            onePhoton=app.buildCurrentPlan();
            testCase.verifyEqual(unique( ...
                string(onePhoton.manifest.trials.stimulation_mode)),"2p_spiral", ...
                "The deprecated global mode must not rewrite event sources.");
            testCase.verifyEqual(app.PlanState,"EDITABLE");
            report=app.validateCurrentPlan();
            testCase.verifyTrue(report.passed);
            testCase.verifyEqual(app.PlanState,"EDITABLE");
            changed=adaptive_optopatch.generate_screen_protocol("PulseCount",2);
            changedPath=fullfile(root,"changed_protocol.mat");
            adaptive_optopatch.save_protocol(changedPath,changed);
            app.loadPulseProtocol(changedPath);
            testCase.verifyEqual(app.PlanState,"EDITABLE");
            testCase.verifyEqual(app.PulseProtocolPath,string(changedPath));
        end
    end
end

function set_spatial_controls(app)
app.setPlanParameter("mode","1p_dmd");
app.setPlanParameter("microns_per_pixel",0.47);
app.setPlanParameter("spiral_radius_um",4.5);
app.setPlanParameter("spiral_density_points_per_volt",17);
app.setPlanParameter("orange_expansion_pixels",5);
app.setPlanParameter("blue_mask_adjustment_pixels",2);
end

function verify_spatial_values(testCase,value)
testCase.verifyEqual(string(value.stimulation_mode),"1p_dmd");
testCase.verifyEqual(value.microns_per_pixel,0.47);
testCase.verifyEqual(value.spiral_radius_um,4.5);
testCase.verifyEqual(value.spiral_density_points_per_volt,17);
testCase.verifyEqual(value.orange_expansion_pixels,5);
testCase.verifyEqual(value.blue_mask_adjustment_pixels,2);
end

function positions=test_polygon()
positions={[30 25;50 25;50 45;30 45]};
end

function info=test_info(root)
camera=struct("name","Orca Fusion","ROI",[0 0 90 70],"bin",1, ...
    "x_world_limits",[979 1069],"y_world_limits",[989 1059]);
metadata=struct("rig_name","Virtual_Upright","voltage_camera",camera);
info=struct("snapshot_name","fov_workflow_test", ...
    "snapshot_directory",string(root), ...
    "snapshot_path",string(fullfile(root,"snapshot.mat")),"metadata",metadata);
end

function path=write_snapshot(root)
snap=struct;
snap.img=uint16(ones(30,40)); snap.name="Orca Fusion"; snap.bin=1;
snap.ref2d=imref2d([30 40],[0 40],[0 30]); snap.timestamp=datetime("now");
snap.tform=struct("name","DMD_Blue","tform",affine2d());
path=fullfile(root,"snapshot.mat"); save(path,"snap");
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
