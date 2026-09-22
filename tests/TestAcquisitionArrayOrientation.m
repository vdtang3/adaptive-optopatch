classdef TestAcquisitionArrayOrientation < matlab.unittest.TestCase
    %TESTACQUISITIONARRAYORIENTATION Shape must not change meaning.
    %   `for x = array` walks COLUMNS. A 1xN acquisition array therefore
    %   gives N scalar iterations and an Nx1 array gives ONE iteration
    %   carrying all N - after which acquisition.events is a comma-separated
    %   list and the failure surfaces somewhere unrelated, if it surfaces at
    %   all. A generator that happened to build its acquisitions with
    %   vertcat produced the second shape.
    %
    %   The workaround was to reshape the generated protocol. That only
    %   moves the assumption to whoever forgets: the invariant has to be
    %   that only NUMEL AND ORDER mean anything, and these tests state it
    %   from both orientations.

    methods (Test)
        function bothOrientationsNormalizeAndValidate(testCase)
            [row,column]=testCase.equivalentProtocols();
            testCase.verifySize(row.acquisitions,[1 3]);
            testCase.verifySize(column.acquisitions,[3 1]);

            for protocol=[{row} {column}]
                report=adaptive_optopatch.validate_protocol(protocol{1});
                testCase.verifyTrue(report.passed,strjoin(report.issues,newline));
            end
        end

        function normalizationDoesNotSilentlyReshape(testCase)
            % The fix is in the CONSUMERS, not in a canonical reshape. If
            % normalize_protocol quietly rewrote the shape, every test below
            % would pass for the wrong reason and the next consumer to use
            % `for x = array` would still be broken.
            [~,column]=testCase.equivalentProtocols();
            normalized=adaptive_optopatch.normalize_protocol(column);
            testCase.verifySize(normalized.acquisitions,[3 1]);
        end

        function bothOrientationsSummarizeIdentically(testCase)
            [row,column]=testCase.equivalentProtocols();
            testCase.verifyEqual( ...
                adaptive_optopatch.summarize_protocol(column), ...
                adaptive_optopatch.summarize_protocol(row));
        end

        function bothOrientationsGiveTheSameRepresentativePulseDuration(testCase)
            % currentPulseDurationMs iterated the array directly. With an
            % Nx1 array the single iteration produced a comma-separated
            % list and the read failed.
            rowController=testCase.controllerWith("row");
            columnController=testCase.controllerWith("column");
            testCase.verifyEqual(columnController.currentPulseDurationMs(), ...
                rowController.currentPulseDurationMs(),"AbsTol",1e-12);
            testCase.verifyEqual(columnController.currentPulseDurationMs(),10, ...
                "AbsTol",1e-12);
        end

        function bothOrientationsBuildTheSamePlan(testCase)
            % buildPlan iterated the array to find the representative pulse
            % duration, which is what sizes the target bundle.
            rowController=testCase.controllerWith("row");
            columnController=testCase.controllerWith("column");
            rowController.updatePlan();
            columnController.updatePlan();

            rowPlan=rowController.ActiveRunPlan;
            columnPlan=columnController.ActiveRunPlan;
            testCase.verifyEqual(height(columnPlan.manifest.trials), ...
                height(rowPlan.manifest.trials));
            testCase.verifyEqual(numel(columnPlan.resolved_protocols), ...
                numel(rowPlan.resolved_protocols));
            for k=1:numel(rowPlan.resolved_protocols)
                testCase.verifyEqual( ...
                    columnPlan.resolved_protocols{k}.events.target_cell_id, ...
                    rowPlan.resolved_protocols{k}.events.target_cell_id);
                testCase.verifyEqual( ...
                    columnPlan.resolved_protocols{k}.events.onset_s, ...
                    rowPlan.resolved_protocols{k}.events.onset_s,"AbsTol",1e-12);
                testCase.verifyEqual( ...
                    columnPlan.resolved_protocols{k}.acquisition_id, ...
                    rowPlan.resolved_protocols{k}.acquisition_id);
            end
        end

        function bothOrientationsResolveTheSameAcquisitionsAndEventCounts(testCase)
            [row,column]=testCase.equivalentProtocols();
            [fovState,targets]=testCase.fov();
            rowResolved=adaptive_optopatch.resolve_protocol(row,fovState, ...
                targets,AoFixtures.guiDefaults());
            columnResolved=adaptive_optopatch.resolve_protocol(column,fovState, ...
                targets,AoFixtures.guiDefaults());

            testCase.verifyEqual(numel(columnResolved),numel(rowResolved));
            for k=1:numel(rowResolved)
                testCase.verifyEqual(columnResolved{k}.acquisition_id, ...
                    rowResolved{k}.acquisition_id, ...
                    "Order must be preserved, whatever the shape.");
                testCase.verifyEqual(height(columnResolved{k}.events), ...
                    height(rowResolved{k}.events));
                testCase.verifyEqual(columnResolved{k}.events.onset_s, ...
                    rowResolved{k}.events.onset_s,"AbsTol",1e-12);
            end
        end

        function theConnectivityGeneratorsShapeIsNotLoadBearing(testCase)
            % It builds its chunks with vertcat, so it returns Nx1. That is
            % allowed; nothing may depend on it either way.
            protocol=adaptive_optopatch.generate_connectivity_chunked_protocol( ...
                "TotalPulsesPerCell",8,"PulsesPerCellPerChunk",4, ...
                "BaseRandomSeed",4242);
            testCase.verifyEqual(numel(protocol.acquisitions),2);
            report=adaptive_optopatch.validate_protocol(protocol);
            testCase.verifyTrue(report.passed,strjoin(report.issues,newline));
        end
    end

    % -------------------------------------------------------------------
    methods (Access=private)
        function [row,column]=equivalentProtocols(testCase)
            %EQUIVALENTPROTOCOLS The same three acquisitions, two shapes.
            acquisitions=[testCase.acquisition("acq_1",0.010), ...
                testCase.acquisition("acq_2",0.012), ...
                testCase.acquisition("acq_3",0.014)];
            row=testCase.protocolWith(reshape(acquisitions,1,[]));
            column=testCase.protocolWith(reshape(acquisitions,[],1));
        end

        function acquisition=acquisition(~,acquisitionId,duration)
            pulse_id=(1:2)';
            condition_id=repmat(string(acquisitionId),2,1);
            stimulation_source=repmat("1p_dmd",2,1);
            onset_s=[0.1;0.2];
            duration_s=repmat(duration,2,1);
            is_null=false(2,1);
            command_voltage_v=repmat(1.4,2,1);
            blue_mask_adjustment_pixels=NaN(2,1);
            events=table(pulse_id,condition_id,stimulation_source,onset_s, ...
                duration_s,is_null,command_voltage_v,blue_mask_adjustment_pixels);
            acquisition=struct("acquisition_id",string(acquisitionId), ...
                "events",events,"parameters",struct, ...
                "event_order_realized",true,"target_repetitions",1, ...
                "post_delay_s",0.05);
        end

        function protocol=protocolWith(~,acquisitions)
            protocol=struct("schema_version","4.0.0", ...
                "artifact_type","experiment_definition", ...
                "protocol_id","orientation_fixture", ...
                "protocol_type","orientation_fixture", ...
                "target_policy","each_stimulation_enabled_cell", ...
                "event_order","ordered","random_seed",5, ...
                "parameter_sources",struct("command_voltage_v", ...
                    ["event","acquisition","protocol","fov_cell"]), ...
                "parameters",struct,"acquisitions",acquisitions);
        end

        function [fovState,targets]=fov(~)
            [fovState,~]=AoFixtures.fovState();
            for k=1:numel(fovState.cells)
                fovState.cells(k).stimulation_enabled=k==1;
                fovState.cells(k).selected_blue_voltage_v=1.4;
            end
            fovState.reference.cells=fovState.cells;
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
        end

        function controller=controllerWith(testCase,orientation)
            [row,column]=testCase.equivalentProtocols();
            if orientation=="row", protocol=row; else, protocol=column; end
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp("CameraRoi",[974 100 984 80]), ...
                "RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
            image=uint16(reshape(mod(1:80*100,4096),80,100));
            camera=struct("name","Orca Fusion","ROI",[0 0 100 80],"bin",1, ...
                "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
            root=testCase.temporaryFolder();
            info=struct("snapshot_name","orientation_test", ...
                "snapshot_directory",string(root), ...
                "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
                "metadata",struct("rig_name","Virtual_Upright", ...
                    "voltage_camera",camera));
            controller.setReferenceData(image,info, ...
                {[25 25; 40 25; 40 40; 25 40]});
            controller.setPlanParameter("mode","1p_dmd");
            controller.setCellBlueVoltage("cell_001",1.4);
            controller.setProtocol(protocol);
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
