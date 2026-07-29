classdef OnePhotonRunnerApp < handle
    %ONEPHOTONRUNNERAPP Operator GUI for automated DMD_Blue acquisitions.
    properties (SetAccess=private)
        Figure
    end
    properties (Access=private)
        LuminosApp
        BundleFolder string
        Manifest
        Targets
        TrialTable
        Status
        PowerOverride
        PowerMw
        VoltageOverride
        VoltageV
        ArmLive
        RunNextButton
        RunAllButton
        StopButton
        StopRequested logical = false
        Busy logical = false
    end
    methods
        function gui=OnePhotonRunnerApp(luminosApp,bundleFolder,options)
            arguments
                luminosApp
                bundleFolder (1,1) string = ""
                options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
            end
            gui.LuminosApp=luminosApp;
            if strlength(bundleFolder)==0
                selected=uigetdir(pwd,"Select an Adaptive Optopatch planning bundle");
                if isequal(selected,0)
                    error("adaptive_optopatch:NoBundleSelected", ...
                        "No planning bundle was selected.");
                end
                bundleFolder=string(selected);
            end
            gui.loadBundle(bundleFolder);
            gui.buildUI(options.Visible);
            gui.refresh();
            gui.readActiveLaserPower();
        end
        function delete(gui)
            gui.StopRequested=true;
            if ~isempty(gui.Figure) && isvalid(gui.Figure), delete(gui.Figure); end
        end
    end
    methods (Access=private)
        function loadBundle(gui,folder)
            targetPath=fullfile(folder,"pattern_bundle.mat");
            manifestPath=fullfile(folder,"trial_manifest.mat");
            if ~isfile(targetPath) || ~isfile(manifestPath)
                error("adaptive_optopatch:InvalidPlanningBundle", ...
                    "The folder must contain pattern_bundle.mat and trial_manifest.mat.");
            end
            t=load(targetPath,"targets"); m=load(manifestPath,"manifest");
            if ~isfield(t,"targets") || ~isfield(m,"manifest")
                error("adaptive_optopatch:InvalidPlanningBundle", ...
                    "The planning bundle variables could not be read.");
            end
            if any(string(m.manifest.trials.stimulation_mode)~="1p_dmd")
                error("adaptive_optopatch:WrongRunnerMode", ...
                    "This runner requires a planning bundle saved in 1p_dmd mode.");
            end
            gui.BundleFolder=folder; gui.Targets=t.targets; gui.Manifest=m.manifest;
        end

        function buildUI(gui,visible)
            gui.Figure=uifigure("Name","Adaptive Optopatch — Automated 1P Runner", ...
                "Position",[160 100 1050 690],"Visible",visible, ...
                "CloseRequestFcn",@(~,~)delete(gui));
            root=uigridlayout(gui.Figure,[3 1]);
            root.RowHeight={105,"1x",125};
            controls=uigridlayout(root,[2 7]);
            controls.ColumnWidth={145,90,145,90,150,"1x",120};
            gui.PowerOverride=uicheckbox(controls,"Text","Override OBIS power", ...
                "Value",false);
            gui.PowerMw=uieditfield(controls,"numeric","Value",0, ...
                "Limits",[0 55],"Tooltip","OBIS serial power ceiling in mW.");
            gui.VoltageOverride=uicheckbox(controls,"Text","Override pulse voltage", ...
                "Value",false);
            gui.VoltageV=uieditfield(controls,"numeric","Value",0, ...
                "Limits",[0 5],"Tooltip","Raw mod488 command on Dev1/ao2.");
            gui.ArmLive=uicheckbox(controls,"Text","ARM live 488 output", ...
                "Value",false,"FontWeight","bold");
            validate=uibutton(controls,"Text","Validate hardware", ...
                "ButtonPushedFcn",@(~,~)gui.validateHardware());
            validate.Layout.Column=7;
            gui.RunNextButton=uibutton(controls,"Text","Run next trial", ...
                "ButtonPushedFcn",@(~,~)gui.runTrials(1));
            gui.RunNextButton.Layout.Row=2; gui.RunNextButton.Layout.Column=[1 2];
            gui.RunAllButton=uibutton(controls,"Text","Run all remaining", ...
                "ButtonPushedFcn",@(~,~)gui.runTrials(0),"FontWeight","bold");
            gui.RunAllButton.Layout.Row=2; gui.RunAllButton.Layout.Column=[3 4];
            gui.StopButton=uibutton(controls,"Text","Stop after current", ...
                "ButtonPushedFcn",@(~,~)gui.requestStop(),"Enable","off");
            gui.StopButton.Layout.Row=2; gui.StopButton.Layout.Column=[5 6];
            folderLabel=uilabel(controls,"Text","Bundle: "+gui.BundleFolder, ...
                "Interpreter","none","Tooltip",gui.BundleFolder);
            folderLabel.Layout.Row=2; folderLabel.Layout.Column=7;

            gui.TrialTable=uitable(root,"ColumnName", ...
                {'Trial','Cell','Duration s','Status','Output folder'});
            gui.Status=uitextarea(root,"Editable","off", ...
                "Value",["Ready. Validate hardware before arming live output."; ...
                "DMD_Blue will be blanked and shutter488 closed after every trial."]);
        end

        function readActiveLaserPower(gui)
            try
                laser=gui.LuminosApp.getDevice("Laser_Device","name","488", ...
                    "displayWarning",false);
                gui.PowerMw.Value=1000*double(laser.SetPower);
                gui.setStatus(sprintf('Active OBIS power: %.3g mW. Override is off.\nPlanning bundle: %s', ...
                    gui.PowerMw.Value,gui.BundleFolder));
            catch exception
                gui.setStatus("Could not read active OBIS power: "+string(exception.message));
            end
        end

        function validateHardware(gui)
            try
                hardware=adaptive_optopatch.resolve_luminos_1p_hardware(gui.LuminosApp);
                profile=adaptive_optopatch.virtual_upright_1p_profile();
                [~,~,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                    hardware.daq.global_props,hardware.daq.wfm_data, ...
                    gui.Manifest.trials.pulse_schedule{1},profile);
                gui.setStatus(sprintf([ ...
                    'PASS: DMD_Blue, 488 OBIS, mod488, shutter488, and Camera 1 found.\n' ...
                    'OBIS: %s, %.3g mW. Master: %s (%s) at %.0f Hz.\n' ...
                    'Clock bridge: %s. Start triggers: %s. First trial: %d pulses, %.3f s.'], ...
                    hardware.laser_mode,1000*hardware.laser_power_w, ...
                    hardware.daq_sync.selected_master_device,summary.clock_source, ...
                    summary.sample_rate_hz,strjoin(hardware.daq_sync.clock_bridge,', '), ...
                    strjoin(hardware.daq_sync.default_trigger,', '), ...
                    summary.pulse_count,summary.duration_s));
            catch exception
                gui.showError(exception);
            end
        end

        function runTrials(gui,count)
            if gui.Busy, return; end
            if ~gui.ArmLive.Value
                uialert(gui.Figure, ...
                    "Check 'ARM live 488 output' after reviewing the mask, OBIS power, and pulse voltage.", ...
                    "Live output is not armed","Icon","warning");
                return
            end
            gui.Busy=true; gui.StopRequested=false; gui.setBusyState(true);
            cleanup=onCleanup(@()gui.setBusyState(false));
            powerW=NaN; voltage=NaN;
            if gui.PowerOverride.Value, powerW=gui.PowerMw.Value/1000; end
            if gui.VoltageOverride.Value, voltage=gui.VoltageV.Value; end
            try
                gui.setStatus("Running live 1P manifest. Use Luminos for emergency abort.");
                run=adaptive_optopatch.run_1p_manifest( ...
                    gui.Manifest,gui.Targets,gui.LuminosApp, ...
                    "OutputDirectory",gui.BundleFolder, ...
                    "Resume",true,"StopAfterTrial",count, ...
                    "LaserPowerW",powerW, ...
                    "ModulatorVoltageOverride",voltage, ...
                    "ConfirmLiveOutput",true, ...
                    "StopRequestedFcn",@()gui.StopRequested);
                gui.Manifest.trials=run.trials;
                gui.setStatus(sprintf('Runner stopped normally. %d of %d trials are complete.', ...
                    sum(ismember(string(run.trials.acquisition_status),["completed","analyzed"])), ...
                    height(run.trials)));
            catch exception
                gui.loadCheckpoint();
                gui.showError(exception);
            end
            gui.refresh();
        end

        function requestStop(gui)
            gui.StopRequested=true;
            gui.StopButton.Text="Stop requested";
            gui.StopButton.Enable="off";
            gui.setStatus("Stop requested. The current acquisition will finish and clean up normally.");
        end

        function setBusyState(gui,state)
            gui.Busy=state;
            if state
                gui.RunNextButton.Enable="off"; gui.RunAllButton.Enable="off";
                gui.StopButton.Enable="on"; gui.StopButton.Text="Stop after current";
            else
                gui.RunNextButton.Enable="on"; gui.RunAllButton.Enable="on";
                gui.StopButton.Enable="off"; gui.StopButton.Text="Stop after current";
                gui.ArmLive.Value=false;
            end
            drawnow;
        end

        function loadCheckpoint(gui)
            path=fullfile(gui.BundleFolder,"run_checkpoint.mat");
            if ~isfile(path), return; end
            saved=load(path,"run");
            if isfield(saved,"run"), gui.Manifest.trials=saved.run.trials; end
        end

        function refresh(gui)
            gui.loadCheckpoint();
            t=gui.Manifest.trials; n=height(t); data=cell(n,5);
            for k=1:n
                data(k,:)={t.trial_id(k),char(string(t.target_cell_id(k))), ...
                    round(t.acquisition_duration_s(k),3), ...
                    char(string(t.acquisition_status(k))), ...
                    char(string(t.experiment_directory(k)))};
            end
            gui.TrialTable.Data=data;
        end

        function setStatus(gui,message)
            gui.Status.Value=reshape(splitlines(string(message)),[],1);
            drawnow;
        end
        function showError(gui,exception)
            gui.setStatus("ERROR: "+string(exception.message));
            uialert(gui.Figure,exception.message,"Adaptive Optopatch runner error", ...
                "Icon","error");
        end
    end
end
