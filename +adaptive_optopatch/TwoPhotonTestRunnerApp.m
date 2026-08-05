classdef TwoPhotonTestRunnerApp < handle
    %TWOPHOTONTESTRUNNERAPP Guarded staged and production-pilot 2P runner.
    properties (SetAccess=private)
        Figure
    end
    properties (Access=private)
        LuminosApp
        BundleFolder string
        Manifest
        Targets
        ReleaseLevel
        PulseCount
        RepeatsPerCondition
        Voltage
        MaxVelocity
        MaxAcceleration
        TrajectoryConfirmed
        LightConfirmed
        AllowCalibrationExtrapolation
        Status
        Axes
    end
    methods
        function gui=TwoPhotonTestRunnerApp(luminosApp,bundleFolder,options)
            arguments
                luminosApp
                bundleFolder (1,1) string = ""
                options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
            end
            gui.LuminosApp=luminosApp;
            if strlength(bundleFolder)==0
                selected=uigetdir(pwd,"Select a 2P Adaptive Optopatch planning bundle");
                if isequal(selected,0), error("adaptive_optopatch:NoBundleSelected","No bundle selected."); end
                bundleFolder=string(selected);
            end
            gui.loadBundle(bundleFolder); gui.buildUI(options.Visible);
        end
        function delete(gui)
            if ~isempty(gui.Figure) && isvalid(gui.Figure)
                gui.Figure.CloseRequestFcn=[]; delete(gui.Figure);
            end
        end
    end
    methods (Access=private)
        function loadBundle(gui,folder)
            a=load(fullfile(folder,"pattern_bundle.mat"),"targets");
            b=load(fullfile(folder,"trial_manifest.mat"),"manifest");
            if ~isfield(a,"targets") || ~isfield(b,"manifest") || ...
                    any(string(b.manifest.trials.stimulation_mode)~="2p_spiral")
                error("adaptive_optopatch:InvalidTwoPhotonBundle", ...
                    "Select a planning bundle saved in 2p_spiral mode.");
            end
            validation=adaptive_optopatch.validate_2p_planning_bundle(a.targets);
            if ~validation.passed
                error("adaptive_optopatch:OutdatedTwoPhotonBundle", ...
                    "This planning bundle cannot be run safely. Load the "+ ...
                    "Snap and save a new planning bundle with the updated "+ ...
                    "GUI. Details: %s",strjoin(validation.issues," "));
            end
            gui.BundleFolder=folder; gui.Targets=a.targets; gui.Manifest=b.manifest;
        end
        function buildUI(gui,visible)
            gui.Figure=uifigure("Name","Adaptive Optopatch — Guarded 2P Runner", ...
                "Position",[150 100 980 650],"Visible",visible, ...
                "CloseRequestFcn",@(~,~)delete(gui));
            root=uigridlayout(gui.Figure,[3 2]);
            root.ColumnWidth={390,"1x"}; root.RowHeight={275,"1x",120};
            controls=uigridlayout(root,[10 2]); controls.ColumnWidth={"1x",190};
            uilabel(controls,"Text","Release level");
            gui.ReleaseLevel=uidropdown(controls, ...
                "Items",["blocked_test","attenuated_test", ...
                "pilot_single","pilot_mixed_trains"], ...
                "Value","blocked_test");
            add("Screen/test pulses","PulseCount",1);
            add("STF repeats/condition","RepeatsPerCondition",50);
            add("Pockels (V)","Voltage",0);
            add("Max velocity (V/s)","MaxVelocity",1000);
            add("Max acceleration (V/s²)","MaxAcceleration",6e6);
            gui.TrajectoryConfirmed=uicheckbox(controls, ...
                "Text","Blocked trajectory reviewed","Value",false);
            gui.TrajectoryConfirmed.Layout.Column=[1 2];
            gui.LightConfirmed=uicheckbox(controls, ...
                "Text","ARM live 2P output","Value",false);
            gui.LightConfirmed.Layout.Column=[1 2];
            gui.AllowCalibrationExtrapolation=uicheckbox(controls, ...
                "Text","Allow calibration extrapolation","Value",false, ...
                "Tooltip",["Permit targets outside the accepted calibration hull. " ...
                "Absolute voltage and motion limits remain enforced."]);
            gui.AllowCalibrationExtrapolation.Layout.Column=[1 2];
            uibutton(controls,"Text","Validate + preview", ...
                "ButtonPushedFcn",@(~,~)gui.preview());
            uibutton(controls,"Text","Run one test acquisition", ...
                "FontWeight","bold","ButtonPushedFcn",@(~,~)gui.run());
            gui.Axes=uiaxes(root); gui.Axes.Layout.Row=[1 2]; gui.Axes.Layout.Column=2;
            gui.Status=uitextarea(root,"Editable","off");
            gui.Status.Layout.Row=3; gui.Status.Layout.Column=[1 2];
            gui.Status.Value=["Start with blocked_test and Pockels = 0 V."; ...
                "Choose pilot_single or pilot_mixed_trains for production pilots."];
            function add(label,name,value)
                uilabel(controls,"Text",label);
                gui.(name)=uieditfield(controls,"numeric","Value",value);
            end
        end
        function manifest=prepareSelectedManifest(gui)
            manifest=gui.Manifest;
            idx=find(~manifest.trials.is_null,1);
            if isempty(idx)
                error("adaptive_optopatch:NoStimulatedTrial", ...
                    "No non-null 2P trial was found.");
            end
            manifest.trials=manifest.trials(idx,:);
            if string(gui.ReleaseLevel.Value)=="pilot_mixed_trains"
                repeats=gui.RepeatsPerCondition.Value;
                if fix(repeats)~=repeats || repeats<1
                    error("adaptive_optopatch:InvalidStfRepeats", ...
                        "STF repeats per condition must be a positive integer.");
                end
                source=manifest.trials.pulse_schedule{1};
                pulseDurationMs=5;
                if isfield(source,"events") && ~isempty(source.events) && ...
                        ismember("duration_s",string(source.events.Properties.VariableNames))
                    pulseDurationMs=1000*double(source.events.duration_s(1));
                end
                conditions=adaptive_optopatch.default_stf_conditions( ...
                    "RepeatsPerCondition",repeats,"PulsesPerTrain",10, ...
                    "PulseDurationMs",pulseDurationMs, ...
                    "ModulatorVoltage",max(0,gui.Voltage.Value));
                protocol=adaptive_optopatch.generate_stf_protocol(conditions, ...
                    "EventDarkIntervalMs",[450 550],"PreDelayMs",100, ...
                    "PostDelayMs",100,"RandomSeed",1001);
                manifest.trials.pulse_schedule={protocol};
                manifest.trials.acquisition_duration_s=protocol.acquisition_duration_s;
                manifest.trials.output_tag=string(manifest.trials.output_tag)+"_stf";
            end
        end
        function [hardware,protocol,target,manifest]=preparePreview(gui)
            hardware=adaptive_optopatch.resolve_luminos_2p_hardware(gui.LuminosApp);
            manifest=gui.prepareSelectedManifest();
            trial=manifest.trials(1,:);
            protocol=trial.pulse_schedule{1};
            if string(gui.ReleaseLevel.Value)~="pilot_mixed_trains"
                count=gui.PulseCount.Value;
                if fix(count)~=count || count<1
                    error("adaptive_optopatch:InvalidPulseCount", ...
                        "Pulse count must be a positive integer.");
                end
                if count>height(protocol.events)
                    protocol=adaptive_optopatch.generate_screen_protocol( ...
                        "PulseCount",count, ...
                        "PulseDurationMs",protocol.pulse_duration_ms, ...
                        "DarkIntervalMs",protocol.dark_interval_range_ms, ...
                        "PreDelayMs",protocol.pre_delay_ms, ...
                        "PostDelayMs",protocol.post_delay_ms, ...
                        "ModulatorVoltage",max(0,gui.Voltage.Value), ...
                        "RandomSeed",protocol.random_seed);
                else
                    protocol.events=protocol.events(1:count,:);
                    protocol.pulse_count=count;
                    protocol.total_light_on_s=sum(protocol.events.duration_s);
                    protocol.acquisition_duration_s=protocol.events.offset_s(end)+ ...
                        protocol.post_delay_ms/1000;
                end
                manifest.trials.pulse_schedule={protocol};
                manifest.trials.acquisition_duration_s=protocol.acquisition_duration_s;
            end
            voltage=gui.Voltage.Value;
            if string(gui.ReleaseLevel.Value)=="blocked_test", voltage=0; end
            protocol.events.modulator_voltage(:)=voltage;
            manifest.trials.pulse_schedule={protocol};
            target=gui.Targets.targets(trial.target_index);
        end
        function preview(gui)
            try
                motionValidation= ...
                    adaptive_optopatch.validate_provisional_2p_motion_limits( ...
                    gui.MaxVelocity.Value,gui.MaxAcceleration.Value);
                if ~motionValidation.passed
                    error("adaptive_optopatch:UnvalidatedGalvoMotionLimits", ...
                        "%s",strjoin(motionValidation.issues,newline));
                end
                [hardware,protocol,target]=gui.preparePreview();
                coverage=adaptive_optopatch.validate_2p_calibration_coverage( ...
                    target,hardware.calibration);
                if ~coverage.passed && ~gui.AllowCalibrationExtrapolation.Value
                    error("adaptive_optopatch:TargetOutsideGalvoCalibration", ...
                        ["The target lies outside the accepted calibration hull. " ...
                         "Enable Allow calibration extrapolation to proceed. Details: %s"], ...
                        strjoin(coverage.issues," "));
                end
                minimumRadiusFraction=0.95;
                if string(gui.ReleaseLevel.Value)=="blocked_test"
                    minimumRadiusFraction=eps;
                end
                w=adaptive_optopatch.build_2p_trial_waveforms( ...
                    protocol,target,hardware.scanner.tform, ...
                    "MaximumVelocityVPerS",gui.MaxVelocity.Value, ...
                    "MaximumAccelerationVPerS2",gui.MaxAcceleration.Value, ...
                    "MinimumIlluminatedRadiusFraction",minimumRadiusFraction);
                t=(0:numel(w.x_v)-1)'/w.sample_rate_hz;
                plotStep=max(1,ceil(numel(t)/200000));
                plotIndex=1:plotStep:numel(t);
                cla(gui.Axes); yyaxis(gui.Axes,"left");
                plot(gui.Axes,t(plotIndex),w.x_v(plotIndex), ...
                    t(plotIndex),w.y_v(plotIndex)); ylabel(gui.Axes,"Galvo (V)");
                yyaxis(gui.Axes,"right");
                plot(gui.Axes,t(plotIndex),w.pockels_v(plotIndex),"k-");
                ylabel(gui.Axes,"Pockels (V)"); xlabel(gui.Axes,"Time (s)");
                extensionText="";
                if w.automatic_extension_s>0
                    extensionText=sprintf([ ...
                        '\\nAcquisition tail extended by %.3f s so the final spiral ' ...
                        'can finish and park safely.'],w.automatic_extension_s);
                end
                coverageText="";
                if ~coverage.passed
                    coverageText=sprintf( ...
                        '\\nWARNING: calibration extrapolation enabled: %s', ...
                        strjoin(coverage.issues," "));
                end
                gui.setStatus(sprintf([ ...
                    'PASS: calibration %s. %d samples, %.3f s.\\n' ...
                    'Velocity %.3g V/s; acceleration %.3g V/s^2; parking [%.4g %.4g] V.%s%s'], ...
                    hardware.calibration.calibration_id,numel(w.x_v),numel(w.x_v)/w.sample_rate_hz, ...
                    w.preflight.max_command_velocity_volts_per_s, ...
                    w.preflight.max_command_acceleration_volts_per_s2,w.parking_v, ...
                    extensionText,coverageText));
            catch exception
                gui.showError(exception);
            end
        end
        function run(gui)
            try
                gui.preview(); drawnow;
                [~,~,~,selectedManifest]=gui.preparePreview();
                result=adaptive_optopatch.run_2p_manifest( ...
                    selectedManifest,gui.Targets,gui.LuminosApp, ...
                    "ReleaseLevel",string(gui.ReleaseLevel.Value), ...
                    "OutputDirectory",gui.BundleFolder, ...
                    "ConfirmTrajectoryTest",gui.TrajectoryConfirmed.Value, ...
                    "ConfirmLiveOutput",gui.LightConfirmed.Value, ...
                    "ModulatorVoltageOverride",gui.Voltage.Value, ...
                    "MaximumVelocityVPerS",gui.MaxVelocity.Value, ...
                    "MaximumAccelerationVPerS2",gui.MaxAcceleration.Value, ...
                    "TestPulseCount",gui.PulseCount.Value, ...
                    "AllowCalibrationExtrapolation", ...
                    gui.AllowCalibrationExtrapolation.Value);
                gui.setStatus("Test acquisition completed: "+ ...
                    string(result.trials.experiment_directory(1)));
            catch exception
                gui.showError(exception);
            end
        end
        function setStatus(gui,message), gui.Status.Value=splitlines(string(message)); end
        function showError(gui,exception)
            gui.setStatus("ERROR: "+string(exception.message));
            uialert(gui.Figure,exception.message,"2P runner error","Icon","error");
        end
    end
end
