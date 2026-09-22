classdef TestCellDecisionDraft < matlab.unittest.TestCase
    %TESTCELLDECISIONDRAFT Per-cell decisions commit atomically, and cheaply.
    %   THREE DECISIONS, ONE GROUP. recording_enabled, stimulation_enabled
    %   and selected_blue_voltage_v are all in executionInputs.cell_decisions
    %   and a stale plan reports them under one label, so a frontend commits
    %   all three through one apply_plan_draft rather than sending the
    %   voltage straight through per edit.
    %
    %   AND CHANGING ONE MUST BE CHEAP. Every cell-decision mutator used to
    %   call currentFovState, which builds the whole FOV - poly2mask over
    %   every soma, the reference model, an archive of every Luminos device,
    %   a live scanner read, and the complete target bundle - and then kept
    %   only the reference. None of that work can change what a decision
    %   edit produces, and on a rig it is device traffic behind a keystroke.

    methods (Test)
        % ---------------------------------------------------------------
        % A. The draft commits all three together
        % ---------------------------------------------------------------
        function oneDraftCommitsEligibilityAndVoltageTogether(testCase)
            controller=testCase.configuredController();
            draft=struct("cells",struct( ...
                "cell_id",{"cell_001","cell_002"}, ...
                "RecordingEnabled",{[],false}, ...
                "StimulationEnabled",{[],[]}, ...
                "SelectedBlueVoltageV",{2.5,[]}));

            controller.applyPlanDraft(draft);

            rows=controller.getState().cells;
            testCase.verifyEqual(testCase.rowFor(rows,"cell_001").selected_blue_voltage_v,2.5);
            testCase.verifyFalse(testCase.rowFor(rows,"cell_002").recording_enabled);
        end

        function theActionEndpointCarriesTheVoltage(testCase)
            % The whole point of drafting it: the browser sends one action.
            controller=testCase.configuredController();
            payload=struct("cells",{{ ...
                struct("cell_id","cell_001","selected_blue_voltage_v",3.25), ...
                struct("cell_id","cell_002","stimulation_enabled",false)}});

            response=adaptive_optopatch.apply_controller_action( ...
                controller,"apply_plan_draft",payload,controller.Revision);

            testCase.verifyTrue(response.ok,response.message);
            rows=response.state.cells;
            testCase.verifyEqual(testCase.rowFor(rows,"cell_001").selected_blue_voltage_v,3.25);
            testCase.verifyFalse(testCase.rowFor(rows,"cell_002").stimulation_enabled);
        end

        function anInvalidVoltageRollsTheWholeDraftBack(testCase)
            controller=testCase.configuredController();
            before=controller.getState();
            payload=struct("cells",{{ ...
                struct("cell_id","cell_001","selected_blue_voltage_v",2.5), ...
                struct("cell_id","cell_002","recording_enabled",false), ...
                struct("cell_id","cell_002","selected_blue_voltage_v",9)}});

            response=adaptive_optopatch.apply_controller_action( ...
                controller,"apply_plan_draft",payload,before.revision);

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.status,"validation_error");
            after=controller.getState();
            testCase.verifyEqual(after.revision,before.revision, ...
                "A refused draft must leave the revision where it was.");
            testCase.verifyEqual( ...
                testCase.rowFor(after.cells,"cell_001").selected_blue_voltage_v, ...
                testCase.rowFor(before.cells,"cell_001").selected_blue_voltage_v, ...
                "None of the valid edits may be kept either.");
            testCase.verifyTrue(testCase.rowFor(after.cells,"cell_002").recording_enabled);
        end

        function anUnknownCellRollsTheWholeDraftBack(testCase)
            controller=testCase.configuredController();
            before=controller.getState();
            payload=struct("cells",{{ ...
                struct("cell_id","cell_001","selected_blue_voltage_v",2.5), ...
                struct("cell_id","cell_999","selected_blue_voltage_v",2.5)}});

            response=adaptive_optopatch.apply_controller_action( ...
                controller,"apply_plan_draft",payload,before.revision);

            testCase.verifyFalse(response.ok);
            after=controller.getState();
            testCase.verifyEqual( ...
                testCase.rowFor(after.cells,"cell_001").selected_blue_voltage_v, ...
                testCase.rowFor(before.cells,"cell_001").selected_blue_voltage_v);
        end

        function calibrationProvenanceSurvivesADraftCommit(testCase)
            % A drafted voltage is stored the way the direct action stores
            % it: notes and acquisition carried forward, and the calibration
            % SNAPSHOT not replaced - a typed number was not measured.
            controller=testCase.configuredController();
            controller.setCellCalibration("cell_001",1.2,"measured on the ramp");
            snapshotBefore=controller.CellState.cells(1).blue_calibration;

            controller.applyPlanDraft(struct("cells",struct( ...
                "cell_id","cell_001","RecordingEnabled",[], ...
                "StimulationEnabled",[],"SelectedBlueVoltageV",2.5)));

            record=controller.CellState.cells(1);
            testCase.verifyEqual(record.selected_blue_voltage_v,2.5);
            testCase.verifyEqual(string(record.calibration_notes), ...
                "measured on the ramp","Notes must survive.");
            testCase.verifyEqual(record.blue_calibration,snapshotBefore, ...
                "The measured snapshot must not be replaced by a typed value.");
        end

        function theDirectActionStillWorksForTheMatlabTable(testCase)
            % set_cell_blue_voltage stays on the allowlist: the MATLAB cell
            % table and scripted calibration workflows use it. Only the
            % React table stopped calling it interactively.
            controller=testCase.configuredController();
            response=adaptive_optopatch.apply_controller_action( ...
                controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",4.0), ...
                controller.Revision);

            testCase.verifyTrue(response.ok,response.message);
            testCase.verifyEqual( ...
                testCase.rowFor(response.state.cells,"cell_001").selected_blue_voltage_v,4);
        end

        function aVoltageEditStalesThePreparedPlan(testCase)
            % It is an execution input, which is the reason it belongs in
            % the draft rather than beside it.
            controller=testCase.configuredController();
            controller.updatePlan();
            testCase.assertEqual(controller.planStatus(),"ready");

            controller.setCellBlueVoltage("cell_001",2.5);

            testCase.verifyEqual(controller.planStatus(),"update_required");
            testCase.verifyTrue(any(controller.stalePlanInputs()=="cell_decisions"));
        end

        % ---------------------------------------------------------------
        % B. A decision edit is cheap
        % ---------------------------------------------------------------
        function aDecisionEditLooksUpNoDevice(testCase)
            % The simulated app records every getDevice lookup, which is how
            % "did not touch the rig" is distinguishable from "probably did
            % not". buildSpatialArtifacts reads the scanner and archives
            % every device; a checkbox must do neither.
            [controller,app]=testCase.controllerWithLookupLog();

            app.DeviceLookupLog=strings(0,1);
            controller.setCellEligibility("cell_001","StimulationEnabled",false);
            controller.setCellBlueVoltage("cell_002",2.5);

            testCase.verifyEmpty(app.DeviceLookupLog, ...
                "A cell decision must not look a device up at all.");
        end

        function aDecisionEditDoesNotRasteriseTheSomata(testCase)
            % somaRasterisations counts how often the soma masks have been
            % built. A decision changes no polygon, so none is needed.
            controller=testCase.recordingController();
            controller.getState();
            before=controller.somaRasterisations();

            controller.setCellEligibility("cell_001","RecordingEnabled",false);
            controller.setCellBlueVoltage("cell_001",2.5);
            controller.getState();

            testCase.verifyEqual(controller.somaRasterisations(),before, ...
                "A decision edit must not rebuild the geometry cache.");
        end

        function savingAFovStillBuildsTheWholeArtifact(testCase)
            % The cheap path must not have cost the save its contents.
            controller=testCase.configuredController();
            controller.setCellBlueVoltage("cell_001",2.5);

            [path,fovState]=controller.saveNextFov();

            testCase.verifyTrue(isfile(path));
            testCase.verifyTrue(isfield(fovState,"canonical_roi_masks"), ...
                "A saved FOV still carries its rasterised masks.");
            testCase.verifyEqual(fovState.cells(1).selected_blue_voltage_v,2.5);
        end

        function cellsDrawnSinceTheLastDecisionAreStillKnown(testCase)
            % The cheap state is rebuilt from FovGeometry's cell list, so a
            % soma drawn after the last decision has a record to edit.
            controller=testCase.configuredController();
            controller.setCellBlueVoltage("cell_001",2.5);
            newId=controller.addSomaPolygon([10 10; 20 10; 20 20; 10 20]);

            controller.setCellEligibility(newId,"StimulationEnabled",false);

            rows=controller.getState().cells;
            testCase.verifyFalse(testCase.rowFor(rows,newId).stimulation_enabled);
            testCase.verifyEqual( ...
                testCase.rowFor(rows,"cell_001").selected_blue_voltage_v,2.5, ...
                "And the earlier decision is still there.");
        end
    end

    % -------------------------------------------------------------------
    methods (Access=private)
        function row=rowFor(testCase,rows,cellId)
            ids=arrayfun(@(r)string(r.cell_id),rows);
            index=find(ids==string(cellId),1);
            testCase.assertNotEmpty(index,sprintf("No row for %s.",cellId));
            row=rows(index);
        end

        function controller=recordingController(testCase)
            %RECORDINGCONTROLLER A controller that counts its own rasterisations.
            controller=ControllerCallRecorder( ...
                "LuminosApp",simulatedLuminosApp("CameraRoi",[974 100 984 80]), ...
                "RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
            controller.setReferenceData(testCase.referenceImage(), ...
                testCase.referenceInfo(),testCase.somaPolygons());
            controller.setPlanParameter("mode","1p_dmd");
            controller.setProtocol(testCase.protocol());
        end

        function [controller,app]=controllerWithLookupLog(testCase)
            app=simulatedLuminosApp("CameraRoi",[974 100 984 80]);
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",app,"RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
            controller.setReferenceData(testCase.referenceImage(), ...
                testCase.referenceInfo(),testCase.somaPolygons());
            controller.setPlanParameter("mode","1p_dmd");
        end

        function controller=configuredController(testCase)
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp("CameraRoi",[974 100 984 80]), ...
                "RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
            controller.setReferenceData(testCase.referenceImage(), ...
                testCase.referenceInfo(),testCase.somaPolygons());
            controller.setPlanParameter("mode","1p_dmd");
            controller.setProtocol(testCase.protocol());
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
            info=struct("snapshot_name","cell_decision_test", ...
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
