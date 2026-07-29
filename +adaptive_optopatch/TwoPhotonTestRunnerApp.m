classdef TwoPhotonTestRunnerApp < handle
    %TWOPHOTONTESTRUNNERAPP Staged blocked/attenuated 2P runner GUI.
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
        Voltage
        MaxVelocity
        MaxAcceleration
        TrajectoryConfirmed
        LightConfirmed
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
            gui.BundleFolder=folder; gui.Targets=a.targets; gui.Manifest=b.manifest;
        end
        function buildUI(gui,visible)
            gui.Figure=uifigure("Name","Adaptive Optopatch — Staged 2P Runner", ...
                "Position",[150 100 980 650],"Visible",visible, ...
                "CloseRequestFcn",@(~,~)delete(gui));
            root=uigridlayout(gui.Figure,[3 2]);
            root.ColumnWidth={330,"1x"}; root.RowHeight={210,"1x",120};
            controls=uigridlayout(root,[8 2]); controls.ColumnWidth={"1x",120};
            uilabel(controls,"Text","Release level");
            gui.ReleaseLevel=uidropdown(controls, ...
                "Items",["blocked_test","attenuated_test"],"Value","blocked_test");
            add("Test pulses","PulseCount",1);
            add("Pockels (V)","Voltage",0);
            add("Max velocity (V/s)","MaxVelocity",30);
            add("Max acceleration (V/s²)","MaxAcceleration",1800);
            gui.TrajectoryConfirmed=uicheckbox(controls, ...
                "Text","Blocked trajectory reviewed","Value",false);
            gui.TrajectoryConfirmed.Layout.Column=[1 2];
            gui.LightConfirmed=uicheckbox(controls, ...
                "Text","ARM attenuated 2P output","Value",false);
            gui.LightConfirmed.Layout.Column=[1 2];
            uibutton(controls,"Text","Validate + preview", ...
                "ButtonPushedFcn",@(~,~)gui.preview());
            uibutton(controls,"Text","Run one test acquisition", ...
                "FontWeight","bold","ButtonPushedFcn",@(~,~)gui.run());
            gui.Axes=uiaxes(root); gui.Axes.Layout.Row=[1 2]; gui.Axes.Layout.Column=2;
            gui.Status=uitextarea(root,"Editable","off");
            gui.Status.Layout.Row=3; gui.Status.Layout.Column=[1 2];
            gui.Status.Value=["Start with blocked_test and Pockels = 0 V."; ...
                "Only one target acquisition will run."];
            function add(label,name,value)
                uilabel(controls,"Text",label);
                gui.(name)=uieditfield(controls,"numeric","Value",value);
            end
        end
        function [hardware,protocol,target]=preparePreview(gui)
            hardware=adaptive_optopatch.resolve_luminos_2p_hardware(gui.LuminosApp);
            trial=gui.Manifest.trials(find(~gui.Manifest.trials.is_null,1),:);
            protocol=trial.pulse_schedule{1};
            count=min(gui.PulseCount.Value,height(protocol.events));
            protocol.events=protocol.events(1:count,:);
            protocol.pulse_count=count;
            protocol.acquisition_duration_s=protocol.events.offset_s(end)+ ...
                protocol.post_delay_ms/1000;
            voltage=gui.Voltage.Value;
            if gui.ReleaseLevel.Value=="blocked_test", voltage=0; end
            protocol.events.modulator_voltage(:)=voltage;
            target=gui.Targets.targets(trial.target_index);
        end
        function preview(gui)
            try
                [hardware,protocol,target]=gui.preparePreview();
                w=adaptive_optopatch.build_2p_trial_waveforms( ...
                    protocol,target,hardware.scanner.tform, ...
                    "MaximumVelocityVPerS",gui.MaxVelocity.Value, ...
                    "MaximumAccelerationVPerS2",gui.MaxAcceleration.Value);
                t=(0:numel(w.x_v)-1)'/w.sample_rate_hz;
                cla(gui.Axes); yyaxis(gui.Axes,"left");
                plot(gui.Axes,t,w.x_v,t,w.y_v); ylabel(gui.Axes,"Galvo (V)");
                yyaxis(gui.Axes,"right"); plot(gui.Axes,t,w.pockels_v,"k-");
                ylabel(gui.Axes,"Pockels (V)"); xlabel(gui.Axes,"Time (s)");
                gui.setStatus(sprintf([ ...
                    'PASS: calibration %s. %d samples, %.3f s.\\n' ...
                    'Velocity %.3g V/s; acceleration %.3g V/s^2; parking [%.4g %.4g] V.'], ...
                    hardware.calibration.calibration_id,numel(w.x_v),numel(w.x_v)/w.sample_rate_hz, ...
                    w.preflight.max_command_velocity_volts_per_s, ...
                    w.preflight.max_command_acceleration_volts_per_s2,w.parking_v));
            catch exception
                gui.showError(exception);
            end
        end
        function run(gui)
            try
                gui.preview(); drawnow;
                result=adaptive_optopatch.run_2p_manifest( ...
                    gui.Manifest,gui.Targets,gui.LuminosApp, ...
                    "ReleaseLevel",string(gui.ReleaseLevel.Value), ...
                    "OutputDirectory",gui.BundleFolder, ...
                    "ConfirmTrajectoryTest",gui.TrajectoryConfirmed.Value, ...
                    "ConfirmLiveOutput",gui.LightConfirmed.Value, ...
                    "ModulatorVoltageOverride",gui.Voltage.Value, ...
                    "MaximumVelocityVPerS",gui.MaxVelocity.Value, ...
                    "MaximumAccelerationVPerS2",gui.MaxAcceleration.Value, ...
                    "TestPulseCount",gui.PulseCount.Value);
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
