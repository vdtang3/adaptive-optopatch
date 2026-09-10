classdef TwoPhotonTestRunnerApp < handle
    %TWOPHOTONTESTRUNNERAPP Standalone commissioning runner for a frozen 2P run.
    %   This is the operator interface for the staged blocked/attenuated/pilot
    %   sequence documented in the README. It never designs an experiment: it
    %   loads a frozen schema-3 planning bundle and drives the canonical staged
    %   execution path, so preview and acquisition derive the same physical
    %   schedule through adaptive_optopatch.plan_staged_2p_execution and
    %   adaptive_optopatch.stage_2p_execution_protocol.
    properties (SetAccess=private)
        Figure
    end
    properties (Access=private)
        LuminosApp
        BundleFolder string
        Manifest
        Targets
        ScannerCalibration struct = struct([])
        CalibrationSource string = "live_active_calibration"
        ReleaseLevel
        PulseCount
        Voltage
        MaxVelocity
        MaxAcceleration
        TrajectoryConfirmed
        LightConfirmed
        AllowCalibrationExtrapolation
        AllowCameraRateOverride
        SelectionLabel
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
            gui.describeSelection();
        end
        function delete(gui)
            if ~isempty(gui.Figure) && isvalid(gui.Figure)
                gui.Figure.CloseRequestFcn=[]; delete(gui.Figure);
            end
        end

        function setRunParameter(gui,name,value)
            %SETRUNPARAMETER Set one operator control by name.
            name=lower(string(name));
            mapping=struct("release_level",gui.ReleaseLevel, ...
                "test_pulses",gui.PulseCount,"pockels_v",gui.Voltage, ...
                "maximum_velocity",gui.MaxVelocity, ...
                "maximum_acceleration",gui.MaxAcceleration, ...
                "confirm_trajectory",gui.TrajectoryConfirmed, ...
                "confirm_live_output",gui.LightConfirmed, ...
                "allow_calibration_extrapolation",gui.AllowCalibrationExtrapolation, ...
                "allow_camera_rate_override",gui.AllowCameraRateOverride);
            key=char(name);
            if ~isfield(mapping,key)
                error("adaptive_optopatch:UnknownRunParameter", ...
                    "Unknown 2P runner control: %s",name);
            end
            mapping.(key).Value=value;
            gui.describeSelection();
        end

        function [staging,row,protocol]=stagedExecution(gui)
            %STAGEDEXECUTION Describe the acquisition the current controls run.
            level=string(gui.ReleaseLevel.Value);
            count=gui.PulseCount.Value;
            if fix(count)~=count || count<1
                error("adaptive_optopatch:InvalidPulseCount", ...
                    "Test pulses must be a positive integer.");
            end
            staging=adaptive_optopatch.plan_staged_2p_execution( ...
                gui.Manifest,level,"TestPulseCount",count, ...
                "ModulatorVoltageOverride",gui.Voltage.Value);
            row=gui.Manifest.trials(staging.source_trial_index,:);
            protocol=adaptive_optopatch.stage_2p_execution_protocol( ...
                row.pulse_schedule{1},staging,row.is_null);
        end

        function result=preview(gui)
            %PREVIEW Build and plot the exact waveforms this call would run.
            result=struct([]);
            try
                [hardware,protocol,target,staging]=gui.preparePreview();
                previewOptions={"ReleaseLevel",string(gui.ReleaseLevel.Value), ...
                    "MaximumVelocityVPerS",gui.MaxVelocity.Value, ...
                    "MaximumAccelerationVPerS2",gui.MaxAcceleration.Value, ...
                    "AllowCalibrationExtrapolation", ...
                    gui.AllowCalibrationExtrapolation.Value};
                if gui.CalibrationSource=="frozen_plan"
                    previewOptions=[previewOptions, ...
                        {"TargetingTransform",gui.ScannerCalibration.tform}];
                end
                result=adaptive_optopatch.build_2p_plan_preview( ...
                    protocol,target,hardware,previewOptions{:});
                gui.plotPreview(result,protocol,staging,hardware);
            catch exception
                gui.showError(exception);
            end
        end

        function result=run(gui)
            %RUN Execute one staged acquisition from the frozen bundle.
            result=struct([]);
            try
                gui.preview(); drawnow;
                runOptions={"ReleaseLevel",string(gui.ReleaseLevel.Value), ...
                    "OutputDirectory",gui.BundleFolder, ...
                    "ConfirmTrajectoryTest",gui.TrajectoryConfirmed.Value, ...
                    "ConfirmLiveOutput",gui.LightConfirmed.Value, ...
                    "ModulatorVoltageOverride",gui.Voltage.Value, ...
                    "MaximumVelocityVPerS",gui.MaxVelocity.Value, ...
                    "MaximumAccelerationVPerS2",gui.MaxAcceleration.Value, ...
                    "TestPulseCount",gui.PulseCount.Value, ...
                    "AllowCalibrationExtrapolation", ...
                    gui.AllowCalibrationExtrapolation.Value, ...
                    "AllowCameraRateOverride",gui.AllowCameraRateOverride.Value};
                if gui.CalibrationSource=="frozen_plan"
                    runOptions=[runOptions, ...
                        {"ScannerCalibration",gui.ScannerCalibration}];
                end
                result=adaptive_optopatch.run_2p_manifest( ...
                    gui.Manifest,gui.Targets,gui.LuminosApp,runOptions{:});
                index=result.staging.source_trial_index;
                gui.setStatus("Test acquisition completed: "+ ...
                    string(result.trials.experiment_directory(index)));
            catch exception
                gui.showError(exception);
            end
        end

        function value=statusText(gui)
            %STATUSTEXT Current status lines as one string array.
            value=string(gui.Status.Value);
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
                details=char(strjoin(validation.issues(:)'," "));
                message=sprintf([ ...
                    'This planning bundle cannot be run safely. Load the ' ...
                    'Snap and save a new planning bundle with the updated ' ...
                    'GUI. Details: %s'],details);
                error('adaptive_optopatch:OutdatedTwoPhotonBundle','%s',message);
            end
            gui.BundleFolder=folder; gui.Targets=a.targets; gui.Manifest=b.manifest;
            % A frozen run archives the targeting transform it was planned
            % with. Execute that transform rather than whatever calibration
            % happens to be active now; fall back to the active calibration
            % only for bundles that carry none.
            referencePath=fullfile(folder,"reference_model.mat");
            if isfile(referencePath)
                saved=load(referencePath,"reference");
                if isfield(saved,"reference") && isfield(saved.reference,"scanner") && ...
                        isfield(saved.reference.scanner,"tform")
                    gui.ScannerCalibration=saved.reference.scanner;
                    gui.CalibrationSource="frozen_plan";
                end
            end
        end
        function buildUI(gui,visible)
            simulation=isa(gui.LuminosApp, ...
                "adaptive_optopatch.testing.SimulatedLuminosApp");
            title="Adaptive Optopatch — Guarded 2P Runner";
            if simulation, title=title+" [SIMULATION]"; end
            gui.Figure=uifigure("Name",title, ...
                "Position",[150 100 980 650],"Visible",visible, ...
                "CloseRequestFcn",@(~,~)delete(gui));
            root=uigridlayout(gui.Figure,[4 2]);
            root.ColumnWidth={390,"1x"}; root.RowHeight={42,305,"1x",120};
            if ~simulation, root.RowHeight={0,305,"1x",120}; end
            banner=uilabel(root,"Text","SIMULATION — NO HARDWARE OUTPUT", ...
                "HorizontalAlignment","center","FontWeight","bold", ...
                "FontSize",16,"FontColor",[1 1 1],"BackgroundColor",[0.75 0.05 0.05], ...
                "Visible",matlab.lang.OnOffSwitchState(simulation));
            banner.Layout.Row=1; banner.Layout.Column=[1 2];
            controls=uigridlayout(root,[11 2]); controls.ColumnWidth={"1x",190};
            controls.Layout.Row=[2 3]; controls.Layout.Column=1;
            uilabel(controls,"Text","Release level");
            gui.ReleaseLevel=uidropdown(controls, ...
                "Items",["blocked_test","attenuated_test", ...
                "pilot_single","pilot_mixed_trains"], ...
                "Value","blocked_test", ...
                "ValueChangedFcn",@(~,~)gui.describeSelection());
            add("Test pulses (screen only)","PulseCount",1);
            add("Pockels (V)","Voltage",0);
            add("Max velocity (V/s)","MaxVelocity",1000);
            add("Max acceleration (V/s²)","MaxAcceleration",6e6);
            gui.TrajectoryConfirmed=uicheckbox(controls, ...
                "Text","Blocked trajectory reviewed","Value",false);
            gui.TrajectoryConfirmed.Layout.Column=[1 2];
            gui.LightConfirmed=uicheckbox(controls, ...
                "Text","ARM live 2P output","Value",false);
            if simulation, gui.LightConfirmed.Text="ARM simulated 2P output"; end
            gui.LightConfirmed.Layout.Column=[1 2];
            gui.AllowCalibrationExtrapolation=uicheckbox(controls, ...
                "Text","Allow calibration extrapolation","Value",false, ...
                "Tooltip",["Permit targets outside the accepted calibration hull. " ...
                "Absolute voltage and motion limits remain enforced."]);
            gui.AllowCalibrationExtrapolation.Layout.Column=[1 2];
            gui.AllowCameraRateOverride=uicheckbox(controls, ...
                "Text","Allow camera-rate override","Value",false, ...
                "Tooltip",["Use the configured DAQ trigger period even when " ...
                "the Luminos ROI-rate estimate is unavailable or below it."]);
            gui.AllowCameraRateOverride.Layout.Column=[1 2];
            gui.SelectionLabel=uilabel(controls,"Text","","WordWrap","on");
            gui.SelectionLabel.Layout.Column=[1 2];
            uibutton(controls,"Text","Validate + preview", ...
                "ButtonPushedFcn",@(~,~)gui.preview());
            uibutton(controls,"Text","Run one test acquisition", ...
                "FontWeight","bold","ButtonPushedFcn",@(~,~)gui.run());
            gui.Axes=uiaxes(root); gui.Axes.Layout.Row=[2 3]; gui.Axes.Layout.Column=2;
            gui.Status=uitextarea(root,"Editable","off");
            gui.Status.Layout.Row=4; gui.Status.Layout.Column=[1 2];
            gui.Status.Value=["Start with blocked_test and Pockels = 0 V."; ...
                "pilot_mixed_trains runs a bundle frozen from an STF protocol."];
            function add(label,name,value)
                uilabel(controls,"Text",label);
                gui.(name)=uieditfield(controls,"numeric","Value",value, ...
                    "ValueChangedFcn",@(~,~)gui.describeSelection());
            end
        end

        function describeSelection(gui)
            if isempty(gui.SelectionLabel) || ~isvalid(gui.SelectionLabel), return; end
            try
                [~,row,protocol]=gui.stagedExecution();
                gui.SelectionLabel.Text=sprintf( ...
                    ['Trial %g (%s), %s: %d of %d frozen events, %.3f s. ' ...
                     'Targeting transform: %s.'], ...
                    row.trial_id,char(string(row.target_cell_id)), ...
                    char(string(row.pulse_schedule{1}.protocol_type)), ...
                    height(protocol.events), ...
                    height(row.pulse_schedule{1}.events), ...
                    protocol.acquisition_duration_s, ...
                    char(gui.CalibrationSource));
            catch exception
                gui.SelectionLabel.Text=char(string(exception.message));
            end
        end

        function [hardware,protocol,target,staging]=preparePreview(gui)
            hardware=adaptive_optopatch.resolve_luminos_2p_hardware( ...
                gui.LuminosApp,"ApplyCalibration",false);
            [staging,row,protocol]=gui.stagedExecution();
            target=adaptive_optopatch.resolve_trial_target(gui.Targets,row);
        end

        function plotPreview(gui,result,protocol,staging,hardware)
            w=result.waveforms; coverage=result.calibration_coverage;
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
                    '\nAcquisition tail extended by %.3f s so the final spiral ' ...
                    'can finish and park safely.'],w.automatic_extension_s);
            end
            coverageText="";
            if ~coverage.passed
                coverageText=sprintf( ...
                    '\nWARNING: calibration extrapolation enabled: %s', ...
                    strjoin(coverage.issues," "));
            end
            gui.describeSelection();
            gui.setStatus(sprintf([ ...
                'PASS: %s executing %d event(s) at %.4g V command.\n' ...
                'Targeting transform: %s; active calibration %s.\n' ...
                '%d samples, %.3f s. Velocity %.3g V/s; acceleration ' ...
                '%.3g V/s^2; parking [%.4g %.4g] V.%s%s'], ...
                char(staging.release_level),height(protocol.events), ...
                max(protocol.events.command_voltage_v), ...
                char(result.targeting_transform_source), ...
                char(string(hardware.calibration.calibration_id)), ...
                numel(w.x_v),numel(w.x_v)/w.sample_rate_hz, ...
                w.preflight.max_command_velocity_volts_per_s, ...
                w.preflight.max_command_acceleration_volts_per_s2,w.parking_v, ...
                extensionText,coverageText));
        end

        function setStatus(gui,message), gui.Status.Value=splitlines(string(message)); end
        function showError(gui,exception)
            gui.setStatus("ERROR: "+string(exception.message));
            uialert(gui.Figure,exception.message,"2P runner error","Icon","error");
        end
    end
end
