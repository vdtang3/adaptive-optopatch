classdef TestFovWorkflowCleanup < matlab.unittest.TestCase
    methods (Test)
        function savesAndRestoresAllSpatialControls(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            [first,~]=launch_simulated_adaptive_optopatch_gui("Visible","off","RunRoot",root);
            firstCleanup=onCleanup(@()delete(first));
            first.setReferenceData(ones(70,90),test_info(root),test_polygon());
            set_spatial_controls(first);
            path=fullfile(root,"spatial_fov.mat"); first.saveCurrentFov(path);
            saved=load(path,"fov_state"); verify_spatial_values(testCase,saved.fov_state);

            [second,~]=launch_simulated_adaptive_optopatch_gui("Visible","off","RunRoot",root);
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
            [source,~]=launch_simulated_adaptive_optopatch_gui("Visible","off","RunRoot",root);
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

            [app,~]=launch_simulated_adaptive_optopatch_gui("Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app));
            app.setPulseProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1));
            app.loadSnapshot(snapshotPath);
            testCase.verifyError(@()app.buildCurrentPlan(),"adaptive_optopatch:NothingToSave");
        end

        function previewValidateAndFreezeNeedNoManualPlanSave(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            [app,~]=launch_simulated_adaptive_optopatch_gui("Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app));
            app.setReferenceData(ones(70,90),test_info(root),test_polygon());
            app.setPulseProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1));
            app.setPlanParameter("mode","1p_dmd");
            app.previewCurrentPlan();
            report=app.validateCurrentPlan();
            app.setPlanParameter("modulator_voltage",1.4);
            paths=app.freezeCurrentPlan(root);
            testCase.verifyTrue(report.passed);
            testCase.verifyEqual(app.PlanState,"FROZEN");
            for path=[paths.fov_state paths.manifest paths.session paths.protocol]
                testCase.verifyTrue(isfile(path));
            end
            frozen=adaptive_optopatch.load_protocol(paths.protocol);
            testCase.verifyEqual(frozen.events.command_voltage_v,1.4);
        end

        function editableEligibilityIsIndependentAndPersistent(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root));
            [app,~]=launch_simulated_adaptive_optopatch_gui("Visible","off","RunRoot",root);
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
            [loadedApp,~]=launch_simulated_adaptive_optopatch_gui( ...
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
            [app,~]=launch_simulated_adaptive_optopatch_gui("Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app));
            app.setReferenceData(ones(70,90),test_info(root),test_polygon());
            tables=findall(app.Figure,"Type","uitable");
            qc=tables(arrayfun(@(value)numel(value.ColumnName)==9,tables));
            testCase.verifyNumElements(qc,1);
            testCase.verifyEqual(logical(qc.ColumnEditable), ...
                [false false false false false false true true false]);
            callback=qc.CellEditCallback;
            callback(qc,struct("Indices",[1 8],"NewData",false));
            state=app.saveCurrentFov(fullfile(root,"table_edit_fov.mat"));
            testCase.verifyTrue(state.cells(1).recording_enabled);
            testCase.verifyFalse(state.cells(1).stimulation_enabled);
            for text=["Exclude selected from stimulation","Override OBIS", ...
                    "ARM live output","ARM simulated 488 output", ...
                    "Release level","Trajectory reviewed"]
                testCase.verifyEmpty(findall(app.Figure,"Text",text));
            end
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
                "PulseCount",1));
            app.setPlanParameter("mode","1p_dmd");
            testCase.verifyError(@()app.freezeCurrentPlan(root), ...
                "adaptive_optopatch:RequiredDeviceMissing");
            testCase.verifyEmpty(dir(fullfile(root,"adaptive_optopatch_run_*")));
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
camera=struct("ROI",[0 0 90 70],"bin",1, ...
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
