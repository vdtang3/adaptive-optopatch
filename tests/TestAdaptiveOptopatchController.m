classdef TestAdaptiveOptopatchController < matlab.unittest.TestCase
    %TESTADAPTIVEOPTOPATCHCONTROLLER The UI-independent Adaptive Optopatch seam.
    %   These tests exercise canonical AO state without opening a figure.
    %   They are the contract a non-MATLAB frontend would be written against:
    %   the controller owns FOV geometry, cell identity, plan values, the
    %   frozen run, and the run lifecycle, and it refuses mutations that
    %   would corrupt a live acquisition.

    methods (Test)
        function sessionStateIsReachableWithoutAnyFigure(testCase)
            root=temporary_root(testCase);
            before=findall(groot,"Type","figure");

            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",controller_simulator(),"RunRoot",string(root));
            controller.setReferenceData(ones(80,100), ...
                controller_info(root),controller_polygons());
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1));
            controller.setPlanParameter("mode","1p_dmd");
            controller.freezeRun();
            state=controller.getState();

            testCase.verifyEqual(state.plan_state,"FROZEN");
            testCase.verifyEqual(state.lifecycle,"frozen");
            testCase.verifyEqual(numel(state.cells),2);
            testCase.verifyEqual(findall(groot,"Type","figure"),before, ...
                "The controller must never create a figure.");
        end

        function addingASomaStoresGeometryMaskAndStableIdentity(testCase)
            controller=prepared_controller(testCase);
            polygon=[10 10;22 10;22 22;10 22];

            cellId=controller.addSomaPolygon(polygon);
            state=controller.getState();
            masks=controller.somaMasks();

            testCase.verifyEqual(cellId,"cell_003");
            testCase.verifyEqual(state.soma_polygons{3},polygon);
            testCase.verifyEqual(size(masks),[80 100 3]);
            testCase.verifyGreaterThan(nnz(masks(:,:,3)),0);
            testCase.verifyEqual(state.cells(3).cell_id,"cell_003");
            testCase.verifyEqual(state.cells(3).area_pixels,nnz(masks(:,:,3)));
            testCase.verifyEqual(state.cells(3).qc_status,"PASS");
            testCase.verifyEqual(state.fov.next_cell_index,4);

            % The canonical FOV state carries the same geometry through the
            % existing schema-2 reference model.
            fovState=controller.currentFovState();
            testCase.verifyEqual(string({fovState.cells.cell_id}), ...
                ["cell_001","cell_002","cell_003"]);
            testCase.verifyEqual(fovState.canonical_roi_polygons{3},polygon);
            testCase.verifyEqual(logical(fovState.canonical_roi_masks(:,:,3)), ...
                masks(:,:,3));
        end

        function movingASomaUpdatesGeometryButKeepsItsIdentity(testCase)
            controller=prepared_controller(testCase);
            before=controller.getState();
            moved=before.soma_polygons{1}+[3 0];

            controller.updateSomaPolygon("cell_001",moved);
            after=controller.getState();
            masks=controller.somaMasks();

            testCase.verifyEqual(after.soma_polygons{1},moved);
            testCase.verifyEqual(cell_ids(after),cell_ids(before));
            testCase.verifyEqual(after.cells(1).centroid_xy, ...
                before.cells(1).centroid_xy+[3 0],"AbsTol",1e-9);
            testCase.verifyEqual(after.cells(1).area_pixels,nnz(masks(:,:,1)));
            testCase.verifyEqual(after.fov.next_cell_index, ...
                before.fov.next_cell_index);
            testCase.verifyError(@()controller.updateSomaPolygon("cell_009",moved), ...
                "adaptive_optopatch:UnknownCellId");
        end

        function deletingASomaRetiresOnlyItsOwnIdentity(testCase)
            controller=prepared_controller(testCase);
            controller.setCellCalibration("cell_002",1.1,"manual");

            controller.deleteCell("cell_001");
            afterDelete=controller.getState();
            newId=controller.addSomaPolygon([50 20;62 20;62 32;50 32]);
            afterAdd=controller.getState();

            testCase.verifyEqual(cell_ids(afterDelete),"cell_002");
            testCase.verifyEqual(newId,"cell_003", ...
                "A deleted cell number must never be reused.");
            testCase.verifyEqual(cell_ids(afterAdd),["cell_002";"cell_003"]);
            testCase.verifyEqual(afterAdd.cells(1).selected_blue_voltage_v,1.1, ...
                "Surviving cells keep their calibration.");
        end

        function cellEligibilityIsMutableWithoutAGui(testCase)
            controller=prepared_controller(testCase);

            controller.setCellEligibility("cell_002","StimulationEnabled",false);
            controller.setCellEligibility("cell_001","RecordingEnabled",false);
            state=controller.getState();
            fovState=controller.currentFovState();

            testCase.verifyFalse(state.cells(1).recording_enabled);
            testCase.verifyTrue(state.cells(1).stimulation_enabled);
            testCase.verifyTrue(state.cells(2).recording_enabled);
            testCase.verifyFalse(state.cells(2).stimulation_enabled);
            testCase.verifyFalse(fovState.cells(2).stimulation_enabled);
            testCase.verifyError( ...
                @()controller.setCellEligibility("cell_009", ...
                "RecordingEnabled",false),"adaptive_optopatch:UnknownCellId");
        end

        function planParametersAreMutableWithoutAGui(testCase)
            controller=prepared_controller(testCase);

            controller.setPlanParameter("mode","1p_dmd");
            controller.setPlanParameter("blue_mask_adjustment_pixels",3);
            controller.setPlanParameter("maximum_velocity",2500);
            controller.setPlanParameter("repeat_batch_count",2);
            parameters=controller.getState().plan_parameters;

            testCase.verifyEqual(parameters.stimulation_mode,"1p_dmd");
            testCase.verifyEqual(parameters.blue_mask_adjustment_pixels,3);
            testCase.verifyEqual(parameters.maximum_velocity_v_per_s,2500);
            testCase.verifyEqual(parameters.repeat_batch_count,2);
            testCase.verifyError(@()controller.setPlanParameter("modulator_voltage",1), ...
                "adaptive_optopatch:UnknownPlanParameter");
        end

        function freezeConsumesControllerStateRatherThanWidgets(testCase)
            controller=prepared_controller(testCase);
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1));
            controller.setPlanParameter("mode","1p_dmd");
            controller.setPlanParameter("blue_mask_adjustment_pixels",3);
            controller.setCellEligibility("cell_002","StimulationEnabled",false);

            paths=controller.freezeRun();
            plan=controller.ActiveRunPlan;
            schedule=plan.manifest.trials.pulse_schedule{1};

            testCase.verifyEqual(unique( ...
                schedule.events.blue_mask_adjustment_pixels),3);
            testCase.verifyEqual(plan.session.parameters.blue_mask_adjustment_pixels,3);
            testCase.verifyEqual(unique(string( ...
                plan.manifest.trials.stimulation_mode)),"1p_dmd");
            testCase.verifyEqual(unique(schedule.events.target_cell_id( ...
                ~schedule.events.is_null)),"cell_001", ...
                "A stimulation-disabled cell must not be scheduled.");
            testCase.verifyEqual(controller.ActiveRunFolder,paths.output_directory);
            testCase.verifyEqual(controller.LifecycleState,"FROZEN");
            testCase.verifyFalse(controller.EditableStateChanged);
        end

        function backendRefusesMutationsWhileAnAcquisitionIsActive(testCase)
            controller=runnable_controller(testCase);
            observed=strings(0,1);
            probed=false;
            controller.StateChangedFcn=@probe_guards;

            controller.runNext();
            controller.StateChangedFcn=[];

            testCase.verifyTrue(probed, ...
                "The guards must have been probed during the acquisition.");
            testCase.verifyEqual(unique(observed), ...
                "adaptive_optopatch:AcquisitionActive");
            testCase.verifyNumElements(observed,5);
            % The same mutations are accepted again once the run is over.
            testCase.verifyEqual(controller.LifecycleState,"FROZEN");
            controller.setPlanParameter("blue_mask_adjustment_pixels",2);
            testCase.verifyEqual( ...
                controller.PlanParameters.blue_mask_adjustment_pixels,2);

            function probe_guards()
                if controller.LifecycleState~="RUNNING" || probed, return; end
                probed=true;
                observed=[observed;guard_error( ...
                    @()controller.addSomaPolygon([1 1;9 1;9 9;1 9]))];
                observed=[observed;guard_error( ...
                    @()controller.updateSomaPolygon("cell_001", ...
                    [1 1;9 1;9 9;1 9]))];
                observed=[observed;guard_error(@()controller.deleteCell("cell_001"))];
                observed=[observed;guard_error( ...
                    @()controller.setPlanParameter("blue_mask_adjustment_pixels",7))];
                observed=[observed;guard_error(@()controller.returnToEditing())];
            end
        end

        function stateSnapshotCarriesNoHandlesAndSerializesAsJson(testCase)
            controller=prepared_controller(testCase);
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1));
            controller.setPlanParameter("mode","1p_dmd");
            controller.freezeRun();
            state=controller.getState();

            verify_plain_data(testCase,state,"state");
            testCase.verifyFalse(isfield(state,"reference_image"));
            testCase.verifyFalse(isfield(state,"masks"));

            encoded=jsonencode(state);
            testCase.verifyClass(encoded,"char");
            decoded=jsondecode(encoded);
            testCase.verifyEqual(decoded.revision,state.revision);
            testCase.verifyEqual(string(decoded.plan_state),"FROZEN");
            testCase.verifyNumElements(decoded.cells,2);
            testCase.verifyEqual(string(decoded.cells(1).cell_id),"cell_001");
            testCase.verifyEqual(string(decoded.lifecycle),"frozen");
        end

        function revisionAdvancesWithEveryCanonicalMutation(testCase)
            controller=prepared_controller(testCase);
            revisions=controller.Revision;

            controller.addSomaPolygon([10 10;22 10;22 22;10 22]);
            revisions(end+1)=controller.Revision;
            controller.updateSomaPolygon("cell_003",[11 11;23 11;23 23;11 23]);
            revisions(end+1)=controller.Revision;
            controller.setCellEligibility("cell_003","StimulationEnabled",false);
            revisions(end+1)=controller.Revision;
            controller.setPlanParameter("spiral_radius_um",7);
            revisions(end+1)=controller.Revision;
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1));
            revisions(end+1)=controller.Revision;
            controller.deleteCell("cell_003");
            revisions(end+1)=controller.Revision;

            testCase.verifyTrue(all(diff(revisions)>0), ...
                "Every canonical mutation must advance the state revision.");
            testCase.verifyEqual(controller.getState().revision,controller.Revision);
        end

        function savedFovAndFrozenRunArtifactsStayCompatible(testCase)
            controller=runnable_controller(testCase);
            root=controller.RunRoot;
            fovPath=fullfile(root,"controller_fov.mat");

            saved=controller.saveFov(fovPath);
            paths=controller.freezeRun();

            % The persisted FOV still satisfies the package loader.
            loaded=adaptive_optopatch.load_fov_state(fovPath);
            testCase.verifyEqual(string(loaded.schema_version),"2.0.0");
            testCase.verifyEqual(string({loaded.cells.cell_id}), ...
                string({saved.cells.cell_id}));
            testCase.verifyEqual(loaded.canonical_roi_polygons, ...
                saved.canonical_roi_polygons);

            % A fresh controller reconstructs the same canonical state.
            restored=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",controller_simulator());
            restored.loadFov(fovPath);
            testCase.verifyEqual(cell_ids(restored.getState()), ...
                cell_ids(controller.getState()));
            testCase.verifyEqual(restored.getState().soma_polygons, ...
                controller.getState().soma_polygons);
            testCase.verifyEqual(restored.FovGeometry.next_cell_index, ...
                controller.FovGeometry.next_cell_index);

            % The frozen run keeps its existing on-disk shape and resumes.
            for name=["reference_model.mat","pattern_bundle.mat", ...
                    "trial_manifest.mat","planning_session.mat", ...
                    "pulse_protocol.mat","protocol_definition.mat","fov_state.mat"]
                testCase.verifyTrue(isfile(fullfile(paths.output_directory,name)), ...
                    sprintf("Frozen run must still contain %s.",name));
            end
            resumed=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",controller_simulator());
            plan=resumed.resumeRun(string(paths.output_directory));
            testCase.verifyEqual(resumed.LifecycleState,"FROZEN");
            testCase.verifyEqual(height(plan.manifest.trials), ...
                height(controller.ActiveRunPlan.manifest.trials));
        end

        function theMatlabGuiRendersAndEditsTheSameControllerState(testCase)
            root=temporary_root(testCase);
            [app,~]=open_simulated_test_gui("CameraRoi",[974 100 984 80], ...
                "Visible","off","RunRoot",string(root));
            testCase.addTeardown(@()delete(app));
            app.setReferenceData(ones(80,100),controller_info(root), ...
                controller_polygons());
            controller=app.Controller;

            % A widget edit becomes canonical controller state.
            field=findall(app.Figure,"Tag","RepeatBatchCount");
            field.Value=2; field.ValueChangedFcn(field,[]);
            testCase.verifyEqual(controller.PlanParameters.repeat_batch_count,2);

            % A controller mutation made outside the GUI is rendered by it.
            controller.addSomaPolygon([10 10;22 10;22 22;10 22]);
            polygons=findall(app.Figure,"Type","images.roi.Polygon");
            testCase.verifyNumElements(polygons,3);
            testCase.verifyEqual(sort(string({polygons.Label})), ...
                ["cell_001","cell_002","cell_003"]);
            qc=findall(app.Figure,"Type","uitable");
            qc=qc(arrayfun(@(t)any(string(t.ColumnName)=="Cell ID"),qc));
            testCase.verifyEqual(string(qc.Data(:,1))', ...
                ["cell_001","cell_002","cell_003"]);

            controller.setPlanParameter("mode","1p_dmd");
            mode=findall(app.Figure,"Type","uidropdown");
            testCase.verifyEqual(string(mode.Value),"1p_dmd");

            % And a GUI ROI edit routes back through the controller.
            moved=polygons(1).Position+[1 0];
            app.setCanonicalRoi(string(polygons(1).Label),moved);
            testCase.verifyEqual(controller.getState().soma_polygons{ ...
                find(cell_ids(controller.getState())== ...
                string(polygons(1).Label),1)},moved);
        end
    end
end

function controller=prepared_controller(testCase)
root=temporary_root(testCase);
controller=adaptive_optopatch.AdaptiveOptopatchController( ...
    "LuminosApp",controller_simulator(),"RunRoot",string(root));
controller.setReferenceData(ones(80,100),controller_info(root), ...
    controller_polygons());
end

function controller=runnable_controller(testCase)
controller=prepared_controller(testCase);
controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",1,"ModulatorVoltage",1));
controller.setPlanParameter("mode","1p_dmd");
end

function app=controller_simulator()
app=simulatedLuminosApp("CameraRoi",[974 100 984 80]);
end

function polygons=controller_polygons()
polygons={[25 25;40 25;40 40;25 40],[60 40;75 40;75 55;60 55]};
end

function info=controller_info(root)
camera=struct("ROI",[0 0 100 80],"bin",1, ...
    "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
info=struct("snapshot_name","controller_seam", ...
    "snapshot_directory",string(root), ...
    "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
    "metadata",struct("rig_name","Virtual_Upright","voltage_camera",camera));
end

function root=temporary_root(testCase)
root=tempname; mkdir(root);
testCase.addTeardown(@()remove_if_present(root));
end

function ids=cell_ids(state)
if isempty(state.cells), ids=strings(0,1); return; end
ids=reshape(string({state.cells.cell_id}),[],1);
end

function identifier=guard_error(operation)
identifier="<no error>";
try
    operation();
catch exception
    identifier=string(exception.identifier);
end
end

function verify_plain_data(testCase,value,path)
%VERIFY_PLAIN_DATA Assert a state snapshot holds only serializable data.
testCase.verifyFalse(isobject(value)&&~isstring(value), ...
    sprintf("%s must not contain an object.",path));
testCase.verifyFalse(any(ishandle(value(:))&~isnumeric(value(:))), ...
    sprintf("%s must not contain a handle.",path));
if isstruct(value)
    for name=string(fieldnames(value))'
        for k=1:numel(value)
            verify_plain_data(testCase,value(k).(name),path+"."+name);
        end
    end
    return
end
if iscell(value)
    for k=1:numel(value)
        verify_plain_data(testCase,value{k},sprintf("%s{%d}",path,k));
    end
    return
end
testCase.verifyTrue(isnumeric(value)||islogical(value)|| ...
    ischar(value)||isstring(value), ...
    sprintf("%s has unsupported class %s.",path,class(value)));
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
