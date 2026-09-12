classdef TestExecutionBatchWorkflow < matlab.unittest.TestCase
    methods (Test)
        function completedFrozenRunStartsDistinctDeterministicBatch(testCase)
            [app,root]=open_batch_app(testCase);
            firstRun=app.runAll();
            firstFolder=app.ActiveRunFolder;
            firstPlan=app.ActiveRunPlan;
            firstIdentity=firstPlan.execution_batch;
            firstOutputDirectories=string(firstRun.trials.experiment_directory);
            checkpointPath=fullfile(firstFolder,"run_checkpoint.mat");
            firstCheckpoint=load(checkpointPath,"run");
            startButton=findall(app.Figure,"Text","Start new batch");

            testCase.verifyEqual(string(startButton.Enable),"on");
            testCase.verifyTrue(app.startNewBatchEnabled());
            paths=app.startNewBatch();
            secondFolder=app.ActiveRunFolder;
            secondPlan=app.ActiveRunPlan;
            secondIdentity=secondPlan.execution_batch;

            testCase.verifyNotEqual(secondFolder,firstFolder);
            testCase.verifyEqual(paths.output_directory,secondFolder);
            testCase.verifyEqual(secondIdentity.batch_number,2);
            testCase.verifyNotEqual(secondIdentity.batch_id,firstIdentity.batch_id);
            testCase.verifyEqual(secondIdentity.frozen_definition_id, ...
                firstIdentity.frozen_definition_id);
            testCase.verifyEqual(secondIdentity.rerun_of_batch_id,firstIdentity.batch_id);
            testCase.verifyEqual(secondIdentity.rerun_of_batch_directory,firstFolder);
            testCase.verifyFalse(secondIdentity.randomized_schedule_reused);
            testCase.verifyTrue(all( ...
                secondPlan.manifest.trials.acquisition_status=="planned"));
            testCase.verifyTrue(all( ...
                secondPlan.manifest.trials.experiment_directory==""));
            testCase.verifyTrue(all(secondPlan.manifest.trials.analysis_status==""));
            testCase.verifyEqual(string(startButton.Enable),"off");
            tableStatuses=string(trial_table(app).Data(:,6));
            testCase.verifyTrue(all(tableStatuses=="planned"));

            testCase.verifyEqual(secondPlan.protocol_definition.random_seed, ...
                firstPlan.protocol_definition.random_seed);
            testCase.verifyEqual(secondPlan.protocol_definition.event_order, ...
                firstPlan.protocol_definition.event_order);
            testCase.verifyEqual(secondPlan.resolved_protocols{1}.events, ...
                firstPlan.resolved_protocols{1}.events);
            testCase.verifyEqual(secondPlan.manifest.trials.pulse_schedule{1}.events, ...
                firstPlan.manifest.trials.pulse_schedule{1}.events);

            unchangedCheckpoint=load(checkpointPath,"run");
            testCase.verifyEqual(unchangedCheckpoint,firstCheckpoint, ...
                "Starting a new batch must not rewrite the completed checkpoint.");
            testCase.verifyTrue(all(isfolder(firstOutputDirectories)));

            partial=app.runNext();
            testCase.verifyEqual(app.ActiveRunFolder,secondFolder);
            testCase.verifyEqual(sum(partial.trials.acquisition_status=="completed"),1);
            testCase.verifyGreaterThan(sum( ...
                partial.trials.acquisition_status=="planned"),0);
            secondRun=app.runAll();
            testCase.verifyTrue(all( ...
                secondRun.trials.acquisition_status=="completed"));
            secondOutputDirectories=string(secondRun.trials.experiment_directory);
            testCase.verifyFalse(any(ismember( ...
                secondOutputDirectories,firstOutputDirectories)));
            testCase.verifyTrue(all(isfolder(secondOutputDirectories)));
            record=load(fullfile(secondOutputDirectories(1),"output_data.mat"), ...
                "adaptive_optopatch_record");
            testCase.verifyEqual( ...
                string(record.adaptive_optopatch_record.trial.batch_id), ...
                secondIdentity.batch_id);
            testCase.verifyEqual( ...
                record.adaptive_optopatch_record.trial.batch_number,2);
        end


        function completedRoundRobinBatchGetsFreshBalancedSchedule(testCase)
            [app,~]=open_batch_app(testCase,"Configure",false);
            configure_round_robin_batch_app(app);
            app.freezeCurrentPlan();
            app.runAll();
            firstFolder=app.ActiveRunFolder;
            firstPlan=app.ActiveRunPlan;
            firstEvents=firstPlan.resolved_protocols{1}.events;
            firstCheckpoint=load(fullfile(firstFolder,"run_checkpoint.mat"),"run");

            paths=app.startNewBatch();
            secondPlan=app.ActiveRunPlan;
            secondEvents=secondPlan.resolved_protocols{1}.events;

            testCase.verifyEqual(groupcounts(firstEvents.target_cell_id),[50;50]);
            testCase.verifyEqual(groupcounts(secondEvents.target_cell_id),[50;50]);
            testCase.verifyNotEqual(secondEvents.target_cell_id, ...
                firstEvents.target_cell_id);
            testCase.verifyEqual(secondEvents.duration_s,firstEvents.duration_s);
            for cellId=unique(firstEvents.target_cell_id,"stable")'
                testCase.verifyEqual(unique(secondEvents.command_voltage_v( ...
                    secondEvents.target_cell_id==cellId)), ...
                    unique(firstEvents.command_voltage_v( ...
                    firstEvents.target_cell_id==cellId)));
            end
            testCase.verifyEqual(secondEvents.blue_mask_adjustment_pixels, ...
                firstEvents.blue_mask_adjustment_pixels);
            testCase.verifyEqual(secondPlan.protocol_definition, ...
                firstPlan.protocol_definition);
            testCase.verifyEqual(secondPlan.manifest.trials.pulse_schedule{1}, ...
                secondPlan.resolved_protocols{1});
            archived=adaptive_optopatch.load_protocol(paths.protocol);
            testCase.verifyEqual(archived.events,secondEvents);
            unchanged=load(fullfile(firstFolder,"run_checkpoint.mat"),"run");
            testCase.verifyEqual(unchanged,firstCheckpoint);
        end

        function resumeContinuesIncompleteBatchWithoutNewIdentity(testCase)
            [app,~]=open_batch_app(testCase);
            app.freezeCurrentPlan();
            originalFolder=app.ActiveRunFolder;
            originalIdentity=app.ActiveRunPlan.execution_batch;
            partial=app.runNext();
            testCase.verifyEqual(sum(partial.trials.acquisition_status=="completed"),1);
            testCase.verifyGreaterThan(sum( ...
                partial.trials.acquisition_status=="planned"),0);
            testCase.verifyFalse(app.startNewBatchEnabled());
            testCase.verifyTrue(app.returnToEditingEnabled());

            resumedPlan=app.resumeRun(originalFolder);
            testCase.verifyEqual(app.ActiveRunFolder,originalFolder);
            testCase.verifyEqual(resumedPlan.execution_batch.batch_id, ...
                originalIdentity.batch_id);
            tableControl=trial_table(app);
            statuses=string(tableControl.Data(:,6));
            testCase.verifyEqual(sum(statuses=="completed"),1);
            testCase.verifyGreaterThan(sum(statuses=="planned"),0);

            completed=app.runAll();
            testCase.verifyEqual(app.ActiveRunFolder,originalFolder);
            testCase.verifyEqual(app.ActiveRunPlan.execution_batch.batch_id, ...
                originalIdentity.batch_id);
            testCase.verifyTrue(all(completed.trials.acquisition_status=="completed"));
            testCase.verifyTrue(app.startNewBatchEnabled());
        end

        function startNewBatchControlRequiresCompletedIdleRun(testCase)
            [app,~]=open_batch_app(testCase,"Configure",false);
            startButton=findall(app.Figure,"Text","Start new batch");
            testCase.verifyNumElements(startButton,1);
            testCase.verifyEqual(string(startButton.Enable),"off");
            testCase.verifyFalse(app.startNewBatchEnabled());
            testCase.verifyFalse(app.returnToEditingEnabled());

            configure_batch_app(app);
            app.freezeCurrentPlan();
            testCase.verifyTrue(app.returnToEditingEnabled());
            observedKey="start_new_batch_during_run";
            timerObject=timer("StartDelay",0.01, ...
                "TimerFcn",@(~,~)capture_running_state( ...
                app,startButton,observedKey));
            timerCleanup=onCleanup(@()delete_timer(timerObject)); %#ok<NASGU>
            start(timerObject);
            app.runNext();
            wait(timerObject);
            observed=getappdata(app.Figure,observedKey);
            testCase.verifyEqual(observed.plan_state,"RUNNING");
            testCase.verifyTrue(observed.controls_locked);
            testCase.verifyEqual(observed.button_enable,"off");
            testCase.verifyFalse(observed.return_to_editing_enabled);
        end

        function runAllHonorsRepeatedBatchCount(testCase)
            [app,root]=open_batch_app(testCase,"Configure",false);
            configure_round_robin_batch_app(app);
            field=repeat_field(app); field.Value=3;

            run=app.runAll();
            folders=run_folders(root);
            testCase.verifyNumElements(folders,3);
            testCase.verifyTrue(all(run.trials.acquisition_status=="completed"));
            identities=strings(3,1);
            schedules=cell(3,1);
            for k=1:3
                manifest=load(fullfile(folders(k),"trial_manifest.mat"),"manifest");
                testCase.verifyTrue(all( ...
                    manifest.manifest.trials.acquisition_status=="planned"));
                checkpoint=load(fullfile(folders(k),"run_checkpoint.mat"),"run");
                testCase.verifyTrue(all( ...
                    checkpoint.run.trials.acquisition_status=="completed"));
                identities(k)=manifest.manifest.execution_batch.batch_id;
                schedules{k}=manifest.manifest.trials.pulse_schedule{1}.events;
                testCase.verifyEqual(groupcounts( ...
                    schedules{k}.target_cell_id),[50;50]);
            end
            testCase.verifyEqual(numel(unique(identities)),3);
            testCase.verifyNotEqual(schedules{1}.target_cell_id, ...
                schedules{2}.target_cell_id);
            testCase.verifyNotEqual(schedules{2}.target_cell_id, ...
                schedules{3}.target_cell_id);
        end

        function oneRepeatedBatchCreatesNoExtraFolder(testCase)
            [app,root]=open_batch_app(testCase);
            field=repeat_field(app); field.Value=1;
            app.runAll();
            testCase.verifyNumElements(run_folders(root),1);
            testCase.verifyEqual(app.ActiveRunPlan.execution_batch.batch_number,1);
        end

        function repeatedBatchFailureStopsBeforeNextBatch(testCase)
            [app,root,sim]=open_batch_app(testCase);
            field=repeat_field(app); field.Value=3;
            sim.FailOnAcquisitionNumber=4;

            testCase.verifyError(@()app.runAll(), ...
                "adaptive_optopatch:SimulatedAcquisitionFailure");
            folders=run_folders(root);
            testCase.verifyNumElements(folders,2);
            first=load(fullfile(folders(1),"run_checkpoint.mat"),"run");
            second=load(fullfile(folders(2),"run_checkpoint.mat"),"run");
            testCase.verifyTrue(all(first.run.trials.acquisition_status=="completed"));
            testCase.verifyEqual(sum( ...
                second.run.trials.acquisition_status=="completed"),1);
            testCase.verifyEqual(sum( ...
                second.run.trials.acquisition_status=="failed"),1);
            testCase.verifyEqual(app.ActiveRunFolder,folders(2));
        end

        function returnToEditingPreservesCurrentExperiment(testCase)
            [app,~,~]=open_batch_app(testCase,"Configure",false);
            configure_round_robin_batch_app(app);
            app.setCellEligibility("cell_002","StimulationEnabled",false);
            app.freezeCurrentPlan();
            folder=app.ActiveRunFolder;
            stateBefore=app.saveCurrentFov(fullfile(fileparts(folder),"before.mat"));
            protocolBefore=app.PulseProtocol;
            roiCountBefore=numel(findall(app.Figure,"Type","images.roi.Polygon"));

            testCase.verifyTrue(app.returnToEditingEnabled());
            app.returnToEditing();

            stateAfter=app.saveCurrentFov(fullfile(fileparts(folder),"after.mat"));
            testCase.verifyEqual(app.PlanState,"EDITABLE");
            testCase.verifyEmpty(app.ActiveRunPlan);
            testCase.verifyEqual(app.ActiveRunFolder,"");
            testCase.verifyEqual(stateAfter.cells,stateBefore.cells);
            testCase.verifyEqual(app.PulseProtocol,protocolBefore);
            testCase.verifyEqual(numel(findall( ...
                app.Figure,"Type","images.roi.Polygon")),roiCountBefore);
            testCase.verifyTrue(isfolder(folder));
        end
    end
end

function [app,root,sim]=open_batch_app(testCase,options)
arguments
    testCase
    options.Configure (1,1) logical = true
end
root=tempname; mkdir(root);
testCase.addTeardown(@()remove_if_present(root));
[app,sim]=open_simulated_test_gui( ...
    "CameraRoi",[974 100 984 80],"Visible","off","RunRoot",root);
testCase.addTeardown(@()delete(app));
if options.Configure, configure_batch_app(app); end
end

function field=repeat_field(app)
field=findall(app.Figure,"Tag","RepeatBatchCount");
end

function folders=run_folders(root)
listing=dir(fullfile(root,"adaptive_optopatch_run_*"));
folders=string(fullfile({listing.folder},{listing.name}))';
folders=sort(folders);
end

function configure_batch_app(app)
info=struct("snapshot_name","batch_workflow", ...
    "snapshot_directory","","snapshot_path","", ...
    "metadata",struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("ROI",[0 0 100 80],"bin",1, ...
    "x_world_limits",[974 1074],"y_world_limits",[984 1064])));
rois={[25 25;40 25;40 40;25 40], ...
    [60 40;75 40;75 55;60 55]};
app.setReferenceData(ones(80,100),info,rois);
protocol=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",1,"ModulatorVoltage",1,"RandomSeed",73);
app.setPulseProtocol(protocol);
app.setPlanParameter("mode","1p_dmd");
end

function configure_round_robin_batch_app(app)
configure_batch_app(app);
app.setCellCalibration("cell_001",0.8);
app.setCellCalibration("cell_002",1.2);
protocol=adaptive_optopatch.generate_round_robin_protocol( ...
    "PulsesPerCell",50,"RandomSeed",73);
app.setPulseProtocol(protocol);
end

function value=trial_table(app)
tables=findall(app.Figure,"Type","uitable");
value=tables(arrayfun(@(table)any(string(table.ColumnName)=="Trial"),tables));
end

function capture_running_state(app,button,key)
value=struct("plan_state",app.PlanState, ...
    "controls_locked",app.ControlsLocked, ...
    "button_enable",string(button.Enable), ...
    "return_to_editing_enabled",app.returnToEditingEnabled());
setappdata(app.Figure,key,value);
end

function delete_timer(value)
if isvalid(value)
    stop(value);
    delete(value);
end
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
