classdef GalvoCalibrationApp < handle
    %GALVOCALIBRATIONAPP Camera 1 / Chameleon calibration interface.
    properties (SetAccess=private)
        Figure
    end
    properties (Access=private)
        LuminosApp
        Axes
        Status
        PointTable
        Fields struct
        TrajectoryConfirmed
        LightConfirmed
        CurrentPlan
        CurrentResult
    end
    methods
        function gui=GalvoCalibrationApp(luminosApp,options)
            arguments
                luminosApp
                options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
            end
            gui.LuminosApp=luminosApp;
            gui.buildUI(options.Visible);
            gui.loadCameraDefaults();
            gui.preview();
        end
        function delete(gui)
            if ~isempty(gui.Figure) && isvalid(gui.Figure)
                gui.Figure.CloseRequestFcn=[];
                delete(gui.Figure);
            end
        end
    end
    methods (Access=private)
        function buildUI(gui,visible)
            gui.Fields=struct();
            gui.Figure=uifigure("Name","Adaptive Optopatch — Camera 1 Galvo Calibration", ...
                "Position",[90 70 1280 780],"Visible",visible, ...
                "CloseRequestFcn",@(~,~)delete(gui));
            root=uigridlayout(gui.Figure,[2 3]);
            root.ColumnWidth={300,"1x",410}; root.RowHeight={"1x",130};
            controls=uigridlayout(root,[18 2]);
            controls.RowHeight=repmat({27},1,18); controls.ColumnWidth={"1x",105};
            add("Center X (V)","center_x",0);
            add("Center Y (V)","center_y",0);
            add("Half range (V)","half_range",0.1);
            add("Grid size","grid_size",3);
            add("Camera rate (Hz)","frame_rate",20);
            add("Settle time (ms)","settle_ms",30);
            add("Frames / point","frames_per_point",4);
            add("Pockels (V)","pockels_v",0);
            add("Max velocity (V/s)","max_velocity",1000);
            add("Max accel. (V/s²)","max_acceleration",6e6);
            add("ROI left","roi_left",628);
            add("ROI width","roi_width",768);
            add("ROI top","roi_top",756);
            add("ROI height","roi_height",768);
            gui.TrajectoryConfirmed=uicheckbox(controls, ...
                "Text","Blocked trajectory reviewed","Value",false);
            gui.TrajectoryConfirmed.Layout.Column=[1 2];
            gui.LightConfirmed=uicheckbox(controls, ...
                "Text","ARM attenuated calibration light","Value",false);
            gui.LightConfirmed.Layout.Column=[1 2];
            previewButton=uibutton(controls,"Text","Preview trajectory", ...
                "ButtonPushedFcn",@(~,~)gui.preview());
            previewButton.Layout.Column=1;
            acquireButton=uibutton(controls,"Text","Acquire grid", ...
                "FontWeight","bold","ButtonPushedFcn",@(~,~)gui.acquire());
            acquireButton.Layout.Column=2;

            gui.Axes=uiaxes(root); gui.Axes.Layout.Column=2;
            gui.Axes.Title.String="Galvo command path";
            right=uigridlayout(root,[2 1]); right.Layout.Column=3;
            right.RowHeight={40,"1x"};
            actions=uigridlayout(right,[1 2]);
            refit=uibutton(actions,"Text","Refit edited points", ...
                "ButtonPushedFcn",@(~,~)gui.refit());
            uibutton(actions,"Text","Apply accepted calibration", ...
                "ButtonPushedFcn",@(~,~)gui.applyCalibration());
            gui.PointTable=uitable(right,"ColumnEditable", ...
                [false false false true true false true]);
            gui.Status=uitextarea(root,"Editable","off");
            gui.Status.Layout.Row=2; gui.Status.Layout.Column=[1 3];
            gui.Status.Value=["Preview the trajectory with Pockels = 0 V."; ...
                "Mechanically block the beam for the first acquisition."];

            function add(label,name,value)
                uilabel(controls,"Text",label);
                field=uieditfield(controls,"numeric","Value",value);
                gui.Fields.(name)=field;
            end
        end

        function loadCameraDefaults(gui)
            try
                cameras=gui.LuminosApp.getDevice("Camera");
                serials=arrayfun(@(c)strip(erase(string(c.cam_id),"S/N: ")),cameras);
                camera=cameras(find(serials=="001125",1));
                roi=double(camera.ROI);
                center=[roi(1)+roi(2)/2 roi(3)+roi(4)/2];
                width=min(768,double(camera.virtualSensorSize));
                left=max(0,4*round((center(1)-width/2)/4));
                top=max(0,4*round((center(2)-width/2)/4));
                gui.Fields.roi_left.Value=left; gui.Fields.roi_width.Value=width;
                gui.Fields.roi_top.Value=top; gui.Fields.roi_height.Value=width;
            catch exception
                gui.setStatus("Could not read Camera 1 ROI defaults: "+exception.message);
            end
        end

        function plan=makePlan(gui)
            plan=adaptive_optopatch.generate_galvo_calibration_waveforms( ...
                "CenterV",[gui.Fields.center_x.Value gui.Fields.center_y.Value], ...
                "HalfRangeV",gui.Fields.half_range.Value, ...
                "GridSize",gui.Fields.grid_size.Value, ...
                "CameraFrameRateHz",gui.Fields.frame_rate.Value, ...
                "SettleTimeMs",gui.Fields.settle_ms.Value, ...
                "FramesPerPoint",gui.Fields.frames_per_point.Value, ...
                "PockelsVoltage",gui.Fields.pockels_v.Value, ...
                "MaximumVelocityVPerS",gui.Fields.max_velocity.Value, ...
                "MaximumAccelerationVPerS2",gui.Fields.max_acceleration.Value);
        end

        function preview(gui)
            try
                plan=gui.makePlan(); gui.CurrentPlan=plan;
                cla(gui.Axes); plot(gui.Axes,plan.x_v,plan.y_v,"k-");
                hold(gui.Axes,"on");
                scatter(gui.Axes,plan.grid_volts(:,1),plan.grid_volts(:,2), ...
                    45,(1:size(plan.grid_volts,1))',"filled");
                hold(gui.Axes,"off"); axis(gui.Axes,"equal"); grid(gui.Axes,"on");
                xlabel(gui.Axes,"Galvo X (V)"); ylabel(gui.Axes,"Galvo Y (V)");
                gui.setStatus(sprintf([ ...
                    'PASS: %dx%d grid, %.3f s, %d samples.\\n' ...
                    'Maximum velocity %.3g V/s; acceleration %.3g V/s^2. ' ...
                    'Pockels %.3g V.'], ...
                    plan.grid_size,plan.grid_size,plan.duration_s,numel(plan.x_v), ...
                    plan.preflight.max_command_velocity_volts_per_s, ...
                    plan.preflight.max_command_acceleration_volts_per_s2, ...
                    plan.pockels_voltage));
            catch exception
                gui.showError(exception);
            end
        end

        function acquire(gui)
            try
                gui.preview();
                plan=gui.CurrentPlan;
                roi=[gui.Fields.roi_left.Value gui.Fields.roi_width.Value ...
                    gui.Fields.roi_top.Value gui.Fields.roi_height.Value];
                gui.setStatus("Calibration acquisition running. Do not change Luminos settings.");
                drawnow;
                result=adaptive_optopatch.run_galvo_calibration( ...
                    gui.LuminosApp,plan,"CameraRoi",roi, ...
                    "ConfirmTrajectoryTest",gui.TrajectoryConfirmed.Value, ...
                    "ConfirmLiveOutput",gui.LightConfirmed.Value);
                gui.CurrentResult=result;
                gui.PointTable.Data=result.points;
                gui.PointTable.ColumnEditable=[false false false true true false true];
                gui.showFitStatus();
            catch exception
                gui.showError(exception);
            end
        end

        function refit(gui)
            if isempty(gui.CurrentResult), return; end
            try
                points=gui.PointTable.Data;
                use=logical(points.use) & isfinite(points.camera_x) & isfinite(points.camera_y);
                calibration=adaptive_optopatch.fit_galvo_camera_calibration( ...
                    [points.galvo_x_v(use) points.galvo_y_v(use)], ...
                    [points.camera_x(use) points.camera_y(use)]);
                gui.CurrentResult.points=points;
                gui.CurrentResult.calibration=calibration;
                calibration_result=gui.CurrentResult; %#ok<NASGU>
                save(fullfile(gui.CurrentResult.experiment_directory, ...
                    "galvo_calibration_result.mat"),"calibration_result","-v7.3");
                gui.showFitStatus();
            catch exception
                gui.showError(exception);
            end
        end

        function applyCalibration(gui)
            if isempty(gui.CurrentResult), return; end
            try
                selection=uiconfirm(gui.Figure, ...
                    ["Replace the live Chameleon scanner transform with this " ...
                     "accepted Camera 1 calibration?"], ...
                    "Apply galvo calibration","Options",["Apply","Cancel"], ...
                    "DefaultOption","Cancel","CancelOption","Cancel");
                if ~strcmp(selection,"Apply"), return; end
                application_record= ...
                    adaptive_optopatch.apply_galvo_calibration_to_luminos( ...
                    gui.LuminosApp,gui.CurrentResult,"ConfirmApply",true); %#ok<NASGU>
                save(fullfile(gui.CurrentResult.experiment_directory, ...
                    "galvo_calibration_application.mat"), ...
                    "application_record","-v7.3");
                gui.setStatus("Accepted calibration applied to the live scanner and archived.");
            catch exception
                gui.showError(exception);
            end
        end

        function showFitStatus(gui)
            c=gui.CurrentResult.calibration;
            if isfield(c,"rmse_pixels")
                gui.setStatus(sprintf([ ...
                    'Calibration %s: %d/%d points, RMSE %.3f px, held-out RMSE %.3f px, maximum error %.3f px.\\n' ...
                    'Saved in %s'],upper(string(c.passed)), ...
                    sum(gui.CurrentResult.points.use),height(gui.CurrentResult.points), ...
                    c.rmse_pixels,c.held_out_rmse_pixels,c.maximum_error_pixels, ...
                    gui.CurrentResult.experiment_directory));
            else
                gui.setStatus("Calibration failed: "+strjoin(string(c.issues),newline));
            end
        end

        function setStatus(gui,message)
            gui.Status.Value=splitlines(string(message));
        end
        function showError(gui,exception)
            gui.setStatus("ERROR: "+string(exception.message));
            uialert(gui.Figure,exception.message,"Galvo calibration error","Icon","error");
        end
    end
end
