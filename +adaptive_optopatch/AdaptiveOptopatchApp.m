classdef AdaptiveOptopatchApp < adaptive_optopatch.ReferencePreparationApp
    %ADAPTIVEOPTOPATCHAPP Unified editable-plan and run workflow.
    %   Like its base class, this app is a view over
    %   adaptive_optopatch.AdaptiveOptopatchController. Protocol identity,
    %   editable plan values, the frozen run, and the run lifecycle all live
    %   in the controller; the buttons, tables, and labels here render that
    %   state and send user actions back to it.
    properties (Dependent, SetAccess=private)
        %PLANSTATE Lifecycle as AO has always named it: EDITABLE/FROZEN/RUNNING.
        PlanState
        ActiveRunFolder
        ActiveRunPlan
        LastRun
        %CONTROLSLOCKED Whether an acquisition is currently holding the session.
        ControlsLocked
        PulseProtocol
        PulseProtocolPath
        PulseProtocolSummary
        EditableStateChanged
    end
    properties (Access=private)
        UnifiedReady logical = false
        StateLabel
        ProtocolPathField
        ProtocolSummaryArea
        LoadProtocolButton
        MaximumVelocity
        MaximumAcceleration
        AllowCalibrationExtrapolation
        AllowCameraRateOverride
        TrialTable
        WaveformAxes
        RunNextButton
        RunAllButton
        RepeatBatchCount
        StartNewBatchButton
        ReturnToEditingButton
        StopButton
        OnePhotonControls cell = {}
        TwoPhotonControls cell = {}
        LockSnapshot cell = {}
        WidgetsLocked logical = false
    end

    methods
        function app=AdaptiveOptopatchApp(options)
            arguments
                options.LuminosApp = []
                options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
                options.RunRoot (1,1) string = ""
            end
            app@adaptive_optopatch.ReferencePreparationApp( ...
                "LuminosApp",options.LuminosApp,"Visible",options.Visible);
            app.Controller.RunRoot=options.RunRoot;
            app.buildUnifiedUI();
            app.UnifiedReady=true;
            app.refreshFromController();
        end

        function value=get.PlanState(app), value=app.Controller.LifecycleState; end
        function value=get.ActiveRunFolder(app), value=app.Controller.ActiveRunFolder; end
        function value=get.ActiveRunPlan(app), value=app.Controller.ActiveRunPlan; end
        function value=get.LastRun(app), value=app.Controller.LastRun; end
        function value=get.ControlsLocked(app)
            value=app.Controller.LifecycleState=="RUNNING";
        end
        function value=get.PulseProtocol(app), value=app.Controller.Protocol; end
        function value=get.PulseProtocolPath(app), value=app.Controller.ProtocolPath; end
        function value=get.PulseProtocolSummary(app), value=app.Controller.ProtocolSummary; end
        function value=get.EditableStateChanged(app)
            value=app.Controller.EditableStateChanged;
        end

        function plan=buildCurrentPlan(app)
            plan=app.Controller.buildPlan();
        end

        function protocol=loadPulseProtocol(app,path)
            protocol=app.Controller.loadProtocol(path);
        end

        function setPulseProtocol(app,protocol,path)
            arguments
                app
                protocol (1,1) struct
                path (1,1) string = ""
            end
            app.Controller.setProtocol(protocol,path);
        end

        function report=validateCurrentPlan(app)
            report=app.Controller.validateCurrentPlan();
        end

        function report=preflightCurrentPlan(app)
            report=app.Controller.preflightCurrentPlan();
        end

        function report=preflightPlan(app,plan)
            report=app.Controller.preflightPlan(plan);
        end

        function plan=previewCurrentPlan(app)
            app.previewTargets();
            plan=app.Controller.buildPlan();
            cla(app.WaveformAxes);
            if app.Controller.PlanParameters.stimulation_mode=="2p_spiral"
                yyaxis(app.WaveformAxes,"left");
                waveforms=app.Controller.build2pPreviewWaveforms(plan);
                time=(0:numel(waveforms.x_v)-1)'/waveforms.sample_rate_hz;
                step=max(1,ceil(numel(time)/50000)); index=1:step:numel(time);
                plot(app.WaveformAxes,time(index),waveforms.x_v(index), ...
                    time(index),waveforms.y_v(index), ...
                    time(index),waveforms.pockels_v(index));
                legend(app.WaveformAxes,["X","Y","Pockels"],"Location","best");
                xlabel(app.WaveformAxes,"Time (s)"); ylabel(app.WaveformAxes,"Command (V)");
            else
                resolved=plan.manifest.trials.pulse_schedule{1};
                pulses=adaptive_optopatch.flatten_pulse_schedule(resolved);
                time=reshape([pulses.onset_s pulses.onset_s ...
                    pulses.offset_s pulses.offset_s]',[],1);
                command=reshape([zeros(height(pulses),1) pulses.modulator_voltage ...
                    pulses.modulator_voltage zeros(height(pulses),1)]',[],1);
                targetIds=unique(pulses.target_cell_id(~pulses.is_null),"stable");
                counts=arrayfun(@(id)sum(pulses.target_cell_id==id & ~pulses.is_null),targetIds);
                yyaxis(app.WaveformAxes,"left");
                plot(app.WaveformAxes,time,command,"b-");
                ylabel(app.WaveformAxes,"mod488 (V)");
                yyaxis(app.WaveformAxes,"right");
                targetNumber=zeros(height(pulses),1);
                for k=1:numel(targetIds)
                    targetNumber(pulses.target_cell_id==targetIds(k))=k;
                end
                stairs(app.WaveformAxes,pulses.onset_s,targetNumber,"k.", ...
                    "MarkerSize",8);
                app.WaveformAxes.YTick=1:numel(targetIds);
                app.WaveformAxes.YTickLabel=cellstr(targetIds);
                ylabel(app.WaveformAxes,"Target cell");
                xlabel(app.WaveformAxes,"Time (s)");
                title(app.WaveformAxes,sprintf( ...
                    '%d targets; %d pulses; %.3f s | %s', ...
                    numel(targetIds),sum(~pulses.is_null),resolved.acquisition_duration_s, ...
                    strjoin(targetIds+":"+counts,", ")));
            end
        end

        function paths=freezeCurrentPlan(app,outputRoot)
            arguments
                app
                outputRoot (1,1) string = ""
            end
            paths=app.Controller.freezeRun(outputRoot);
        end

        function paths=startNewBatch(app,outputRoot,options)
            %STARTNEWBATCH Reuse one completed frozen definition in a new batch.
            arguments
                app
                outputRoot (1,1) string = ""
                options.Automatic (1,1) logical = false
            end
            paths=app.Controller.startNewBatch(outputRoot, ...
                "Automatic",options.Automatic);
        end

        function value=startNewBatchEnabled(app)
            value=app.Controller.startNewBatchEnabled();
        end

        function paths=startNewRun(app,outputRoot)
            %STARTNEWRUN Freeze current editable state as the active run.
            arguments
                app
                outputRoot (1,1) string = ""
            end
            paths=app.Controller.startNewRun(outputRoot);
        end

        function run=runNext(app)
            run=app.Controller.runNext();
        end

        function run=runAll(app)
            run=app.Controller.runAll();
        end

        function returnToEditing(app)
            app.Controller.returnToEditing();
        end

        function value=returnToEditingEnabled(app)
            value=app.Controller.returnToEditingEnabled();
        end

        function plan=resumeRun(app,folder)
            arguments
                app
                folder (1,1) string
            end
            plan=app.Controller.resumeRun(folder);
        end

        function setPlanParameter(app,name,value)
            app.Controller.setPlanParameter(name,value);
        end

        function setReferenceData(app,image,info,roiPositions)
            arguments
                app
                image (:,:) {mustBeNumeric}
                info (1,1) struct
                roiPositions cell = {}
            end
            app.Controller.setReferenceData(image,info,roiPositions);
        end
    end

    methods (Access=protected)
        function renderState(app,state)
            renderState@adaptive_optopatch.ReferencePreparationApp(app,state);
            if ~app.UnifiedReady, return; end
            app.refreshProtocolDisplay(state);
            app.refreshRunControls(state);
            app.refreshModeVisibility(state);
            app.refreshTrialTable();
        end

        function value=showPlanningBundleControl(~)
            value=false;
        end

        function value=restorePlanningBundleOnSnapshotLoad(~)
            value=false;
        end

        function planningSessionRestored(app,session)
            if ~isfield(session,"pulse_protocol_path") || ...
                    strlength(string(session.pulse_protocol_path))==0
                return
            end
            path=string(session.pulse_protocol_path);
            if isfile(path)
                app.Controller.loadProtocol(path);
            else
                app.Controller.forgetMissingProtocol(path);
            end
        end

        function savePlanningBundle(app)
            try
                plan=app.Controller.buildPlan();
                paths=adaptive_optopatch.save_bundle( ...
                    app.Controller.ReferenceInfo.snapshot_directory, ...
                    plan.reference,plan.targets, ...
                    plan.manifest,"CreateSubfolder",true,"SessionState",plan.session);
                adaptive_optopatch.save_protocol( ...
                    fullfile(paths.output_directory,"pulse_protocol.mat"),plan.protocol);
                app.setStatus("Saved optional editable plan:"+newline+paths.output_directory);
            catch exception
                app.showError(exception);
            end
        end
    end

    methods (Access=private)
        function buildUnifiedUI(app)
            app.Figure.Name="Adaptive Optopatch";
            if isa(app.LuminosApp,"adaptive_optopatch.testing.SimulatedLuminosApp")
                app.Figure.Name=app.Figure.Name+" [SIMULATION]";
            end
            app.Figure.Position=[40 40 1500 940];
            root=app.Figure.Children;
            simulation=isa(app.LuminosApp, ...
                "adaptive_optopatch.testing.SimulatedLuminosApp");
            % Keep the protocol and trial regions stable while allowing the
            % camera/planning region to use additional window height.
            root.RowHeight={"1x",36,250,130,70};
            if ~simulation, root.RowHeight={"1x",0,250,130,70}; end
            banner=uilabel(root,"Text","SIMULATION — NO HARDWARE OUTPUT", ...
                "HorizontalAlignment","center","FontWeight","bold", ...
                "FontSize",16,"FontColor",[1 1 1], ...
                "BackgroundColor",[0.75 0.05 0.05], ...
                "Visible",matlab.lang.OnOffSwitchState(simulation));
            banner.Layout.Row=2; banner.Layout.Column=[1 3];
            app.Status.Layout.Row=5; app.Status.Layout.Column=[1 3];
            planningControls=app.Mode.Parent;
            heights=planningControls.RowHeight;
            heights(:)=repmat({21},size(heights));
            heights(13:18)=repmat({0},1,6);
            planningControls.RowHeight=heights;
            planningControls.RowSpacing=2;
            planningControls.Padding=[4 4 4 4];
            hiddenControls={app.Repeats,app.PulseCount,app.PulseDuration, ...
                app.DarkIntervalMin,app.DarkIntervalMax,app.PreDelay.Parent};
            for k=1:numel(hiddenControls), hiddenControls{k}.Visible="off"; end
            hiddenLabels=["Screen repeats","Pulses / neuron","Pulse duration (ms)", ...
                "Dark gap min (ms)","Dark gap max (ms)", ...
                "Pre / post delay (ms)"];
            for label=hiddenLabels
                object=findall(app.Figure,"Text",label);
                if ~isempty(object), object.Visible="off"; end
            end

            runtime=uigridlayout(root,[1 2]);
            runtime.Layout.Row=3; runtime.Layout.Column=[1 3];
            runtime.ColumnWidth={920,"1x"}; runtime.Padding=[4 4 4 4];
            % Five rows, not six. The panel is given 250 px by the root
            % grid, and a sixth row overflowed it and clipped the buttons
            % sitting on it. Spacing and padding are stated explicitly so
            % the fit is a decision rather than an inherited default.
            controls=uigridlayout(runtime,[5 8]);
            controls.RowHeight={30,45,30,38,30};
            controls.ColumnWidth={105,100,115,105,115,105,115,"1x"};
            controls.RowSpacing=6; controls.ColumnSpacing=6;
            controls.Padding=[6 6 6 6];
            app.StateLabel=uilabel(controls,"Text","Editable — current settings run", ...
                "FontWeight","bold","FontColor",[0 0.35 0.65]);
            app.StateLabel.Layout.Row=1; app.StateLabel.Layout.Column=[1 2];
            app.ProtocolPathField=uieditfield(controls,"text", ...
                "Editable","off","Value","No pulse protocol loaded");
            app.ProtocolPathField.Layout.Row=1; app.ProtocolPathField.Layout.Column=[3 6];
            app.LoadProtocolButton=uibutton(controls,"Text","Load protocol…", ...
                "ButtonPushedFcn",@(~,~)app.chooseProtocol());
            app.LoadProtocolButton.Layout.Row=1; app.LoadProtocolButton.Layout.Column=[7 8];
            app.ProtocolSummaryArea=uitextarea(controls,"Editable","off", ...
                "Value","Load a validated pulse_protocol.mat generated by MATLAB.");
            app.ProtocolSummaryArea.Layout.Row=2; app.ProtocolSummaryArea.Layout.Column=[1 8];
            velocityLabel=uilabel(controls,"Text","Max velocity");
            velocityLabel.Layout.Row=3; velocityLabel.Layout.Column=1;
            app.MaximumVelocity=uieditfield(controls,"numeric","Value",1000,"Limits",[eps Inf]);
            app.MaximumVelocity.Layout.Row=3; app.MaximumVelocity.Layout.Column=2;
            accelerationLabel=uilabel(controls,"Text","Max acceleration");
            accelerationLabel.Layout.Row=3; accelerationLabel.Layout.Column=3;
            app.MaximumAcceleration=uieditfield(controls,"numeric","Value",6e6,"Limits",[eps Inf]);
            app.MaximumAcceleration.Layout.Row=3; app.MaximumAcceleration.Layout.Column=4;
            app.AllowCalibrationExtrapolation=uicheckbox(controls,"Text","Allow cal extrapolation");
            app.AllowCalibrationExtrapolation.Layout.Row=3;
            app.AllowCalibrationExtrapolation.Layout.Column=[5 6];
            app.AllowCameraRateOverride=uicheckbox(controls,"Text","Camera-rate override");
            app.AllowCameraRateOverride.Layout.Row=3;
            app.AllowCameraRateOverride.Layout.Column=[7 8];

            previewButton=uibutton(controls,"Text","Preview", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.previewCurrentPlan()));
            previewButton.Layout.Row=4; previewButton.Layout.Column=1;
            validateButton=uibutton(controls,"Text","Check", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.validateCurrentPlan()));
            validateButton.Layout.Row=4; validateButton.Layout.Column=2;
            app.RunNextButton=uibutton(controls,"Text","Run next", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.runNext()));
            app.RunNextButton.Layout.Row=4; app.RunNextButton.Layout.Column=3;
            app.RunAllButton=uibutton(controls,"Text","Run all", ...
                "FontWeight","bold","ButtonPushedFcn",@(~,~)app.invoke(@()app.runAll()));
            app.RunAllButton.Layout.Row=4; app.RunAllButton.Layout.Column=4;
            app.StopButton=uibutton(controls,"Text","Stop after current", ...
                "Enable","off","ButtonPushedFcn",@(~,~)app.requestStop());
            app.StopButton.Layout.Row=4; app.StopButton.Layout.Column=[5 6];
            resumeButton=uibutton(controls,"Text","Resume run…", ...
                "ButtonPushedFcn",@(~,~)app.chooseResume());
            resumeButton.Layout.Row=4; resumeButton.Layout.Column=[7 8];
            reviewButton=uibutton(controls,"Text","Review completed Blue ramp…", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.chooseRampReview()));
            reviewButton.Layout.Row=5; reviewButton.Layout.Column=[1 2];
            newRunButton=uibutton(controls,"Text","Freeze new run", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.startNewRun()), ...
                "Tooltip",["Freeze the current editable state as a new run " ...
                "and make it the active one. The previous frozen run's " ...
                "artifacts stay on disk and remain resumable."]);
            newRunButton.Layout.Row=5; newRunButton.Layout.Column=3;
            app.ReturnToEditingButton=uibutton(controls,"Text","Return to editing", ...
                "Enable","off", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.returnToEditing()));
            app.ReturnToEditingButton.Layout.Row=5;
            app.ReturnToEditingButton.Layout.Column=[4 5];
            app.StartNewBatchButton=uibutton(controls,"Text","Start new batch", ...
                "Enable","off", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.startNewBatch()), ...
                "Tooltip",["Create a fresh execution batch from the exact " ...
                "completed frozen definition and preserve the prior batch."]);
            app.StartNewBatchButton.Layout.Row=5;
            app.StartNewBatchButton.Layout.Column=6;
            batchLabel=uilabel(controls,"Text","Batches", ...
                "HorizontalAlignment","right");
            batchLabel.Layout.Row=5; batchLabel.Layout.Column=7;
            app.RepeatBatchCount=uieditfield(controls,"numeric", ...
                "Value",1,"Limits",[1 Inf],"RoundFractionalValues","on", ...
                "Tag","RepeatBatchCount");
            app.RepeatBatchCount.Layout.Row=5;
            app.RepeatBatchCount.Layout.Column=8;
            app.WaveformAxes=uiaxes(runtime);
            title(app.WaveformAxes,"Waveform / DMD preview");

            app.TrialTable=uitable(root,"ColumnName", ...
                {'Trial','Cell','Protocol','Duration','Command (V)','Status','Output'});
            app.TrialTable.Layout.Row=4; app.TrialTable.Layout.Column=[1 3];
            app.OnePhotonControls={};
            app.TwoPhotonControls={velocityLabel,app.MaximumVelocity, ...
                accelerationLabel,app.MaximumAcceleration, ...
                app.AllowCalibrationExtrapolation,app.AllowCameraRateOverride};
            app.bindRunControls();
        end

        function bindRunControls(app)
            %BINDRUNCONTROLS Route run-panel widget edits into the controller.
            watched={app.MaximumVelocity,"maximum_velocity_v_per_s"; ...
                app.MaximumAcceleration,"maximum_acceleration_v_per_s2"; ...
                app.AllowCalibrationExtrapolation,"allow_calibration_extrapolation"; ...
                app.AllowCameraRateOverride,"allow_camera_rate_override"; ...
                app.RepeatBatchCount,"repeat_batch_count"};
            for k=1:size(watched,1)
                name=watched{k,2};
                watched{k,1}.ValueChangedFcn= ...
                    @(source,~)app.planControlEdited(name,source.Value);
            end
        end

        function refreshProtocolDisplay(app,state)
            if isempty(app.ProtocolPathField) || ~isvalid(app.ProtocolPathField), return; end
            if ~state.protocol.loaded
                if strlength(state.protocol.path)>0
                    app.ProtocolPathField.Value=char(state.protocol.path);
                    app.ProtocolSummaryArea.Value="Protocol file not found — select a pulse protocol.";
                else
                    app.ProtocolPathField.Value="No pulse protocol loaded";
                    app.ProtocolSummaryArea.Value= ...
                        "Load a validated pulse_protocol.mat generated by MATLAB.";
                end
                return
            end
            if strlength(state.protocol.path)>0
                app.ProtocolPathField.Value=char(state.protocol.path);
            else
                app.ProtocolPathField.Value="In-memory validated protocol";
            end
            s=state.protocol.summary;
            app.ProtocolSummaryArea.Value=sprintf( ...
                ['%s — %s | target policy: %s | %d explicit acquisition(s) | ' ...
                 '%d events (%d light), %d conditions | order: %s | seed %g'], ...
                s.protocol_id,s.protocol_type,s.target_policy, ...
                s.definition_acquisition_count,s.event_count,s.light_event_count, ...
                s.condition_count,s.event_order,s.random_seed);
        end

        function refreshRunControls(app,state)
            if isempty(app.StateLabel) || ~isvalid(app.StateLabel), return; end
            parameters=state.plan_parameters;
            app.MaximumVelocity.Value=parameters.maximum_velocity_v_per_s;
            app.MaximumAcceleration.Value=parameters.maximum_acceleration_v_per_s2;
            app.AllowCalibrationExtrapolation.Value= ...
                parameters.allow_calibration_extrapolation;
            app.AllowCameraRateOverride.Value=parameters.allow_camera_rate_override;
            app.RepeatBatchCount.Value=parameters.repeat_batch_count;
            switch state.plan_state
                case "FROZEN"
                    if state.legal_actions.start_new_batch
                        app.StateLabel.Text="Frozen batch completed";
                    else
                        app.StateLabel.Text="Frozen run ready / resumable";
                    end
                    app.StateLabel.FontColor=[0 0.5 0];
                case "RUNNING"
                    app.StateLabel.Text="● Running frozen plan";
                    app.StateLabel.FontColor=[0 0.3 0.8];
                otherwise
                    app.StateLabel.Text="Editable — current settings run";
                    app.StateLabel.FontColor=[0 0.35 0.65];
            end
            % Enabled state is derived from the backend lifecycle, never the
            % other way round.
            app.setControlsLocked(state.plan_state=="RUNNING");
            app.StartNewBatchButton.Enable= ...
                matlab.lang.OnOffSwitchState(state.legal_actions.start_new_batch);
            app.ReturnToEditingButton.Enable= ...
                matlab.lang.OnOffSwitchState(state.legal_actions.return_to_editing);
            if state.active_run.frozen
                runnable=~state.legal_actions.start_new_batch && ...
                    state.plan_state~="RUNNING";
                app.RunNextButton.Enable=matlab.lang.OnOffSwitchState(runnable);
                app.RunAllButton.Enable=matlab.lang.OnOffSwitchState(runnable);
            end
            app.StopButton.Enable=matlab.lang.OnOffSwitchState( ...
                state.legal_actions.stop_after_current);
            app.StopButton.Text=ternary(state.stop_after_current_requested, ...
                'Stop requested','Stop after current');
        end

        function refreshModeVisibility(app,state)
            is1p=state.plan_parameters.stimulation_mode=="1p_dmd";
            set_visible(app.OnePhotonControls,is1p);
            set_visible(app.TwoPhotonControls,~is1p);
            if app.WidgetsLocked, return; end
            app.DmdErosion.Enable=matlab.lang.OnOffSwitchState(is1p);
            app.SpiralRadius.Enable=matlab.lang.OnOffSwitchState(~is1p);
            app.SpiralDensity.Enable=matlab.lang.OnOffSwitchState(~is1p);
        end

        function refreshTrialTable(app)
            trials=app.displayTrials();
            n=height(trials); data=cell(n,7);
            for k=1:n
                resolved=trials.pulse_schedule{k};
                data(k,:)={trials.trial_id(k),char(string(trials.target_cell_id(k))), ...
                    char(string(resolved.protocol_type)), ...
                    round(trials.acquisition_duration_s(k),3), ...
                    char(resolved_command_summary(resolved)), ...
                    char(string(trials.acquisition_status(k))), ...
                    char(string(trials.experiment_directory(k)))};
            end
            app.TrialTable.Data=data;
        end

        function trials=displayTrials(app)
            %DISPLAYTRIALS Trial rows the table shows for the active frozen run.
            trials=table;
            if isempty(app.Controller.ActiveRunPlan) || ...
                    strlength(app.Controller.ActiveRunFolder)==0
                return
            end
            lastRun=app.Controller.LastRun;
            frozen=app.Controller.ActiveRunPlan.manifest.trials;
            if ~isempty(lastRun) && isfield(lastRun,"trials") && ...
                    height(lastRun.trials)==height(frozen)
                trials=lastRun.trials;
                return
            end
            trials=app.Controller.currentBatchTrials();
        end

        function setControlsLocked(app,state)
            if state==app.WidgetsLocked, return; end
            app.WidgetsLocked=state;
            if state
                objects=findall(app.Figure,"-property","Enable");
                app.LockSnapshot=cell(numel(objects),2);
                for k=1:numel(objects)
                    app.LockSnapshot{k,1}=objects(k);
                    app.LockSnapshot{k,2}=objects(k).Enable;
                    objects(k).Enable="off";
                end
                app.StopButton.Enable="on";
                app.setRoiInteractions("none");
            else
                for k=1:size(app.LockSnapshot,1)
                    object=app.LockSnapshot{k,1};
                    if isvalid(object), object.Enable=app.LockSnapshot{k,2}; end
                end
                app.LockSnapshot={}; app.StopButton.Enable="off";
                app.setRoiInteractions("all");
            end
            drawnow;
        end

        function setRoiInteractions(app,mode)
            for k=1:numel(app.RoiObjects)
                if isvalid(app.RoiObjects{k}) && ...
                        isprop(app.RoiObjects{k},"InteractionsAllowed")
                    app.RoiObjects{k}.InteractionsAllowed=mode;
                end
            end
        end

        function requestStop(app)
            app.Controller.stopAfterCurrent();
        end

        function chooseResume(app)
            folder=uigetdir(app.Controller.defaultRunRoot(), ...
                "Select a frozen Adaptive Optopatch run");
            if ~isequal(folder,0), app.invoke(@()app.resumeRun(string(folder))); end
        end

        function chooseProtocol(app)
            [file,folder]=uigetfile({'*.mat','Pulse protocol MAT (*.mat)'}, ...
                "Select a validated pulse protocol",pwd);
            if isequal(file,0), return; end
            app.invoke(@()app.loadPulseProtocol(string(fullfile(folder,file))));
        end

        function invoke(app,operation)
            try
                operation();
            catch exception
                app.showError(exception);
            end
        end

        function chooseRampReview(app)
            protocol=app.Controller.Protocol;
            if isempty(protocol) || ...
                    string(protocol.protocol_type)~="single_cell_blue_ramp"
                error("adaptive_optopatch:RampProtocolRequired", ...
                    "Load the single-cell Blue ramp protocol used for the acquisition first.");
            end
            folder=uigetdir(app.Controller.defaultRunRoot(), ...
                "Select completed ramp acquisition");
            if isequal(folder,0), return; end
            saved=load(fullfile(folder,"output_data.mat"), ...
                "adaptive_optopatch_record");
            if ~isfield(saved,"adaptive_optopatch_record") || ...
                    ~isfield(saved.adaptive_optopatch_record,"pulse_schedule")
                error("adaptive_optopatch:ResolvedRampRecordRequired", ...
                    "The selected acquisition does not contain its resolved ramp schedule.");
            end
            adaptive_optopatch.RampReviewApp(string(folder), ...
                saved.adaptive_optopatch_record.pulse_schedule, ...
                app.Controller.currentFovState(), ...
                "DecisionAppliedFcn",@(state)app.acceptRampReview(state));
        end

        function acceptRampReview(app,state)
            app.Controller.applyCellState(state);
            app.setStatus(["Stored ramp calibration decision in the active FOV. " ...
                "Save the FOV to persist it."]);
        end
    end
end

function set_visible(controls,state)
for k=1:numel(controls), controls{k}.Visible=matlab.lang.OnOffSwitchState(state); end
end

function value=ternary(condition,yes,no)
if condition, value=yes; else, value=no; end
end

function summary=resolved_command_summary(resolved)
% What the operator will physically deliver, and where that value came
% from. command_voltage_source is the resolver's own provenance, so a
% command inherited from a per-cell calibration is visible before the run
% rather than only in the archive.
light=~resolved.events.is_null;
if ~any(light), summary="0 (null)"; return; end
values=unique(round(resolved.events.command_voltage_v(light),4),"stable");
sources=unique(resolved.events.command_voltage_source(light),"stable");
summary=strjoin(string(values),", ")+" ["+strjoin(sources,", ")+"]";
end
