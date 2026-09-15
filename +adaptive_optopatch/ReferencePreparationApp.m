classdef ReferencePreparationApp < handle
    %REFERENCEPREPARATIONAPP Interactive soma annotation and target planning.
    %   This app is a view over adaptive_optopatch.AdaptiveOptopatchController.
    %   Widgets and drawpolygon objects display and edit canonical state; the
    %   controller owns it. Every interaction follows the same path: the
    %   callback asks the controller to mutate state, the controller reports
    %   the change, and the app redraws itself from getState().
    properties (SetAccess=protected)
        Figure
        Controller
    end
    properties (Access=protected)
        Axes
        RoiList
        QcTable
        Status
        Mode
        MicronsPerPixel
        SpiralRadius
        SpiralDensity
        OrangeExpansion
        DmdErosion
        Repeats
        PulseCount
        PulseDuration
        DarkIntervalMin
        DarkIntervalMax
        PreDelay
        PostDelay
        DrawRoiButton
        ToggleTargetsButton
        ToggleRoisButton
        RoiObjects = {}
        LuminosApp = []
        TargetsVisible = true
        RoisVisible = true
        DrawingSomas logical = false
        % Presentation bookkeeping: what the axes and ROI graphics currently
        % show, so a refresh only redraws what actually changed.
        RenderedCellIds string = strings(0,1)
        RenderedReferenceRevision double = -1
    end

    methods
        function app = ReferencePreparationApp(options)
            arguments
                options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
                options.LuminosApp = []
                options.Controller = []
            end
            app.LuminosApp=options.LuminosApp;
            app.Controller=options.Controller;
            if isempty(app.Controller)
                app.Controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                    "LuminosApp",options.LuminosApp);
            end
            app.buildUI(options.Visible);
            app.Controller.StateChangedFcn=@()app.refreshFromController();
            app.refreshFromController();
        end

        function delete(app)
            app.DrawingSomas=false;
            if ~isempty(app.Controller) && isvalid(app.Controller)
                app.Controller.StateChangedFcn=[];
            end
            if ~isempty(app.Figure) && isvalid(app.Figure), delete(app.Figure); end
        end

        function value=statusText(app)
            %STATUSTEXT Current status lines as one string array.
            value=app.Controller.statusText();
        end

        function fovState=saveCurrentFov(app,path)
            fovState=app.Controller.saveFov(path);
        end

        function fovState=loadFov(app,path)
            fovState=app.Controller.loadFov(path);
        end

        function setFovState(app,fovState)
            app.Controller.setFovState(fovState);
        end

        function setCellCalibration(app,cellId,commandVoltageV,notes)
            arguments
                app
                cellId (1,1) string
                commandVoltageV (1,1) double = NaN
                notes (1,1) string = ""
            end
            app.Controller.setCellCalibration(cellId,commandVoltageV,notes);
        end

        function fovState=setCellEligibility(app,cellId,options)
            arguments
                app
                cellId (1,1) string
                options.RecordingEnabled = []
                options.StimulationEnabled = []
            end
            fovState=app.Controller.setCellEligibility(cellId, ...
                "RecordingEnabled",options.RecordingEnabled, ...
                "StimulationEnabled",options.StimulationEnabled);
        end

        function configuration=sendOrangeRecordingMask(app)
            configuration=app.Controller.sendOrangeRecordingMask();
        end

        function cellId=addCanonicalRoi(app,position)
            arguments
                app
                position (:,2) double
            end
            cellId=app.Controller.addSomaPolygon(position);
        end

        function deleteCell(app,cellId)
            app.Controller.deleteCell(string(cellId));
        end

        function setCanonicalRoi(app,cellId,position)
            app.Controller.updateSomaPolygon(string(cellId),double(position));
        end

        function loadSnapshot(app,snapshotPath)
            app.Controller.loadSnapshot(string(snapshotPath));
            info=app.Controller.ReferenceInfo;
            title(app.Axes,sprintf("%s — %s snapshot", ...
                info.metadata.rig_name,info.camera_name),"Interpreter","none");
            if app.restorePlanningBundleOnSnapshotLoad()
                app.restoreLatestPlanning(info.snapshot_directory);
            end
        end
    end

    methods (Access=protected)
        % -----------------------------------------------------------------
        % Rendering: the app redraws itself from controller state.
        % -----------------------------------------------------------------
        function refreshFromController(app)
            if isempty(app.Figure) || ~isvalid(app.Figure), return; end
            app.renderState(app.Controller.getState());
        end

        function renderState(app,state)
            %RENDERSTATE Draw one controller state snapshot. Subclasses extend.
            app.refreshReferenceImage(state);
            app.refreshRoiGraphics(state);
            app.refreshCellTable(state);
            app.refreshPlanControls(state);
            app.refreshStatus(state);
        end

        function refreshReferenceImage(app,state)
            if state.fov.reference_revision==app.RenderedReferenceRevision, return; end
            app.RenderedReferenceRevision=state.fov.reference_revision;
            if isempty(app.Controller.ReferenceImage), return; end
            imagesc(app.Axes,app.Controller.ReferenceImage);
            axis(app.Axes,"image"); app.Axes.YDir="reverse";
            colormap(app.Axes,"gray"); app.applyContrast();
            % A new reference image invalidates any ROI graphics drawn on it.
            app.RenderedCellIds=strings(0,1);
        end

        function refreshRoiGraphics(app,state)
            ids=cell_ids(state);
            polygons=state.soma_polygons;
            rendered=app.RenderedCellIds;
            if isequal(ids,rendered) && numel(app.RoiObjects)==numel(polygons)
                for k=1:numel(app.RoiObjects)
                    if ~isvalid(app.RoiObjects{k}), continue; end
                    if ~isequal(app.RoiObjects{k}.Position,polygons{k})
                        app.RoiObjects{k}.Position=polygons{k};
                    end
                end
                return
            end
            appended=numel(ids)>numel(rendered) && ...
                isequal(ids(1:numel(rendered)),rendered) && ...
                numel(app.RoiObjects)==numel(rendered);
            if ~appended
                app.deleteRoiGraphics();
            end
            colors=lines(max(7,numel(ids)));
            for k=numel(app.RoiObjects)+1:numel(ids)
                roi=drawpolygon(app.Axes,"Position",polygons{k}, ...
                    "Color",colors(mod(k-1,size(colors,1))+1,:), ...
                    "Label",char(ids(k)),"LabelVisible","hover");
                addlistener(roi,"ROIMoved",@(source,~)app.roiMoved(source));
                app.RoiObjects{end+1}=roi;
            end
            app.RenderedCellIds=ids;
            app.updateRoiVisibility();
        end

        function refreshCellTable(app,state)
            n=numel(state.cells);
            items=cell_ids(state); data=cell(n,9);
            for k=1:n
                row=state.cells(k);
                % Older MATLAB releases do not accept string scalars inside
                % a uitable cell-array Data value; use character vectors.
                data(k,:)={char(row.cell_id),row.recording_enabled, ...
                    row.stimulation_enabled,row.selected_blue_voltage_v, ...
                    row.area_pixels,round(row.centroid_xy(1),1), ...
                    round(row.centroid_xy(2),1),row.edge_distance_pixels, ...
                    char(row.qc_status)};
            end
            previous=string(app.RoiList.Value);
            app.RoiList.Items=reshape(items,1,[]);
            if isscalar(previous) && any(items==previous)
                app.RoiList.Value=previous;
            end
            app.QcTable.Data=data;
            app.highlightSelection();
        end

        function refreshPlanControls(app,state)
            parameters=state.plan_parameters;
            app.Mode.Value=parameters.stimulation_mode;
            app.MicronsPerPixel.Value=parameters.microns_per_pixel;
            app.SpiralRadius.Value=parameters.spiral_radius_um;
            app.SpiralDensity.Value=parameters.spiral_density_points_per_volt;
            app.OrangeExpansion.Value=parameters.orange_expansion_pixels;
            app.DmdErosion.Value=parameters.blue_mask_adjustment_pixels;
            app.Repeats.Value=parameters.screen_repeats;
            app.PulseCount.Value=parameters.pulse_count;
            app.PulseDuration.Value=parameters.pulse_duration_ms;
            app.DarkIntervalMin.Value=parameters.dark_interval_min_ms;
            app.DarkIntervalMax.Value=parameters.dark_interval_max_ms;
            app.PreDelay.Value=parameters.pre_delay_ms;
            app.PostDelay.Value=parameters.post_delay_ms;
        end

        function refreshStatus(app,state)
            if isempty(app.Status) || ~isvalid(app.Status), return; end
            app.Status.Value=state.status;
        end

        function matchSimulatedReferenceCamera(app,referenceCamera) %#ok<INUSD>
            % Retained for subclasses; camera matching is controller-owned.
        end

        function buildUI(app,visible)
            app.Figure = uifigure("Name","Adaptive Optopatch — Reference & Targets", ...
                "Position",[80 80 1320 780],"Visible",visible);
            root = uigridlayout(app.Figure,[2 3]);
            root.RowHeight = {"1x",145}; root.ColumnWidth = {245,"1x",390};

            controls = uigridlayout(root,[23 2]); controls.Layout.Row = 1; controls.Layout.Column = 1;
            controls.RowHeight = repmat({28},1,23); controls.ColumnWidth = {"1x",90};
            b = uibutton(controls,"Text","Load Luminos snapshot…", ...
                "ButtonPushedFcn",@(~,~)app.chooseSnapshot()); b.Layout.Column = [1 2];
            b = uibutton(controls,"Text","Load saved FOV…", ...
                "ButtonPushedFcn",@(~,~)app.chooseFov()); b.Layout.Column = [1 2];
            b = uibutton(controls,"Text","Save FOV…", ...
                "ButtonPushedFcn",@(~,~)app.chooseSaveFov()); b.Layout.Column = [1 2];
            app.DrawRoiButton = uibutton(controls,"Text","Draw Polygon Soma", ...
                "ButtonPushedFcn",@(~,~)app.addRoi());
            app.DrawRoiButton.Layout.Column = [1 2];
            b = uibutton(controls,"Text","Delete selected", ...
                "ButtonPushedFcn",@(~,~)app.deleteSelected()); b.Layout.Column = [1 2];
            b = uibutton(controls,"Text","Clear all ROIs", ...
                "ButtonPushedFcn",@(~,~)app.clearRois()); b.Layout.Column = [1 2];
            uilabel(controls,"Text","Stimulation");
            app.Mode = uidropdown(controls,"Items",["2p_spiral","1p_dmd"],"Value","2p_spiral");
            uilabel(controls,"Text","µm / camera pixel");
            app.MicronsPerPixel = uieditfield(controls,"numeric","Value",0.35,"Limits",[eps Inf]);
            uilabel(controls,"Text","Spiral radius (µm)");
            app.SpiralRadius = uieditfield(controls,"numeric","Value",6,"Limits",[eps Inf]);
            uilabel(controls,"Text","Spiral density (points/V)");
            app.SpiralDensity = uieditfield(controls,"numeric","Value",10,"Limits",[eps Inf]);
            uilabel(controls,"Text","Orange expansion (px)");
            app.OrangeExpansion=uieditfield(controls,"numeric","Value",2, ...
                "Limits",[0 Inf],"RoundFractionalValues","on");
            uilabel(controls,"Text","Blue adjustment (px)");
            app.DmdErosion = uieditfield(controls,"numeric","Value",-1, ...
                "Limits",[-Inf Inf],"RoundFractionalValues","on", ...
                "Tooltip","Positive expands; negative shrinks the Blue mask.");
            uilabel(controls,"Text","Screen repeats");
            app.Repeats = uieditfield(controls,"numeric","Value",1,"Limits",[1 Inf],"RoundFractionalValues","on");
            uilabel(controls,"Text","Pulses / neuron");
            app.PulseCount = uieditfield(controls,"numeric","Value",200, ...
                "Limits",[1 Inf],"RoundFractionalValues","on");
            uilabel(controls,"Text","Pulse duration (ms)");
            app.PulseDuration = uieditfield(controls,"numeric", ...
                "Value",5,"Limits",[eps Inf]);
            uilabel(controls,"Text","Dark gap min (ms)");
            app.DarkIntervalMin = uieditfield(controls,"numeric","Value",45,"Limits",[eps Inf]);
            uilabel(controls,"Text","Dark gap max (ms)");
            app.DarkIntervalMax = uieditfield(controls,"numeric","Value",55,"Limits",[eps Inf]);
            uilabel(controls,"Text","Pre / post delay (ms)");
            delayGrid=uigridlayout(controls,[1 2]); delayGrid.Padding=0;
            app.PreDelay=uieditfield(delayGrid,"numeric","Value",100,"Limits",[0 Inf]);
            app.PostDelay=uieditfield(delayGrid,"numeric","Value",100,"Limits",[0 Inf]);
            b = uibutton(controls,"Text","Preview targets", ...
                "ButtonPushedFcn",@(~,~)app.previewTargets()); b.Layout.Column = [1 2];
            app.ToggleTargetsButton = uibutton(controls,"Text","Hide target preview", ...
                "ButtonPushedFcn",@(~,~)app.toggleTargets());
            app.ToggleTargetsButton.Layout.Column = [1 2];
            app.ToggleRoisButton = uibutton(controls,"Text","Hide ROI polygons", ...
                "ButtonPushedFcn",@(~,~)app.toggleRois());
            app.ToggleRoisButton.Layout.Column = [1 2];
            b=uibutton(controls,"Text","Send Orange recording mask", ...
                "ButtonPushedFcn",@(~,~)app.invokeOrangeMask()); b.Layout.Column=[1 2];
            if app.showPlanningBundleControl()
                b = uibutton(controls,"Text","Save planning bundle…", ...
                    "ButtonPushedFcn",@(~,~)app.savePlanningBundle(), ...
                    "FontWeight","bold"); b.Layout.Column = [1 2];
            end

            app.Axes = uiaxes(root); app.Axes.Layout.Row = 1; app.Axes.Layout.Column = 2;
            title(app.Axes,"Load a Luminos camera snapshot to begin"); axis(app.Axes,"image");
            colormap(app.Axes,"gray"); app.Axes.YDir = "reverse";

            side = uigridlayout(root,[5 1]); side.Layout.Row=1; side.Layout.Column=3;
            side.RowHeight={26,120,"1x",30,30};
            uilabel(side,"Text","Somata (select here, drag vertices in image)","FontWeight","bold");
            app.RoiList = uilistbox(side,"Items",strings(1,0), ...
                "ValueChangedFcn",@(~,~)app.highlightSelection());
            % The three per-cell decisions an experimenter makes -- record,
            % stimulate, and at what Blue voltage -- lead, so they are read
            % without scrolling past the geometry. "Blue V (1P)" is the
            % per-cell 488 nm calibration; there is no 2P equivalent, whose
            % Pockels command is protocol-owned rather than per cell.
            app.QcTable = uitable(side,"ColumnName", ...
                ["Cell ID","Record","Stim","Blue V (1P)", ...
                 "Area px","X","Y","Edge px","QC"], ...
                "ColumnEditable",[false true true true false false false false false], ...
                "CellEditCallback",@(source,event)app.qcCellEdited(source,event));

            app.Status = uitextarea(root,"Editable","off");
            app.Status.Layout.Row=2; app.Status.Layout.Column=[1 3];
            app.bindPlanControls();
        end

        function bindPlanControls(app)
            %BINDPLANCONTROLS Route every plan widget edit into the controller.
            watched={app.Mode,"stimulation_mode"; ...
                app.MicronsPerPixel,"microns_per_pixel"; ...
                app.SpiralRadius,"spiral_radius_um"; ...
                app.SpiralDensity,"spiral_density_points_per_volt"; ...
                app.OrangeExpansion,"orange_expansion_pixels"; ...
                app.DmdErosion,"blue_mask_adjustment_pixels"; ...
                app.Repeats,"screen_repeats"; ...
                app.PulseCount,"pulse_count"; ...
                app.PulseDuration,"pulse_duration_ms"; ...
                app.DarkIntervalMin,"dark_interval_min_ms"; ...
                app.DarkIntervalMax,"dark_interval_max_ms"; ...
                app.PreDelay,"pre_delay_ms"; ...
                app.PostDelay,"post_delay_ms"};
            for k=1:size(watched,1)
                name=watched{k,2};
                watched{k,1}.ValueChangedFcn= ...
                    @(source,~)app.planControlEdited(name,source.Value);
            end
        end

        function planControlEdited(app,name,value)
            try
                app.Controller.setPlanParameter(name,value);
            catch exception
                app.showError(exception);
                app.refreshPlanControls(app.Controller.getState());
            end
        end

        function chooseSnapshot(app)
            [selectedFile,selectedFolder] = uigetfile( ...
                {'*.mat','Luminos snapshot MAT (*.mat)'}, ...
                "Select Camera 1 snapshot from the Luminos Snaps folder",pwd);
            if isequal(selectedFile,0), return; end
            snapshotPath=string(fullfile(selectedFolder,selectedFile));
            app.setStatus("Loading Luminos Camera 1 snapshot…"); drawnow;
            try
                app.loadSnapshot(snapshotPath);
            catch exception
                app.showError(exception);
            end
        end

        function chooseFov(app)
            if ~isempty(app.RoiObjects)
                choice=uiconfirm(app.Figure, ...
                    "Loading a saved FOV replaces the currently displayed ROIs. Continue?", ...
                    "Load saved FOV","Options",["Load FOV","Cancel"], ...
                    "DefaultOption","Cancel","CancelOption","Cancel");
                if choice~="Load FOV", return; end
            end
            [file,folder]=uigetfile(adaptive_optopatch.fov_file_dialog_filter(), ...
                "Load persistent Adaptive Optopatch FOV",pwd);
            if isequal(file,0), return; end
            try
                app.loadFov(string(fullfile(folder,file)));
            catch exception
                app.showError(exception);
            end
        end

        function chooseSaveFov(app)
            info=app.Controller.ReferenceInfo;
            if isempty(info), app.setStatus("Load a snapshot before saving an FOV."); return; end
            suggested=string(info.snapshot_name)+"_fov_state.mat";
            [file,folder]=uiputfile(adaptive_optopatch.fov_file_dialog_filter(), ...
                "Save persistent Adaptive Optopatch FOV",char(suggested));
            if isequal(file,0), return; end
            try
                app.saveCurrentFov(string(fullfile(folder,file)));
                app.setStatus("Saved persistent FOV: "+string(fullfile(folder,file)));
            catch exception
                app.showError(exception);
            end
        end

        function applyContrast(app)
            values=double(app.Controller.ReferenceImage(:));
            values=values(isfinite(values));
            if isempty(values), return; end
            limits=prctile(values,[1 99.8]);
            if limits(2)>limits(1), app.Axes.CLim=limits; end
        end

        function addRoi(app)
            if isempty(app.Controller.ReferenceImage)
                uialert(app.Figure,"Load a Luminos snapshot first.","No reference image");
                return
            end
            if app.DrawingSomas, return; end
            app.DrawingSomas=true;
            cleanup=onCleanup(@()app.finishSomaDrawing());
            app.DrawRoiButton.Text="Drawing Soma ROIs...";
            app.DrawRoiButton.Enable="off";
            app.RoisVisible=true;
            app.updateRoiVisibility();
            try
                count=adaptive_optopatch.draw_soma_rois_until_empty( ...
                    @()app.drawSomaPolygon(),@(position)app.commitDrawnSoma(position), ...
                    @()app.somaDrawingCanContinue());
                if app.somaDrawingCanContinue()
                    app.setStatus(sprintf(["Soma drawing finished after %d new ROI(s). " ...
                        "Previously committed ROIs were preserved."],count));
                end
            catch exception
                if app.somaDrawingCanContinue(), app.showError(exception); end
            end
            clear cleanup
        end

        function position=drawSomaPolygon(app)
            % The in-progress polygon is transient interaction state. Only
            % its final vertices reach the controller; the temporary
            % graphics object is discarded either way.
            position=zeros(0,2);
            colors=lines(max(7,numel(app.RoiObjects)+1));
            index=numel(app.RoiObjects)+1;
            roi=drawpolygon(app.Axes, ...
                "Color",colors(mod(index-1,size(colors,1))+1,:));
            if isempty(roi) || ~isvalid(roi), return; end
            position=double(roi.Position);
            delete(roi);
        end

        function commitDrawnSoma(app,position)
            app.Controller.addSomaPolygon(position);
            if isempty(app.RoiList.Items), return; end
            app.RoiList.Value=string(app.RoiList.Items(end));
            app.highlightSelection();
        end

        function value=somaDrawingCanContinue(app)
            value=app.DrawingSomas && ~isempty(app.Figure) && isvalid(app.Figure);
        end

        function finishSomaDrawing(app)
            app.DrawingSomas=false;
            if isempty(app.DrawRoiButton) || ~isvalid(app.DrawRoiButton), return; end
            app.DrawRoiButton.Text="Draw Polygon Soma";
            app.DrawRoiButton.Enable="on";
        end

        function roiMoved(app,source)
            %ROIMOVED Send an edited polygon's vertices to the controller.
            index=find(cellfun(@(roi)isequal(roi,source),app.RoiObjects),1);
            if isempty(index) || index>numel(app.RenderedCellIds), return; end
            try
                app.Controller.updateSomaPolygon( ...
                    app.RenderedCellIds(index),double(source.Position));
            catch exception
                app.showError(exception);
                app.RenderedCellIds=strings(0,1);
                app.refreshFromController();
            end
        end

        function deleteSelected(app)
            index=app.selectedRoiIndex();
            if isempty(index) || index>numel(app.RenderedCellIds), return; end
            try
                app.Controller.deleteCell(app.RenderedCellIds(index));
            catch exception
                app.showError(exception);
            end
        end

        function clearRois(app)
            try
                app.Controller.clearSomata();
            catch exception
                app.showError(exception);
                return
            end
            app.RoisVisible=true; app.updateRoiVisibility();
            app.deletePreview();
        end

        function deleteRoiGraphics(app)
            for k=1:numel(app.RoiObjects)
                if isvalid(app.RoiObjects{k}), delete(app.RoiObjects{k}); end
            end
            app.RoiObjects={}; app.RenderedCellIds=strings(0,1);
        end

        function highlightSelection(app)
            selected=app.selectedRoiIndex();
            for k=1:numel(app.RoiObjects)
                if ~isvalid(app.RoiObjects{k}), continue; end
                app.RoiObjects{k}.LineWidth=1;
                if k==selected, app.RoiObjects{k}.LineWidth=3; end
            end
        end

        function index=selectedRoiIndex(app)
            %SELECTEDROIINDEX Row of the highlighted soma, or empty.
            index=[];
            items=string(app.RoiList.Items); value=string(app.RoiList.Value);
            if isempty(items) || ~isscalar(value), return; end
            index=find(items==value,1);
        end

        function restoreLatestPlanning(app,searchFolder)
            info=app.Controller.ReferenceInfo;
            bundle=adaptive_optopatch.find_latest_planning_bundle(searchFolder, ...
                "ExperimentDirectory",info.snapshot_directory, ...
                "SourceSnapshot",info.snapshot_path);
            if isempty(bundle), return; end
            loaded=load(bundle.session_path,"planning_session");
            if ~isfield(loaded,"planning_session"), return; end
            session=loaded.planning_session;
            if ~isfield(session,"image_size") || ...
                    any(double(session.image_size)~=size(app.Controller.ReferenceImage)) || ...
                    ~isfield(session,"roi_positions") || ...
                    ~isfield(session,"parameters")
                return
            end
            positions=session.roi_positions;
            app.Controller.setSomaPolygons(positions);
            if ~isempty(fieldnames(session.parameters))
                app.Controller.setPlanParameters(session.parameters);
            end
            app.planningSessionRestored(session);
            app.setStatus(sprintf(['Loaded %s\nRestored %d polygon ROIs and ' ...
                'experimental parameters from latest planning bundle:\n%s'], ...
                info.snapshot_path,numel(positions),bundle.folder));
        end

        function previewTargets(app)
            try
                % Only spatial artifacts are needed here: the preview draws
                % resolved acquisitions when a protocol is loaded, and the
                % bundle's own defaults otherwise.
                [~,targets]=app.Controller.buildSpatialArtifacts( ...
                    "PulseDurationMs",app.Controller.currentPulseDurationMs());
                mode=app.Controller.PlanParameters.stimulation_mode;
                preview=adaptive_optopatch.build_target_preview(targets,mode, ...
                    "ResolvedProtocols",app.Controller.resolvedProtocolsForPreview(), ...
                    "ScannerTransform",preview_scanner_transform(targets), ...
                    "ScannerSampleRateHz",targets.parameters.scanner_sample_rate_hz);
                app.deletePreview(); hold(app.Axes,"on");
                theta=linspace(0,2*pi,100);
                for k=1:numel(preview.orange)
                    plot_boundaries(app.Axes,preview.orange(k).mask,[1 0.45 0]);
                end
                for k=1:numel(preview.blue)
                    plot_boundaries(app.Axes,preview.blue(k).mask,[0 1 1]);
                end
                for k=1:numel(preview.spiral)
                    s=preview.spiral(k);
                    c=s.center_xy; r=s.radius_pixels;
                    plot(app.Axes,c(1)+r*cos(theta),c(2)+r*sin(theta),"c--", ...
                        "LineWidth",1.2,"Tag","TargetPreview");
                    spiral=adaptive_optopatch.generate_spiral_preview(c,r, ...
                        s.density_points_per_volt);
                    plot(app.Axes,spiral(:,1),spiral(:,2),"c-", ...
                        "LineWidth",1.1,"Tag","TargetPreview");
                    park=s.parking_xy;
                    plot(app.Axes,park(1),park(2),"mo","MarkerFaceColor","m", ...
                        "MarkerSize",7,"Tag","TargetPreview");
                    plot(app.Axes,[c(1) park(1)],[c(2) park(2)],"m--", ...
                        "LineWidth",1,"Tag","TargetPreview");
                end
                hold(app.Axes,"off");
                app.TargetsVisible=true;
                app.updateTargetVisibility();
                app.Controller.setStatus(preview_status(preview,mode, ...
                    app.Controller.ScannerWarning));
            catch exception
                app.showError(exception);
            end
        end

        function deletePreview(app)
            if isempty(app.Axes) || ~isvalid(app.Axes), return; end
            delete(findobj(app.Axes,"Tag","TargetPreview"));
            app.TargetsVisible=true;
            app.updateTargetVisibility();
        end

        function toggleTargets(app)
            overlays=findobj(app.Axes,"Tag","TargetPreview");
            if isempty(overlays)
                app.setStatus("No target preview is currently displayed. Click Preview targets first.");
                return
            end
            app.TargetsVisible=~app.TargetsVisible;
            app.updateTargetVisibility();
        end

        function updateTargetVisibility(app)
            if isempty(app.ToggleTargetsButton) || ~isvalid(app.ToggleTargetsButton), return; end
            overlays=findobj(app.Axes,"Tag","TargetPreview");
            visibility=ternary(app.TargetsVisible,'on','off');
            for k=1:numel(overlays), overlays(k).Visible=visibility; end
            app.ToggleTargetsButton.Text=ternary(app.TargetsVisible, ...
                'Hide target preview','Show target preview');
        end

        function toggleRois(app)
            if isempty(app.RoiObjects)
                app.setStatus("No ROI polygons are currently displayed.");
                return
            end
            app.RoisVisible=~app.RoisVisible;
            app.updateRoiVisibility();
        end

        function updateRoiVisibility(app)
            if isempty(app.ToggleRoisButton) || ~isvalid(app.ToggleRoisButton), return; end
            visibility=ternary(app.RoisVisible,'on','off');
            for k=1:numel(app.RoiObjects)
                if isvalid(app.RoiObjects{k}), app.RoiObjects{k}.Visible=visibility; end
            end
            app.ToggleRoisButton.Text=ternary(app.RoisVisible, ...
                'Hide ROI polygons','Show ROI polygons');
        end

        function savePlanningBundle(app)
            try
                [reference,targets,manifest]=app.Controller.buildScreenPlanningArtifacts();
                session=app.Controller.buildSessionState();
                paths=adaptive_optopatch.save_bundle( ...
                    app.Controller.ReferenceInfo.snapshot_directory, ...
                    reference,targets,manifest, ...
                    "CreateSubfolder",true,"SessionState",session);
                app.setStatus(sprintf("Created planning folder:\n%s\n\nSaved:\n%s\n%s\n%s\n%s\n\n%d acquisitions planned (%s).", ...
                    paths.output_directory,paths.reference,paths.targets,paths.manifest,paths.session, ...
                    height(manifest.trials), ...
                    app.Controller.PlanParameters.stimulation_mode));
            catch exception
                app.showError(exception);
            end
        end

        function invokeOrangeMask(app)
            try
                app.sendOrangeRecordingMask();
            catch exception
                app.showError(exception);
            end
        end

        function qcCellEdited(app,source,event)
            row=event.Indices(1); column=event.Indices(2);
            if row<1 || row>numel(app.RenderedCellIds) || ~ismember(column,[2 3 4])
                app.refreshFromController();
                return
            end
            try
                cellId=app.RenderedCellIds(row);
                if column==2
                    app.Controller.setCellEligibility(cellId, ...
                        "RecordingEnabled",logical(event.NewData));
                elseif column==3
                    app.Controller.setCellEligibility(cellId, ...
                        "StimulationEnabled",logical(event.NewData));
                else
                    app.Controller.setCellBlueVoltage(cellId,event.NewData);
                end
                if column==4
                    app.setStatus(sprintf( ...
                        "%s Blue V updated. Save the FOV to persist it.",cellId));
                else
                    app.setStatus(sprintf( ...
                        "%s %s eligibility updated. Save the FOV to persist it.", ...
                        cellId,lower(string(source.ColumnName(column)))));
                end
            catch exception
                app.refreshFromController();
                app.showError(exception);
            end
        end

        function setStatus(app,message), app.Controller.setStatus(message); end

        function showError(app,exception)
            app.Controller.setStatus("ERROR: "+string(exception.message));
            if app.Figure.Visible=="on"
                uialert(app.Figure,exception.message,"Adaptive Optopatch error","Icon","error");
            end
        end

        function planningSessionRestored(~,~)
            % Subclasses can restore additional planning-session state.
        end

        function value=showPlanningBundleControl(~)
            value=true;
        end

        function value=restorePlanningBundleOnSnapshotLoad(~)
            value=true;
        end
    end
end

function ids=cell_ids(state)
if isempty(state.cells), ids=strings(0,1); return; end
ids=reshape(string({state.cells.cell_id}),[],1);
end

function transform=preview_scanner_transform(targets)
%PREVIEW_SCANNER_TRANSFORM Transform used for spiral cycle metrics.
transform=[];
if isfield(targets,"scanner_transform")
    transform=targets.scanner_transform;
end
end

function value=ternary(condition,yes,no)
if condition, value=yes; else, value=no; end
end

function plot_boundaries(axesHandle,mask,color)
boundaries=bwboundaries(mask);
for j=1:numel(boundaries)
    p=boundaries{j};
    plot(axesHandle,p(:,2),p(:,1),"-","Color",color,"LineWidth",1.5, ...
        "Tag","TargetPreview");
end
end

function lines=preview_status(preview,mode,scannerWarning)
if preview.source=="resolved_plan"
    origin="resolved acquisition values";
else
    origin="bundle default values";
end
if mode~="2p_spiral"
    lines=["Target preview updated from "+origin+". ROI polygons are canonical;";
        "orange = expanded recording illumination; cyan = Blue stimulation masks."];
    if ~isempty(preview.blue)
        adjustments=unique([preview.blue.adjustment_pixels],"stable");
        lines(end+1,1)="Blue mask adjustment(s): "+ ...
            strjoin(string(adjustments),", ")+" px.";
    end
    if ~isempty(preview.orange)
        lines(end+1,1)="Orange expansion: "+ ...
            strjoin(unique(string([preview.orange.expansion_pixels]),"stable"),", ")+" px.";
    end
    return
end
lines=["Cyan = double-spiral preview; magenta = automatic off-cell parking " + ...
    "point and dark transition.";"Drawn from "+origin+"."];
if strlength(scannerWarning)>0
    lines(end+1,1)="WARNING: "+scannerWarning;
end
for k=1:numel(preview.spiral)
    s=preview.spiral(k); m=s.cycle_metrics;
    if isfield(m,"calibrated") && m.calibrated
        lines(end+1,1)=sprintf(['%s: radius %.3g px, density %.3g points/V, ' ...
            'pulse %.3g ms; %.3f cycles during pulse (%d complete; %d started), ' ...
            '%.3f ms/cycle.'],char(s.cell_id),s.radius_pixels, ...
            s.density_points_per_volt,s.pulse_duration_ms, ...
            m.fractional_cycles_during_pulse,m.complete_cycles_during_pulse, ...
            m.cycles_started_during_pulse,m.cycle_duration_ms); %#ok<AGROW>
    else
        lines(end+1,1)=sprintf(['%s: radius %.3g px, density %.3g points/V, ' ...
            'pulse %.3g ms; exact spirals/pulse pending a nonidentity ' ...
            'scanner calibration.'],char(s.cell_id),s.radius_pixels, ...
            s.density_points_per_volt,s.pulse_duration_ms); %#ok<AGROW>
    end
end
end
