classdef AdaptiveOptopatchApp < adaptive_optopatch.ReferencePreparationApp
    %ADAPTIVEOPTOPATCHAPP Unified editable-plan, validation, and run workflow.
    properties (SetAccess=private)
        PlanState string = "DIRTY"
        ActiveRunFolder string = ""
        ActiveRunPlan struct = struct([])
        LastRun struct = struct([])
        ControlsLocked logical = false
        PulseProtocol struct = struct([])
        PulseProtocolPath string = ""
        PulseProtocolSummary struct = struct([])
    end
    properties (Access=private)
        RunRoot string = ""
        UnifiedReady logical = false
        ValidatedPlan struct = struct([])
        StateLabel
        ProtocolPathField
        ProtocolSummaryArea
        LoadProtocolButton
        ObisOverride
        ObisPowerMw
        ArmOutput
        ReleaseLevel
        TrajectoryConfirmed
        MaximumVelocity
        MaximumAcceleration
        AllowCalibrationExtrapolation
        AllowCameraRateOverride
        TrialTable
        WaveformAxes
        RunNextButton
        RunAllButton
        StopButton
        StopRequested logical = false
        OnePhotonControls cell = {}
        TwoPhotonControls cell = {}
        LockSnapshot cell = {}
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
            app.RunRoot=options.RunRoot;
            app.buildUnifiedUI();
            app.UnifiedReady=true;
            app.markDirty();
        end

        function plan=buildCurrentPlan(app)
            if isempty(app.PulseProtocol)
                error("adaptive_optopatch:PulseProtocolRequired", ...
                    "Load a validated pulse_protocol.mat before previewing or running.");
            end
            protocol=adaptive_optopatch.normalize_protocol(app.PulseProtocol);
            compatibility=adaptive_optopatch.validate_protocol_for_mode( ...
                protocol,string(app.Mode.Value));
            if ~compatibility.passed
                error("adaptive_optopatch:ProtocolModeIncompatible", ...
                    "%s",strjoin(compatibility.issues,newline));
            end
            lightDurations=protocol.events.duration_s( ...
                protocol.events.amplitude_fraction>0);
            if isempty(lightDurations), representativePulseMs=5;
            else, representativePulseMs=1000*min(lightDurations); end
            [reference,targets]=app.buildSpatialArtifacts( ...
                "PulseDurationMs",representativePulseMs);
            manifest=adaptive_optopatch.build_manifest( ...
                reference,targets,protocol,"Mode",string(app.Mode.Value), ...
                "OutputPrefix",string(protocol.protocol_id));
            session=app.buildSessionState();
            legacyTimingFields=["screen_repeats","pulse_count","pulse_duration_ms", ...
                "dark_interval_min_ms","dark_interval_max_ms", ...
                "pre_delay_ms","post_delay_ms"];
            for field=legacyTimingFields
                if isfield(session.parameters,field)
                    session.parameters=rmfield(session.parameters,field);
                end
            end
            session.pulse_protocol_path=app.PulseProtocolPath;
            session.pulse_protocol_id=string(protocol.protocol_id);
            session.pulse_protocol_summary=app.PulseProtocolSummary;
            session.run_controls=app.captureRunControls();
            plan=struct("schema_version","0.1.0", ...
                "built_at",string(datetime("now","TimeZone","local")), ...
                "reference",reference,"targets",targets,"protocol",protocol, ...
                "manifest",manifest,"session",session);
        end

        function protocol=loadPulseProtocol(app,path)
            protocol=adaptive_optopatch.load_protocol(path);
            app.setPulseProtocol(protocol,path);
        end

        function setPulseProtocol(app,protocol,path)
            arguments
                app
                protocol (1,1) struct
                path (1,1) string = ""
            end
            report=adaptive_optopatch.validate_protocol(protocol);
            if ~report.passed
                error("adaptive_optopatch:InvalidProtocol", ...
                    "%s",strjoin(report.issues,newline));
            end
            app.PulseProtocol=report.protocol;
            app.PulseProtocolPath=path;
            app.PulseProtocolSummary= ...
                adaptive_optopatch.summarize_protocol(report.protocol);
            app.updateProtocolDisplay();
            app.markDirty();
            app.refreshTrialTable(table);
        end

        function report=validateCurrentPlan(app)
            plan=app.buildCurrentPlan();
            issues=strings(0,1);
            for k=1:height(plan.manifest.trials)
                preflight=adaptive_optopatch.preflight_trial( ...
                    plan.targets,plan.manifest.trials(k,:), ...
                    "RequireConfirmedLiveProtocol",false, ...
                    "LiveProtocolConfirmed",true);
                issues=[issues;preflight.issues(:)]; %#ok<AGROW>
            end
            mode=string(app.Mode.Value);
            if mode=="1p_dmd"
                if ~app.ArmOutput.Value
                    issues(end+1)="ARM live 488 output is not confirmed.";
                end
                if isempty(issues)
                    hardware=adaptive_optopatch.resolve_luminos_1p_hardware(app.LuminosApp);
                    adaptive_optopatch.build_luminos_1p_waveform_config( ...
                        hardware.daq.global_props,hardware.daq.wfm_data, ...
                        plan.manifest.trials.pulse_schedule{1}, ...
                        adaptive_optopatch.virtual_upright_1p_profile(), ...
                        "ModulatorVoltageOverride",app.ModulatorVoltage.Value);
                end
            else
                bundleReport=adaptive_optopatch.validate_2p_planning_bundle(plan.targets);
                issues=[issues;bundleReport.issues(:)];
                release=adaptive_optopatch.validate_2p_release_level( ...
                    plan.manifest,app.ReleaseLevel.Value, ...
                    "ConfirmTrajectoryTest",app.TrajectoryConfirmed.Value, ...
                    "ConfirmLiveOutput",app.ArmOutput.Value, ...
                    "ModulatorVoltageOverride",app.effectiveTwoPhotonVoltage());
                issues=[issues;release.issues(:)];
                if isempty(issues)
                    hardware=adaptive_optopatch.resolve_luminos_2p_hardware(app.LuminosApp);
                    targetIndex=find(~plan.manifest.trials.is_null,1);
                    row=plan.manifest.trials(targetIndex,:);
                    target=plan.targets.targets(row.target_index);
                    protocol=app.protocolWithEffectiveVoltage( ...
                        row.pulse_schedule{1},row.is_null);
                    adaptive_optopatch.build_2p_plan_preview( ...
                        protocol,target,hardware, ...
                        "ReleaseLevel",app.ReleaseLevel.Value, ...
                        "MaximumVelocityVPerS",app.MaximumVelocity.Value, ...
                        "MaximumAccelerationVPerS2",app.MaximumAcceleration.Value, ...
                        "AllowCalibrationExtrapolation", ...
                        app.AllowCalibrationExtrapolation.Value);
                end
            end
            issues=unique(issues(strlength(issues)>0),"stable");
            report=struct("schema_version","0.1.0","passed",isempty(issues), ...
                "validated_at",string(datetime("now","TimeZone","local")), ...
                "mode",mode,"issues",issues);
            if ~report.passed
                app.PlanState="DIRTY"; app.updateStateDisplay();
                error("adaptive_optopatch:UnifiedPlanValidationFailed", ...
                    "%s",strjoin(issues,newline));
            end
            app.ValidatedPlan=plan;
            app.PlanState="VALIDATED";
            app.updateStateDisplay();
            app.setStatus("Validation passed. The current experiment is ready to freeze and run.");
        end

        function plan=previewCurrentPlan(app)
            app.previewTargets();
            plan=app.buildCurrentPlan();
            cla(app.WaveformAxes);
            if string(app.Mode.Value)=="2p_spiral"
                hardware=adaptive_optopatch.resolve_luminos_2p_hardware(app.LuminosApp);
                row=plan.manifest.trials(find(~plan.manifest.trials.is_null,1),:);
                target=plan.targets.targets(row.target_index);
                protocol=app.protocolWithEffectiveVoltage( ...
                    row.pulse_schedule{1},row.is_null);
                preview=adaptive_optopatch.build_2p_plan_preview( ...
                    protocol,target,hardware, ...
                    "ReleaseLevel",app.ReleaseLevel.Value, ...
                    "MaximumVelocityVPerS",app.MaximumVelocity.Value, ...
                    "MaximumAccelerationVPerS2",app.MaximumAcceleration.Value, ...
                    "AllowCalibrationExtrapolation", ...
                    app.AllowCalibrationExtrapolation.Value);
                waveforms=preview.waveforms;
                time=(0:numel(waveforms.x_v)-1)'/waveforms.sample_rate_hz;
                step=max(1,ceil(numel(time)/50000)); index=1:step:numel(time);
                plot(app.WaveformAxes,time(index),waveforms.x_v(index), ...
                    time(index),waveforms.y_v(index), ...
                    time(index),waveforms.pockels_v(index));
                legend(app.WaveformAxes,["X","Y","Pockels"],"Location","best");
                xlabel(app.WaveformAxes,"Time (s)"); ylabel(app.WaveformAxes,"Command (V)");
            else
                pulses=adaptive_optopatch.flatten_pulse_schedule( ...
                    plan.protocol,"ConfiguredVoltage",app.ModulatorVoltage.Value);
                time=reshape([pulses.onset_s pulses.onset_s ...
                    pulses.offset_s pulses.offset_s]',[],1);
                command=reshape([zeros(height(pulses),1) pulses.modulator_voltage ...
                    pulses.modulator_voltage zeros(height(pulses),1)]',[],1);
                plot(app.WaveformAxes,time,command,"b-");
                xlabel(app.WaveformAxes,"Time (s)"); ylabel(app.WaveformAxes,"mod488 (V)");
                title(app.WaveformAxes,sprintf( ...
                    '%d DMD targets; %d realized light pulses', ...
                    size(plan.targets.dmd_camera_masks,3),height(pulses)));
            end
        end

        function paths=freezeCurrentPlan(app,outputRoot)
            arguments
                app
                outputRoot (1,1) string = ""
            end
            if app.PlanState~="VALIDATED" || isempty(app.ValidatedPlan)
                app.validateCurrentPlan();
            end
            if strlength(outputRoot)==0, outputRoot=app.defaultRunRoot(); end
            plan=app.ValidatedPlan;
            paths=adaptive_optopatch.save_bundle(outputRoot, ...
                plan.reference,plan.targets,plan.manifest, ...
                "CreateSubfolder",true, ...
                "SubfolderPrefix","adaptive_optopatch_run", ...
                "SessionState",plan.session);
            paths.protocol=fullfile(paths.output_directory,"pulse_protocol.mat");
            adaptive_optopatch.save_protocol(paths.protocol,plan.protocol);
            app.ActiveRunPlan=plan;
            app.ActiveRunFolder=paths.output_directory;
            app.refreshTrialTable(plan.manifest.trials);
            app.setStatus("Frozen run plan created before acquisition:"+newline+ ...
                app.ActiveRunFolder);
        end

        function run=runNext(app)
            run=app.executeCurrentPlan(1);
        end

        function run=runAll(app)
            run=app.executeCurrentPlan(0);
        end

        function plan=resumeRun(app,folder)
            arguments
                app
                folder (1,1) string
            end
            reference=load_required(folder,"reference_model.mat","reference");
            targets=load_required(folder,"pattern_bundle.mat","targets");
            manifest=load_required(folder,"trial_manifest.mat","manifest");
            session=load_required(folder,"planning_session.mat","planning_session");
            protocol=adaptive_optopatch.load_protocol( ...
                fullfile(folder,"pulse_protocol.mat"));
            plan=struct("schema_version","0.1.0","built_at","frozen", ...
                "reference",reference,"targets",targets,"protocol",protocol, ...
                "manifest",manifest,"session",session);
            app.ActiveRunPlan=plan;
            app.ActiveRunFolder=folder;
            app.ValidatedPlan=plan;
            app.PlanState="VALIDATED";
            app.updateStateDisplay();
            app.refreshTrialTable(manifest.trials);
            app.setStatus("Loaded frozen run for resume. Editable controls were not substituted into it.");
        end

        function setPlanParameter(app,name,value)
            name=lower(string(name));
            mapping=struct( ...
                "mode",app.Mode,"stimulation_mode",app.Mode, ...
                "microns_per_pixel",app.MicronsPerPixel, ...
                "spiral_radius_um",app.SpiralRadius, ...
                "spiral_density_points_per_volt",app.SpiralDensity, ...
                "dmd_erosion_pixels",app.DmdErosion, ...
                "modulator_voltage",app.ModulatorVoltage, ...
                "release_level",app.ReleaseLevel,"maximum_velocity",app.MaximumVelocity, ...
                "maximum_acceleration",app.MaximumAcceleration, ...
                "arm_output",app.ArmOutput,"trajectory_confirmed",app.TrajectoryConfirmed, ...
                "obis_override",app.ObisOverride,"obis_power_mw",app.ObisPowerMw, ...
                "allow_calibration_extrapolation",app.AllowCalibrationExtrapolation, ...
                "allow_camera_rate_override",app.AllowCameraRateOverride);
            key=char(name);
            if ~isfield(mapping,key)
                error("adaptive_optopatch:UnknownPlanParameter", ...
                    "Unknown editable plan parameter: %s",name);
            end
            mapping.(key).Value=value;
            if ismember(name,["mode","stimulation_mode"]), app.modeChanged();
            else, app.markDirty(); end
        end

        function setReferenceData(app,image,info,roiPositions)
            arguments
                app
                image (:,:) {mustBeNumeric}
                info (1,1) struct
                roiPositions cell = {}
            end
            app.ReferenceImage=image;
            app.LoadInfo=info;
            imagesc(app.Axes,image); axis(app.Axes,"image"); app.Axes.YDir="reverse";
            colormap(app.Axes,"gray"); app.applyContrast();
            app.restorePolygons(roiPositions);
            app.markDirty();
        end
    end

    methods (Access=protected)
        function planChanged(app)
            if app.UnifiedReady && app.PlanState~="RUNNING", app.markDirty(); end
        end

        function planningSessionRestored(app,session)
            if ~isfield(session,"pulse_protocol_path") || ...
                    strlength(string(session.pulse_protocol_path))==0
                return
            end
            path=string(session.pulse_protocol_path);
            if isfile(path)
                app.loadPulseProtocol(path);
            else
                app.PulseProtocol=struct([]);
                app.PulseProtocolPath=path;
                app.PulseProtocolSummary=struct([]);
                app.updateProtocolDisplay();
                app.setStatus("Protocol file not found — select a pulse protocol."+ ...
                    newline+path);
            end
        end

        function savePlanningBundle(app)
            try
                plan=app.buildCurrentPlan();
                paths=adaptive_optopatch.save_bundle( ...
                    app.LoadInfo.snapshot_directory,plan.reference,plan.targets, ...
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
            root.RowHeight={"1x",36,250,165,70};
            if ~simulation, root.RowHeight={"1x",0,250,165,70}; end
            banner=uilabel(root,"Text","SIMULATION — NO HARDWARE OUTPUT", ...
                "HorizontalAlignment","center","FontWeight","bold", ...
                "FontSize",16,"FontColor",[1 1 1], ...
                "BackgroundColor",[0.75 0.05 0.05], ...
                "Visible",matlab.lang.OnOffSwitchState(simulation));
            banner.Layout.Row=2; banner.Layout.Column=[1 3];
            app.Status.Layout.Row=5; app.Status.Layout.Column=[1 3];
            legacySave=findall(app.Figure,"Text","Save planning bundle…");
            if ~isempty(legacySave)
                legacySave.Text="Save plan…"; legacySave.FontWeight="normal";
                legacySave.Tooltip="Optional: save the editable plan without running.";
            end

            planningControls=app.Mode.Parent;
            heights=planningControls.RowHeight;
            heights(:)=repmat({24},size(heights));
            heights(10:16)=repmat({0},1,7);
            planningControls.RowHeight=heights;
            planningControls.RowSpacing=3;
            planningControls.Padding=[4 4 4 4];
            hiddenControls={app.Repeats,app.PulseCount,app.PulseDuration, ...
                app.DarkIntervalMin,app.DarkIntervalMax,app.PreDelay.Parent};
            for k=1:numel(hiddenControls), hiddenControls{k}.Visible="off"; end
            hiddenLabels=["Screen repeats","Pulses / neuron","Pulse duration (ms)", ...
                "Dark gap min (ms)","Dark gap max (ms)","Pulse command (V)", ...
                "Pre / post delay (ms)"];
            for label=hiddenLabels
                object=findall(app.Figure,"Text",label);
                if ~isempty(object), object.Visible="off"; end
            end

            runtime=uigridlayout(root,[1 2]);
            runtime.Layout.Row=3; runtime.Layout.Column=[1 3];
            runtime.ColumnWidth={920,"1x"}; runtime.Padding=[4 4 4 4];
            controls=uigridlayout(runtime,[5 8]);
            controls.RowHeight={30,45,30,30,38};
            controls.ColumnWidth={105,90,115,100,105,100,115,"1x"};
            app.StateLabel=uilabel(controls,"Text","● Modified — validation required", ...
                "FontWeight","bold","FontColor",[0.75 0.25 0]);
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
            app.ArmOutput=uicheckbox(controls,"Text","ARM live output", ...
                "FontWeight","bold");
            app.ArmOutput.Layout.Row=3; app.ArmOutput.Layout.Column=[7 8];

            app.ObisOverride=uicheckbox(controls,"Text","Override OBIS");
            app.ObisOverride.Layout.Row=3; app.ObisOverride.Layout.Column=1;
            app.ObisPowerMw=uieditfield(controls,"numeric","Value",10,"Limits",[0 55]);
            app.ObisPowerMw.Layout.Row=3; app.ObisPowerMw.Layout.Column=2;
            commandLabel=uilabel(controls,"Text","mod488 / Pockels (V)", ...
                "HorizontalAlignment","right");
            commandLabel.Layout.Row=3; commandLabel.Layout.Column=3;
            commandGrid=uigridlayout(controls,[1 1]); commandGrid.Padding=0;
            commandGrid.Layout.Row=3; commandGrid.Layout.Column=4;
            app.ModulatorVoltage.Parent=commandGrid;
            releaseLabel=uilabel(controls,"Text","Release level");
            releaseLabel.Layout.Row=3; releaseLabel.Layout.Column=5;
            app.ReleaseLevel=uidropdown(controls,"Items", ...
                ["blocked_test","attenuated_test","pilot_single","pilot_mixed_trains"], ...
                "Value","blocked_test");
            app.ReleaseLevel.Layout.Row=3; app.ReleaseLevel.Layout.Column=6;
            app.TrajectoryConfirmed=uicheckbox(controls,"Text","Trajectory reviewed");
            app.TrajectoryConfirmed.Layout.Row=4; app.TrajectoryConfirmed.Layout.Column=[7 8];

            velocityLabel=uilabel(controls,"Text","Max velocity");
            velocityLabel.Layout.Row=4; velocityLabel.Layout.Column=1;
            app.MaximumVelocity=uieditfield(controls,"numeric","Value",1000,"Limits",[eps Inf]);
            app.MaximumVelocity.Layout.Row=4; app.MaximumVelocity.Layout.Column=2;
            accelerationLabel=uilabel(controls,"Text","Max acceleration");
            accelerationLabel.Layout.Row=4; accelerationLabel.Layout.Column=3;
            app.MaximumAcceleration=uieditfield(controls,"numeric","Value",6e6,"Limits",[eps Inf]);
            app.MaximumAcceleration.Layout.Row=4; app.MaximumAcceleration.Layout.Column=4;
            app.AllowCalibrationExtrapolation=uicheckbox(controls,"Text","Allow cal extrapolation");
            app.AllowCalibrationExtrapolation.Layout.Row=4; app.AllowCalibrationExtrapolation.Layout.Column=5;
            app.AllowCameraRateOverride=uicheckbox(controls,"Text","Camera-rate override");
            app.AllowCameraRateOverride.Layout.Row=4; app.AllowCameraRateOverride.Layout.Column=6;

            previewButton=uibutton(controls,"Text","Preview", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.previewCurrentPlan()));
            previewButton.Layout.Row=5; previewButton.Layout.Column=1;
            validateButton=uibutton(controls,"Text","Validate", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.validateCurrentPlan()));
            validateButton.Layout.Row=5; validateButton.Layout.Column=2;
            app.RunNextButton=uibutton(controls,"Text","Run next", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.runNext()));
            app.RunNextButton.Layout.Row=5; app.RunNextButton.Layout.Column=3;
            app.RunAllButton=uibutton(controls,"Text","Run all", ...
                "FontWeight","bold","ButtonPushedFcn",@(~,~)app.invoke(@()app.runAll()));
            app.RunAllButton.Layout.Row=5; app.RunAllButton.Layout.Column=4;
            app.StopButton=uibutton(controls,"Text","Stop after current", ...
                "Enable","off","ButtonPushedFcn",@(~,~)app.requestStop());
            app.StopButton.Layout.Row=5; app.StopButton.Layout.Column=[5 6];
            resumeButton=uibutton(controls,"Text","Resume run…", ...
                "ButtonPushedFcn",@(~,~)app.chooseResume());
            resumeButton.Layout.Row=5; resumeButton.Layout.Column=[7 8];
            app.WaveformAxes=uiaxes(runtime);
            title(app.WaveformAxes,"Waveform / DMD preview");

            app.TrialTable=uitable(root,"ColumnName", ...
                {'Trial','Cell','Protocol','Duration','Status','Output'});
            app.TrialTable.Layout.Row=4; app.TrialTable.Layout.Column=[1 3];
            app.OnePhotonControls={app.ObisOverride,app.ObisPowerMw};
            app.TwoPhotonControls={app.ReleaseLevel,app.TrajectoryConfirmed, ...
                app.MaximumVelocity,app.MaximumAcceleration, ...
                app.AllowCalibrationExtrapolation,app.AllowCameraRateOverride};
            watched=[app.OnePhotonControls app.TwoPhotonControls ...
                {app.ModulatorVoltage,app.ArmOutput}];
            for k=1:numel(watched)
                watched{k}.ValueChangedFcn=@(~,~)app.markDirty();
            end
            app.Mode.ValueChangedFcn=@(~,~)app.modeChanged();
            app.modeChanged();
        end

        function modeChanged(app)
            is1p=string(app.Mode.Value)=="1p_dmd";
            set_enable(app.OnePhotonControls,is1p);
            set_enable(app.TwoPhotonControls,~is1p);
            app.DmdErosion.Enable=matlab.lang.OnOffSwitchState(is1p);
            app.SpiralRadius.Enable=matlab.lang.OnOffSwitchState(~is1p);
            app.SpiralDensity.Enable=matlab.lang.OnOffSwitchState(~is1p);
            if isa(app.LuminosApp,"adaptive_optopatch.testing.SimulatedLuminosApp")
                app.ArmOutput.Text=ternary_local(is1p, ...
                    "ARM simulated 488 output","ARM simulated 2P output");
            else
                app.ArmOutput.Text=ternary_local(is1p, ...
                    "ARM live 488 output","ARM live 2P output");
            end
            app.markDirty();
        end

        function markDirty(app)
            if app.PlanState=="RUNNING", return; end
            app.PlanState="DIRTY";
            app.ValidatedPlan=struct([]);
            app.ActiveRunPlan=struct([]);
            app.ActiveRunFolder="";
            app.updateStateDisplay();
        end

        function updateStateDisplay(app)
            if isempty(app.StateLabel) || ~isvalid(app.StateLabel), return; end
            switch app.PlanState
                case "VALIDATED"
                    app.StateLabel.Text="✓ Ready to run"; app.StateLabel.FontColor=[0 0.5 0];
                case "RUNNING"
                    app.StateLabel.Text="● Running frozen plan"; app.StateLabel.FontColor=[0 0.3 0.8];
                otherwise
                    app.StateLabel.Text="● Modified — validation required";
                    app.StateLabel.FontColor=[0.75 0.25 0];
            end
        end

        function run=executeCurrentPlan(app,count)
            if app.PlanState=="DIRTY" || isempty(app.ValidatedPlan)
                app.validateCurrentPlan();
            end
            if isempty(app.ActiveRunPlan) || strlength(app.ActiveRunFolder)==0
                app.freezeCurrentPlan();
            end
            plan=app.ActiveRunPlan;
            app.PlanState="RUNNING"; app.StopRequested=false;
            app.setControlsLocked(true); app.updateStateDisplay();
            cleanup=onCleanup(@()app.finishRunning());
            simulation=isa(app.LuminosApp, ...
                "adaptive_optopatch.testing.SimulatedLuminosApp");
            outputRoot="";
            if simulation, outputRoot=fullfile(app.ActiveRunFolder,"simulation_runs"); end
            mode=unique(string(plan.manifest.trials.stimulation_mode));
            frozenControls=app.frozenRunControls(plan);
            if isequal(mode,"1p_dmd")
                run=adaptive_optopatch.run_1p_manifest( ...
                    plan.manifest,plan.targets,app.LuminosApp, ...
                    "OutputDirectory",app.ActiveRunFolder,"OutputRoot",outputRoot, ...
                    "Resume",true,"StopAfterTrial",count, ...
                    "ConfirmLiveOutput",app.ArmOutput.Value, ...
                    "LaserPowerW",frozenControls.laser_power_w, ...
                    "ModulatorVoltageOverride",frozenControls.modulator_voltage_override, ...
                    "StopRequestedFcn",@()app.StopRequested);
            else
                run=adaptive_optopatch.run_2p_manifest( ...
                    plan.manifest,plan.targets,app.LuminosApp, ...
                    "ReleaseLevel",frozenControls.release_level, ...
                    "OutputDirectory",app.ActiveRunFolder,"OutputRoot",outputRoot, ...
                    "Resume",true,"ConfirmTrajectoryTest",app.TrajectoryConfirmed.Value, ...
                    "ConfirmLiveOutput",app.ArmOutput.Value, ...
                    "ModulatorVoltageOverride",frozenControls.two_photon_voltage, ...
                    "MaximumVelocityVPerS",frozenControls.maximum_velocity_v_per_s, ...
                    "MaximumAccelerationVPerS2",frozenControls.maximum_acceleration_v_per_s2, ...
                    "AllowCalibrationExtrapolation",frozenControls.allow_calibration_extrapolation, ...
                    "AllowCameraRateOverride",frozenControls.allow_camera_rate_override);
            end
            app.LastRun=run;
            app.refreshTrialTable(run.trials);
            app.setStatus("Run stopped normally. Frozen plan: "+app.ActiveRunFolder);
        end

        function finishRunning(app)
            app.setControlsLocked(false);
            if app.PlanState=="RUNNING", app.PlanState="VALIDATED"; end
            app.updateStateDisplay();
        end

        function setControlsLocked(app,state)
            app.ControlsLocked=state;
            if state
                objects=findall(app.Figure,"-property","Enable");
                app.LockSnapshot=cell(numel(objects),2);
                for k=1:numel(objects)
                    app.LockSnapshot{k,1}=objects(k);
                    app.LockSnapshot{k,2}=objects(k).Enable;
                    objects(k).Enable="off";
                end
                app.StopButton.Enable="on";
                for k=1:numel(app.RoiObjects)
                    if isvalid(app.RoiObjects{k}) && isprop(app.RoiObjects{k},"InteractionsAllowed")
                        app.RoiObjects{k}.InteractionsAllowed="none";
                    end
                end
            else
                for k=1:size(app.LockSnapshot,1)
                    object=app.LockSnapshot{k,1};
                    if isvalid(object), object.Enable=app.LockSnapshot{k,2}; end
                end
                app.LockSnapshot={}; app.StopButton.Enable="off";
                for k=1:numel(app.RoiObjects)
                    if isvalid(app.RoiObjects{k}) && isprop(app.RoiObjects{k},"InteractionsAllowed")
                        app.RoiObjects{k}.InteractionsAllowed="all";
                    end
                end
                app.modeChangedWithoutDirty();
            end
            drawnow;
        end

        function modeChangedWithoutDirty(app)
            is1p=string(app.Mode.Value)=="1p_dmd";
            set_enable(app.OnePhotonControls,is1p);
            set_enable(app.TwoPhotonControls,~is1p);
        end

        function requestStop(app)
            app.StopRequested=true; app.StopButton.Enable="off";
            app.StopButton.Text="Stop requested";
        end

        function chooseResume(app)
            folder=uigetdir(app.defaultRunRoot(),"Select a frozen Adaptive Optopatch run");
            if ~isequal(folder,0), app.invoke(@()app.resumeRun(string(folder))); end
        end

        function chooseProtocol(app)
            [file,folder]=uigetfile({"*.mat","Pulse protocol MAT (*.mat)"}, ...
                "Select a validated pulse protocol",pwd);
            if isequal(file,0), return; end
            app.invoke(@()app.loadPulseProtocol(string(fullfile(folder,file))));
        end

        function updateProtocolDisplay(app)
            if isempty(app.ProtocolPathField) || ~isvalid(app.ProtocolPathField), return; end
            if isempty(app.PulseProtocol)
                if strlength(app.PulseProtocolPath)>0
                    app.ProtocolPathField.Value=char(app.PulseProtocolPath);
                    app.ProtocolSummaryArea.Value="Protocol file not found — select a pulse protocol.";
                else
                    app.ProtocolPathField.Value="No pulse protocol loaded";
                    app.ProtocolSummaryArea.Value= ...
                        "Load a validated pulse_protocol.mat generated by MATLAB.";
                end
                return
            end
            if strlength(app.PulseProtocolPath)>0
                app.ProtocolPathField.Value=char(app.PulseProtocolPath);
            else
                app.ProtocolPathField.Value="In-memory validated protocol";
            end
            s=app.PulseProtocolSummary;
            app.ProtocolSummaryArea.Value=sprintf( ...
                '%s — %s | %d events (%d light), %d conditions | %.3g–%.3g ms | %.3f s total | seed %g', ...
                s.protocol_id,s.protocol_type,s.event_count,s.light_event_count, ...
                s.condition_count,1000*s.duration_range_s(1), ...
                1000*s.duration_range_s(2),s.acquisition_duration_s,s.random_seed);
        end

        function invoke(app,operation)
            try
                operation();
            catch exception
                app.showError(exception);
            end
        end

        function refreshTrialTable(app,trials)
            n=height(trials); data=cell(n,6);
            for k=1:n
                protocol=string(trials.pulse_schedule{k}.protocol_type);
                data(k,:)={trials.trial_id(k),char(string(trials.target_cell_id(k))), ...
                    char(protocol),round(trials.acquisition_duration_s(k),3), ...
                    char(string(trials.acquisition_status(k))), ...
                    char(string(trials.experiment_directory(k)))};
            end
            app.TrialTable.Data=data;
        end

        function root=defaultRunRoot(app)
            root=app.RunRoot;
            if strlength(root)==0 && isfield(app.LoadInfo,"snapshot_directory")
                root=string(app.LoadInfo.snapshot_directory);
            end
            if strlength(root)==0, root=string(pwd); end
        end

        function value=effectiveTwoPhotonVoltage(app)
            value=app.ModulatorVoltage.Value;
            if string(app.ReleaseLevel.Value)=="blocked_test", value=0; end
        end

        function protocol=protocolWithEffectiveVoltage(app,protocol,isNull)
            voltage=app.effectiveTwoPhotonVoltage();
            if isNull, voltage=0; end
            protocol=adaptive_optopatch.normalize_protocol(protocol);
            protocol.hardware_command_voltage=voltage;
        end

        function value=captureRunControls(app)
            value=struct("obis_override",app.ObisOverride.Value, ...
                "obis_power_mw",app.ObisPowerMw.Value, ...
                "arm_output",app.ArmOutput.Value, ...
                "release_level",string(app.ReleaseLevel.Value), ...
                "trajectory_confirmed",app.TrajectoryConfirmed.Value, ...
                "maximum_velocity_v_per_s",app.MaximumVelocity.Value, ...
                "maximum_acceleration_v_per_s2",app.MaximumAcceleration.Value, ...
                "allow_calibration_extrapolation",app.AllowCalibrationExtrapolation.Value, ...
                "allow_camera_rate_override",app.AllowCameraRateOverride.Value);
        end

        function controls=frozenRunControls(~,plan)
            saved=plan.session.run_controls;
            controls=struct;
            if saved.obis_override, controls.laser_power_w=saved.obis_power_mw/1000;
            else, controls.laser_power_w=NaN; end
            controls.modulator_voltage_override= ...
                plan.session.parameters.modulator_voltage;
            controls.release_level=string(saved.release_level);
            controls.two_photon_voltage=plan.session.parameters.modulator_voltage;
            if controls.release_level=="blocked_test", controls.two_photon_voltage=0; end
            controls.maximum_velocity_v_per_s=saved.maximum_velocity_v_per_s;
            controls.maximum_acceleration_v_per_s2=saved.maximum_acceleration_v_per_s2;
            controls.allow_calibration_extrapolation=saved.allow_calibration_extrapolation;
            controls.allow_camera_rate_override=saved.allow_camera_rate_override;
        end
    end
end

function set_enable(controls,state)
for k=1:numel(controls), controls{k}.Enable=matlab.lang.OnOffSwitchState(state); end
end

function value=ternary_local(condition,yes,no)
if condition, value=yes; else, value=no; end
end

function value=load_required(folder,filename,variable)
path=fullfile(folder,filename);
if ~isfile(path)
    error("adaptive_optopatch:IncompleteFrozenRun", ...
        "Frozen run is missing %s.",filename);
end
saved=load(path,variable);
if ~isfield(saved,variable)
    error("adaptive_optopatch:IncompleteFrozenRun", ...
        "%s does not contain %s.",filename,variable);
end
value=saved.(variable);
end
