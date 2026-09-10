classdef AdaptiveOptopatchApp < adaptive_optopatch.ReferencePreparationApp
    %ADAPTIVEOPTOPATCHAPP Unified editable-plan and run workflow.
    properties (SetAccess=private)
        PlanState string = "EDITABLE"
        ActiveRunFolder string = ""
        ActiveRunPlan struct = struct([])
        LastRun struct = struct([])
        ControlsLocked logical = false
        PulseProtocol struct = struct([])
        PulseProtocolPath string = ""
        PulseProtocolSummary struct = struct([])
        EditableStateChanged logical = true
    end
    properties (Access=private)
        RunRoot string = ""
        UnifiedReady logical = false
        StateLabel
        ProtocolPathField
        ProtocolSummaryArea
        LoadProtocolButton
        CommandVoltageLabel
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
            app.planChanged();
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
            lightDurations=[];
            for acquisition=protocol.acquisitions
                selected=~acquisition.events.is_null & ...
                    isfinite(acquisition.events.duration_s);
                lightDurations=[lightDurations; ...
                    acquisition.events.duration_s(selected)]; %#ok<AGROW>
            end
            if isempty(lightDurations), representativePulseMs=5;
            else, representativePulseMs=1000*min(lightDurations); end
            [~,targets]=app.buildSpatialArtifacts( ...
                "PulseDurationMs",representativePulseMs);
            fovState=app.currentFovState();
            reference=fovState.reference;
            guiDefaults=struct("command_voltage_v",app.ModulatorVoltage.Value, ...
                "pulse_duration_s",representativePulseMs/1000, ...
                "blue_mask_adjustment_pixels",app.DmdErosion.Value, ...
                "orange_expansion_pixels",app.OrangeExpansion.Value, ...
                "spiral_radius_um",app.SpiralRadius.Value, ...
                "spiral_density_points_per_volt",app.SpiralDensity.Value);
            [manifest,resolvedProtocols]=adaptive_optopatch.build_manifest( ...
                reference,targets,protocol,"Mode",string(app.Mode.Value), ...
                "OutputPrefix",string(protocol.protocol_id), ...
                "CurrentObisPowerW",app.plannedObisPowerW(), ...
                "FovState",fovState,"GuiDefaults",guiDefaults);
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
            plan=struct("schema_version","1.0.0", ...
                "built_at",string(datetime("now","TimeZone","local")), ...
                "software",adaptive_optopatch.software_provenance(), ...
                "reference",reference,"targets",targets,"fov_state",fovState, ...
                "protocol_definition",protocol,"protocol",protocol, ...
                "resolved_protocols",{resolvedProtocols}, ...
                "manifest",manifest,"session",session, ...
                "advisories",manifest.advisories);
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
            app.planChanged();
            app.refreshTrialTable(table);
        end

        function report=validateCurrentPlan(app)
            plan=app.buildCurrentPlan();
            report=app.preflightPlan(plan);
            app.showPreflightStatus(report,plan.advisories);
        end

        function report=preflightCurrentPlan(app)
            plan=app.buildCurrentPlan();
            report=app.preflightPlan(plan);
        end

        function report=preflightPlan(app,plan)
            issues=strings(0,1);
            for k=1:height(plan.manifest.trials)
                preflight=adaptive_optopatch.preflight_trial( ...
                    plan.targets,plan.manifest.trials(k,:), ...
                    "RequireConfirmedLiveProtocol",false, ...
                    "LiveProtocolConfirmed",true, ...
                    "Advisories",plan.manifest.advisories);
                issues=[issues;preflight.issues(:)]; %#ok<AGROW>
            end
            mode=string(app.Mode.Value);
            if mode=="1p_dmd"
                if isempty(issues)
                    hardware=adaptive_optopatch.resolve_luminos_1p_hardware(app.LuminosApp);
                    adaptive_optopatch.validate_camera_geometry( ...
                        hardware.voltage_camera,plan.targets);
                    for rowIndex=1:height(plan.manifest.trials)
                        resolved=plan.manifest.trials.pulse_schedule{rowIndex};
                        sequencePlan=struct([]);
                        pulseTargets=unique(resolved.events.target_cell_id( ...
                            ~resolved.events.is_null));
                        maskVaries=any(resolved.events.blue_mask_adjustment_pixels~= ...
                            plan.targets.parameters.blue_mask_adjustment_pixels);
                        if numel(pulseTargets)>1 || maskVaries
                            sequencePlan=adaptive_optopatch.build_dmd_sequence_plan( ...
                                resolved,plan.targets);
                        end
                        [globalProps,~]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                            hardware.daq.global_props,hardware.daq.wfm_data, ...
                            resolved,adaptive_optopatch.virtual_upright_1p_profile(), ...
                            "DmdSequencePlan",sequencePlan);
                        preflight_camera_frames(hardware.cameras,globalProps.total_time,false);
                    end
                end
            else
                bundleReport=adaptive_optopatch.validate_2p_planning_bundle(plan.targets);
                issues=[issues;bundleReport.issues(:)];
                if isempty(issues)
                    hardware=adaptive_optopatch.resolve_luminos_2p_hardware( ...
                        app.LuminosApp,"ApplyCalibration",false);
                    adaptive_optopatch.validate_camera_geometry( ...
                        hardware.voltage_camera,plan.targets);
                    rows=find(~plan.manifest.trials.is_null);
                    for rowIndex=reshape(rows,1,[])
                        row=plan.manifest.trials(rowIndex,:);
                        target=adaptive_optopatch.resolve_trial_target(plan.targets,row);
                        protocol=app.protocolWithEffectiveVoltage( ...
                            row.pulse_schedule{1},row.is_null);
                        preview=adaptive_optopatch.build_2p_plan_preview( ...
                            protocol,target,hardware, ...
                            "ReleaseLevel","standard", ...
                            "MaximumVelocityVPerS",app.MaximumVelocity.Value, ...
                            "MaximumAccelerationVPerS2",app.MaximumAcceleration.Value, ...
                            "AllowCalibrationExtrapolation", ...
                            app.AllowCalibrationExtrapolation.Value, ...
                            "TargetingTransform",plan_targeting_transform(plan));
                        [globalProps,~,~]= ...
                            adaptive_optopatch.build_luminos_2p_waveform_config( ...
                            hardware.daq.global_props,hardware.daq.wfm_data, ...
                            preview.waveforms);
                        preflight_camera_frames(hardware.cameras, ...
                            globalProps.total_time,app.AllowCameraRateOverride.Value);
                    end
                end
            end
            issues=unique(issues(strlength(issues)>0),"stable");
            report=struct("schema_version","0.1.0","passed",isempty(issues), ...
                "validated_at",string(datetime("now","TimeZone","local")), ...
                "mode",mode,"issues",issues);
            if ~report.passed
                error("adaptive_optopatch:UnifiedPlanValidationFailed", ...
                    "%s",strjoin(issues,newline));
            end
        end

        function showPreflightStatus(app,report,advisories)
            if ~report.passed, return; end
            if isempty(advisories)
                app.setStatus("Configuration check passed. Runs will rebuild and freeze current settings.");
            else
                messages=reshape(string({advisories.message}),[],1);
                app.setStatus(["Configuration check passed with nonblocking advisories:";messages]);
            end
        end

        function plan=previewCurrentPlan(app)
            app.previewTargets();
            plan=app.buildCurrentPlan();
            cla(app.WaveformAxes);
            if string(app.Mode.Value)=="2p_spiral"
                yyaxis(app.WaveformAxes,"left");
                hardware=adaptive_optopatch.resolve_luminos_2p_hardware( ...
                    app.LuminosApp,"ApplyCalibration",false);
                row=plan.manifest.trials(find(~plan.manifest.trials.is_null,1),:);
                target=adaptive_optopatch.resolve_trial_target(plan.targets,row);
                protocol=app.protocolWithEffectiveVoltage( ...
                    row.pulse_schedule{1},row.is_null);
                preview=adaptive_optopatch.build_2p_plan_preview( ...
                    protocol,target,hardware, ...
                    "ReleaseLevel","standard", ...
                    "MaximumVelocityVPerS",app.MaximumVelocity.Value, ...
                    "MaximumAccelerationVPerS2",app.MaximumAcceleration.Value, ...
                    "AllowCalibrationExtrapolation", ...
                    app.AllowCalibrationExtrapolation.Value, ...
                    "TargetingTransform",plan_targeting_transform(plan));
                waveforms=preview.waveforms;
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
            plan=app.buildCurrentPlan();
            app.preflightPlan(plan);
            if strlength(outputRoot)==0, outputRoot=app.defaultRunRoot(); end
            paths=adaptive_optopatch.save_bundle(outputRoot, ...
                plan.reference,plan.targets,plan.manifest, ...
                "CreateSubfolder",true, ...
                "SubfolderPrefix","adaptive_optopatch_run", ...
                "SessionState",plan.session,"FovState",plan.fov_state);
            paths.protocol=fullfile(paths.output_directory,"pulse_protocol.mat");
            save_frozen_protocol_archive(paths.protocol,plan.resolved_protocols, ...
                plan.manifest.trials.trial_id);
            paths.protocol_definition=fullfile(paths.output_directory, ...
                "protocol_definition.mat");
            adaptive_optopatch.save_protocol(paths.protocol_definition, ...
                plan.protocol_definition);
            app.ActiveRunPlan=plan;
            app.ActiveRunFolder=paths.output_directory;
            app.EditableStateChanged=false;
            app.PlanState="FROZEN";
            app.updateStateDisplay();
            app.refreshTrialTable(plan.manifest.trials);
            app.setStatus("Frozen run plan created before acquisition:"+newline+ ...
                app.ActiveRunFolder);
        end

        function paths=startNewRun(app,outputRoot)
            %STARTNEWRUN Freeze current editable state as the active run.
            %   Editable changes never replace an active frozen run on their
            %   own, so this is the operator's explicit way to finish with
            %   one run and begin another. The previous run's frozen
            %   artifacts stay on disk and remain resumable.
            arguments
                app
                outputRoot (1,1) string = ""
            end
            previousFolder=app.ActiveRunFolder;
            paths=app.freezeCurrentPlan(outputRoot);
            if strlength(previousFolder)>0
                app.setStatus(["Froze a new run and made it active:"; ...
                    app.ActiveRunFolder; ...
                    "The previous run remains on disk and can be continued "+ ...
                    "with Resume run…:";previousFolder]);
            end
        end

        function value=commandVoltageEnabled(app)
            %COMMANDVOLTAGEENABLED Whether the mod488 default is in use.
            %   Off in 2P mode: the Pockels command is protocol-owned.
            value=app.ModulatorVoltage.Enable;
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
            [~,resolvedProtocols]=load_frozen_protocol_archive( ...
                fullfile(folder,"pulse_protocol.mat"));
            definition=adaptive_optopatch.load_protocol( ...
                fullfile(folder,"protocol_definition.mat"));
            fovState=load_required(folder,"fov_state.mat","fov_state");
            plan=struct("schema_version","1.0.0","built_at","frozen", ...
                "reference",reference,"targets",targets, ...
                "protocol_definition",definition,"protocol",definition, ...
                "resolved_protocols",{resolvedProtocols}, ...
                "fov_state",fovState,"manifest",manifest,"session",session, ...
                "advisories",manifest_advisories(manifest));
            app.ActiveRunPlan=plan;
            app.ActiveRunFolder=folder;
            app.EditableStateChanged=false;
            app.PlanState="FROZEN";
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
                "orange_expansion_pixels",app.OrangeExpansion, ...
                "blue_mask_adjustment_pixels",app.DmdErosion, ...
                "dmd_erosion_pixels",app.DmdErosion, ...
                "modulator_voltage",app.ModulatorVoltage, ...
                "maximum_velocity",app.MaximumVelocity, ...
                "maximum_acceleration",app.MaximumAcceleration, ...
                "allow_calibration_extrapolation",app.AllowCalibrationExtrapolation, ...
                "allow_camera_rate_override",app.AllowCameraRateOverride);
            key=char(name);
            if ~isfield(mapping,key)
                error("adaptive_optopatch:UnknownPlanParameter", ...
                    "Unknown editable plan parameter: %s",name);
            end
            mapping.(key).Value=value;
            if ismember(name,["mode","stimulation_mode"]), app.modeChanged();
            else, app.planChanged(); end
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
            app.CurrentFovState=struct([]);
            app.CellIds=strings(0,1);
            app.NextCellIndex=1;
            imagesc(app.Axes,image); axis(app.Axes,"image"); app.Axes.YDir="reverse";
            colormap(app.Axes,"gray"); app.applyContrast();
            app.restorePolygons(roiPositions);
            app.planChanged();
        end
    end

    methods (Access=protected)
        function protocols=previewResolvedProtocols(app,~)
            % The unified app resolves an explicit protocol, so its target
            % preview shows the resolved per-event Blue adjustments, the
            % resolved Orange expansion, and the resolved 2P spiral geometry
            % rather than the bundle's default values.
            protocols={};
            if isempty(app.PulseProtocol), return; end
            protocols=app.buildCurrentPlan().resolved_protocols;
        end

        function value=showPlanningBundleControl(~)
            value=false;
        end

        function value=restorePlanningBundleOnSnapshotLoad(~)
            value=false;
        end

        function value=currentPulseDurationMs(app)
            value=5;
            if isempty(app.PulseProtocol), return; end
            protocol=adaptive_optopatch.normalize_protocol(app.PulseProtocol);
            durations=[];
            for acquisition=protocol.acquisitions
                selected=~acquisition.events.is_null & ...
                    isfinite(acquisition.events.duration_s);
                durations=[durations;acquisition.events.duration_s(selected)]; %#ok<AGROW>
            end
            if ~isempty(durations), value=1000*durations(1); end
        end

        function planChanged(app)
            % Marks the editable configuration changed. A frozen run (or one
            % loaded via resumeRun) is authoritative once it exists and is
            % never mutated or discarded here: editable edits made afterward
            % apply only to a future run, started explicitly via
            % freezeCurrentPlan. "Run next"/"Run all" continue the active
            % frozen run regardless of later editable changes.
            if ~app.UnifiedReady || app.PlanState=="RUNNING", return; end
            app.EditableStateChanged=true;
            if strlength(app.ActiveRunFolder)==0
                app.ActiveRunPlan=struct([]);
                app.PlanState="EDITABLE";
            end
            app.updateStateDisplay();
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
            heights(13:19)=repmat({0},1,7);
            planningControls.RowHeight=heights;
            planningControls.RowSpacing=2;
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
            app.CommandVoltageLabel=uilabel(controls,"Text","mod488 (V)", ...
                "HorizontalAlignment","right");
            app.CommandVoltageLabel.Layout.Row=3;
            app.CommandVoltageLabel.Layout.Column=1;
            commandGrid=uigridlayout(controls,[1 1]); commandGrid.Padding=0;
            commandGrid.Layout.Row=3; commandGrid.Layout.Column=2;
            % Reparenting carries the field's coordinates in the planning
            % grid with it, which grew this wrapper to that grid's shape and
            % left the control with zero height -- present, editable, and
            % invisible. Place it explicitly and pin the wrapper to one cell.
            app.ModulatorVoltage.Parent=commandGrid;
            app.ModulatorVoltage.Layout.Row=1;
            app.ModulatorVoltage.Layout.Column=1;
            commandGrid.RowHeight={"1x"}; commandGrid.ColumnWidth={"1x"};
            % Who owns what is a tooltip, not permanent panel space. Neither
            % the 2P Pockels command nor the OBIS setpoint is settable here,
            % and the disabled control already says so in 2P mode.
            app.ModulatorVoltage.Tooltip=["1P mod488 default (V). The 2P " ...
                "Pockels command comes from the protocol, and the 488 nm " ...
                "OBIS power from Luminos/React."];

            velocityLabel=uilabel(controls,"Text","Max velocity");
            velocityLabel.Layout.Row=3; velocityLabel.Layout.Column=3;
            app.MaximumVelocity=uieditfield(controls,"numeric","Value",1000,"Limits",[eps Inf]);
            app.MaximumVelocity.Layout.Row=3; app.MaximumVelocity.Layout.Column=4;
            accelerationLabel=uilabel(controls,"Text","Max acceleration");
            accelerationLabel.Layout.Row=3; accelerationLabel.Layout.Column=5;
            app.MaximumAcceleration=uieditfield(controls,"numeric","Value",6e6,"Limits",[eps Inf]);
            app.MaximumAcceleration.Layout.Row=3; app.MaximumAcceleration.Layout.Column=6;
            app.AllowCalibrationExtrapolation=uicheckbox(controls,"Text","Allow cal extrapolation");
            app.AllowCalibrationExtrapolation.Layout.Row=3; app.AllowCalibrationExtrapolation.Layout.Column=7;
            app.AllowCameraRateOverride=uicheckbox(controls,"Text","Camera-rate override");
            app.AllowCameraRateOverride.Layout.Row=3; app.AllowCameraRateOverride.Layout.Column=8;

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
            reviewButton.Layout.Row=5; reviewButton.Layout.Column=[1 3];
            newRunButton=uibutton(controls,"Text","Freeze new run", ...
                "ButtonPushedFcn",@(~,~)app.invoke(@()app.startNewRun()), ...
                "Tooltip",["Freeze the current editable state as a new run " ...
                "and make it the active one. The previous frozen run's " ...
                "artifacts stay on disk and remain resumable."]);
            newRunButton.Layout.Row=5; newRunButton.Layout.Column=[4 5];
            app.WaveformAxes=uiaxes(runtime);
            title(app.WaveformAxes,"Waveform / DMD preview");

            app.TrialTable=uitable(root,"ColumnName", ...
                {'Trial','Cell','Protocol','Duration','Command (V)','Status','Output'});
            app.TrialTable.Layout.Row=4; app.TrialTable.Layout.Column=[1 3];
            app.OnePhotonControls={};
            app.TwoPhotonControls={velocityLabel,app.MaximumVelocity, ...
                accelerationLabel,app.MaximumAcceleration, ...
                app.AllowCalibrationExtrapolation,app.AllowCameraRateOverride};
            watched=[app.TwoPhotonControls {app.ModulatorVoltage}];
            for k=1:numel(watched)
                if isprop(watched{k},"ValueChangedFcn")
                    watched{k}.ValueChangedFcn=@(~,~)app.planChanged();
                end
            end
            app.Mode.ValueChangedFcn=@(~,~)app.modeChanged();
            app.modeChanged();
        end

        function modeChanged(app)
            is1p=string(app.Mode.Value)=="1p_dmd";
            set_visible(app.OnePhotonControls,is1p);
            set_visible(app.TwoPhotonControls,~is1p);
            app.DmdErosion.Enable=matlab.lang.OnOffSwitchState(is1p);
            app.SpiralRadius.Enable=matlab.lang.OnOffSwitchState(~is1p);
            app.SpiralDensity.Enable=matlab.lang.OnOffSwitchState(~is1p);
            app.updateCommandVoltageControl(is1p);
            app.planChanged();
        end

        function updateCommandVoltageControl(app,is1p)
            % This field is the 1P mod488 default only. A 2P Pockels
            % command comes from the protocol artifact and can never be
            % supplied here, so the control is disabled rather than left
            % looking as though it still applies.
            if isempty(app.CommandVoltageLabel) || ...
                    ~isvalid(app.CommandVoltageLabel), return; end
            app.ModulatorVoltage.Enable=matlab.lang.OnOffSwitchState(is1p);
        end

        function updateStateDisplay(app)
            if isempty(app.StateLabel) || ~isvalid(app.StateLabel), return; end
            switch app.PlanState
                case "FROZEN"
                    app.StateLabel.Text="Frozen run ready / resumable"; app.StateLabel.FontColor=[0 0.5 0];
                case "RUNNING"
                    app.StateLabel.Text="● Running frozen plan"; app.StateLabel.FontColor=[0 0.3 0.8];
                otherwise
                    app.StateLabel.Text="Editable — current settings run";
                    app.StateLabel.FontColor=[0 0.35 0.65];
            end
        end

        function run=executeCurrentPlan(app,count)
            % Continue an existing active frozen run whenever one exists.
            % Editable changes since freezing (app.EditableStateChanged) do
            % not by themselves trigger a new freeze here — only the absence
            % of an active frozen run does. A new run is created only via an
            % explicit freezeCurrentPlan call.
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
                    "ConfirmLiveOutput",true, ...
                    "LaserPowerW",frozenControls.laser_power_w, ...
                    "StopRequestedFcn",@()app.StopRequested);
            else
                if ~isfield(plan.reference,"scanner") || ...
                        ~isfield(plan.reference.scanner,"tform")
                    error("adaptive_optopatch:FrozenScannerCalibrationMissing", ...
                        "The frozen reference model does not contain a scanner " + ...
                        "targeting calibration to execute this run with.");
                end
                run=adaptive_optopatch.run_2p_manifest( ...
                    plan.manifest,plan.targets,app.LuminosApp, ...
                    "ReleaseLevel","standard", ...
                    "OutputDirectory",app.ActiveRunFolder,"OutputRoot",outputRoot, ...
                    "Resume",true,"StopAfterTrial",count, ...
                    "ConfirmTrajectoryTest",true, ...
                    "ConfirmLiveOutput",true, ...
                    "MaximumVelocityVPerS",frozenControls.maximum_velocity_v_per_s, ...
                    "MaximumAccelerationVPerS2",frozenControls.maximum_acceleration_v_per_s2, ...
                    "AllowCalibrationExtrapolation",frozenControls.allow_calibration_extrapolation, ...
                    "AllowCameraRateOverride",frozenControls.allow_camera_rate_override, ...
                    "StopRequestedFcn",@()app.StopRequested, ...
                    "ScannerCalibration",plan.reference.scanner);
            end
            app.LastRun=run;
            app.refreshTrialTable(run.trials);
            app.setStatus("Run stopped normally. Frozen plan: "+app.ActiveRunFolder);
        end

        function finishRunning(app)
            app.setControlsLocked(false);
            app.StopRequested=false;
            app.StopButton.Text="Stop after current";
            if app.PlanState=="RUNNING", app.PlanState="FROZEN"; end
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
            set_visible(app.OnePhotonControls,is1p);
            set_visible(app.TwoPhotonControls,~is1p);
            app.updateCommandVoltageControl(is1p);
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
            [file,folder]=uigetfile({'*.mat','Pulse protocol MAT (*.mat)'}, ...
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
                ['%s — %s | target policy: %s | %d explicit acquisition(s) | ' ...
                 '%d events (%d light), %d conditions | order: %s | seed %g'], ...
                s.protocol_id,s.protocol_type,s.target_policy, ...
                s.definition_acquisition_count,s.event_count,s.light_event_count, ...
                s.condition_count,s.event_order,s.random_seed);
        end

        function invoke(app,operation)
            try
                operation();
            catch exception
                app.showError(exception);
            end
        end

        function refreshTrialTable(app,trials)
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

        function root=defaultRunRoot(app)
            root=app.RunRoot;
            if strlength(root)==0 && isfield(app.LoadInfo,"snapshot_directory")
                root=string(app.LoadInfo.snapshot_directory);
            end
            if strlength(root)==0, root=string(pwd); end
        end

        function chooseRampReview(app)
            if isempty(app.PulseProtocol) || ...
                    string(app.PulseProtocol.protocol_type)~="single_cell_blue_ramp"
                error("adaptive_optopatch:RampProtocolRequired", ...
                    "Load the single-cell Blue ramp protocol used for the acquisition first.");
            end
            folder=uigetdir(app.defaultRunRoot(),"Select completed ramp acquisition");
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
                app.currentFovState(),"DecisionAppliedFcn",@(state)app.acceptRampReview(state));
        end

        function acceptRampReview(app,state)
            app.CurrentFovState=state;
            app.updateQc();
            app.setStatus("Stored ramp calibration decision in the active FOV. Save the FOV to persist it.");
        end

        function protocol=protocolWithEffectiveVoltage(~,protocol,isNull)
            protocol=adaptive_optopatch.normalize_protocol(protocol);
            if isNull, protocol.events.command_voltage_v(:)=0; end
        end

        function value=captureRunControls(app)
            value=struct("active_obis_power_w",app.currentObisPowerW(), ...
                "maximum_velocity_v_per_s",app.MaximumVelocity.Value, ...
                "maximum_acceleration_v_per_s2",app.MaximumAcceleration.Value, ...
                "allow_calibration_extrapolation",app.AllowCalibrationExtrapolation.Value, ...
                "allow_camera_rate_override",app.AllowCameraRateOverride.Value);
        end

        function value=plannedObisPowerW(app)
            value=app.currentObisPowerW();
        end

        function controls=frozenRunControls(~,plan)
            saved=plan.session.run_controls;
            controls=struct;
            % Luminos/React owns the OBIS setpoint. NaN tells the runner to
            % preserve it; the observed value remains archived in the plan.
            controls.laser_power_w=NaN;
            % Command voltages are resolved per event and frozen into the
            % manifest; there is no run-level voltage control to restore.
            controls.maximum_velocity_v_per_s=saved.maximum_velocity_v_per_s;
            controls.maximum_acceleration_v_per_s2=saved.maximum_acceleration_v_per_s2;
            controls.allow_calibration_extrapolation=saved.allow_calibration_extrapolation;
            controls.allow_camera_rate_override=saved.allow_camera_rate_override;
        end
    end
end

function set_visible(controls,state)
for k=1:numel(controls), controls{k}.Visible=matlab.lang.OnOffSwitchState(state); end
end

function preflight_camera_frames(cameras,durationS,allowOverride)
original=arrayfun(@(camera)double(camera.frames_requested),cameras);
cleanup=onCleanup(@()restore_camera_frames(cameras,original));
adaptive_optopatch.set_camera_frames_for_duration(cameras,durationS, ...
    "AllowRateLimitOverride",allowOverride);
end

function restore_camera_frames(cameras,frames)
for k=1:numel(cameras), cameras(k).frames_requested=frames(k); end
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

function value=manifest_advisories(manifest)
value=struct([]);
if isfield(manifest,"advisories"), value=manifest.advisories; end
end

function save_frozen_protocol_archive(path,protocols,trialIds)
if isscalar(protocols)
    assert_resolved_protocol(protocols{1},1);
    adaptive_optopatch.save_protocol(path,protocols{1});
    return
end
for k=1:numel(protocols)
    protocols{k}=assert_resolved_protocol(protocols{k},k);
end
protocol_set=struct("schema_version","1.0.0", ...
    "archive_type","resolved_acquisition_protocol_set", ...
    "acquisition_count",numel(protocols),"trial_id",trialIds(:), ...
    "protocols",{protocols(:)});
save(path,"protocol_set","-v7.3");
end

function protocol=assert_resolved_protocol(protocol,index)
report=adaptive_optopatch.validate_protocol(protocol);
if report.passed
    unresolved=~report.protocol.events.is_null & ...
        strlength(report.protocol.events.target_cell_id)==0;
    if any(unresolved)
        report.issues(end+1)="Every non-null pulse must have a resolved target cell.";
        report.passed=false;
    end
end
if ~report.passed
    error("adaptive_optopatch:UnresolvedFrozenProtocol", ...
        "Acquisition %d is not fully resolved: %s",index,strjoin(report.issues," "));
end
protocol=report.protocol;
end

function [protocol,protocols]=load_frozen_protocol_archive(path)
saved=load(path);
if isfield(saved,"protocol")
    protocol=adaptive_optopatch.load_protocol(path);
    protocols={protocol};
elseif isfield(saved,"protocol_set") && ...
        string(saved.protocol_set.archive_type)=="resolved_acquisition_protocol_set"
    protocols=saved.protocol_set.protocols;
    protocol=protocols{1};
else
    error("adaptive_optopatch:InvalidFrozenProtocolArchive", ...
        "Frozen pulse_protocol.mat has no resolved protocol archive.");
end
end

function transform=plan_targeting_transform(plan)
% The transform this plan will be executed with once frozen, so preview
% draws the trajectory the galvos will actually follow.
transform=[];
if isfield(plan,"reference") && isfield(plan.reference,"scanner") && ...
        isfield(plan.reference.scanner,"tform")
    transform=plan.reference.scanner.tform;
end
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
