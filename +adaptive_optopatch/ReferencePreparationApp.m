classdef ReferencePreparationApp < handle
    %REFERENCEPREPARATIONAPP Interactive soma annotation and target planning.
    properties (SetAccess=private)
        Figure
    end
    properties (Access=private)
        Axes
        RoiList
        QcTable
        Status
        Mode
        MicronsPerPixel
        SpiralRadius
        SpiralDensity
        DmdErosion
        Repeats
        PulseCount
        PulseDuration
        DarkIntervalMin
        DarkIntervalMax
        ModulatorVoltage
        PreDelay
        PostDelay
        ToggleTargetsButton
        ToggleRoisButton
        ReferenceImage = []
        LoadInfo = struct([])
        RoiObjects = {}
        LuminosApp = []
        ScannerWarning = ""
        TargetsVisible = true
        RoisVisible = true
    end

    methods
        function app = ReferencePreparationApp(options)
            arguments
                options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
                options.LuminosApp = []
            end
            app.LuminosApp=options.LuminosApp;
            app.buildUI(options.Visible);
        end

        function delete(app)
            if ~isempty(app.Figure) && isvalid(app.Figure), delete(app.Figure); end
        end
    end

    methods (Access=private)
        function buildUI(app,visible)
            app.Figure = uifigure("Name","Adaptive Optopatch — Reference & Targets", ...
                "Position",[80 80 1320 780],"Visible",visible);
            root = uigridlayout(app.Figure,[2 3]);
            root.RowHeight = {"1x",145}; root.ColumnWidth = {245,"1x",390};

            controls = uigridlayout(root,[20 2]); controls.Layout.Row = 1; controls.Layout.Column = 1;
            controls.RowHeight = repmat({28},1,20); controls.ColumnWidth = {"1x",90};
            b = uibutton(controls,"Text","Load Luminos snapshot…", ...
                "ButtonPushedFcn",@(~,~)app.chooseSnapshot()); b.Layout.Column = [1 2];
            b = uibutton(controls,"Text","Add polygon soma", ...
                "ButtonPushedFcn",@(~,~)app.addRoi()); b.Layout.Column = [1 2];
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
            uilabel(controls,"Text","DMD erosion (+ shrink)");
            app.DmdErosion = uieditfield(controls,"numeric","Value",1, ...
                "Limits",[-Inf Inf],"RoundFractionalValues","on", ...
                "Tooltip","Positive shrinks the mask; negative expands it.");
            uilabel(controls,"Text","Screen repeats");
            app.Repeats = uieditfield(controls,"numeric","Value",1,"Limits",[1 Inf],"RoundFractionalValues","on");
            uilabel(controls,"Text","Pulses / neuron");
            app.PulseCount = uieditfield(controls,"numeric","Value",200, ...
                "Limits",[1 Inf],"RoundFractionalValues","on");
            uilabel(controls,"Text","Pulse duration (ms)");
            app.PulseDuration = uieditfield(controls,"numeric","Value",5,"Limits",[5 10]);
            uilabel(controls,"Text","Dark gap min (ms)");
            app.DarkIntervalMin = uieditfield(controls,"numeric","Value",45,"Limits",[eps Inf]);
            uilabel(controls,"Text","Dark gap max (ms)");
            app.DarkIntervalMax = uieditfield(controls,"numeric","Value",55,"Limits",[eps Inf]);
            uilabel(controls,"Text","Pulse command (V)", ...
                "Tooltip","2P mod for spirals; mod488 for 1P DMD stimulation.");
            app.ModulatorVoltage = uieditfield(controls,"numeric","Value",0,"Limits",[0 5]);
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
            b = uibutton(controls,"Text","Save planning bundle…", ...
                "ButtonPushedFcn",@(~,~)app.savePlanningBundle(),"FontWeight","bold"); b.Layout.Column = [1 2];

            app.Axes = uiaxes(root); app.Axes.Layout.Row = 1; app.Axes.Layout.Column = 2;
            title(app.Axes,"Load a Luminos camera snapshot to begin"); axis(app.Axes,"image");
            colormap(app.Axes,"gray"); app.Axes.YDir = "reverse";

            side = uigridlayout(root,[3 1]); side.Layout.Row=1; side.Layout.Column=3;
            side.RowHeight={26,150,"1x"};
            uilabel(side,"Text","Somata (select here, drag vertices in image)","FontWeight","bold");
            app.RoiList = uilistbox(side,"Items",strings(1,0), ...
                "ValueChangedFcn",@(~,~)app.highlightSelection());
            app.QcTable = uitable(side,"ColumnName", ...
                ["Cell","Area px","X","Y","Edge px","QC"]);

            app.Status = uitextarea(root,"Editable","off", ...
                "Value",["Ready. In Luminos, click Snap for Camera 1."; ...
                         "Then load its MAT file from the Luminos Snaps folder."]);
            app.Status.Layout.Row=2; app.Status.Layout.Column=[1 3];
        end

        function chooseSnapshot(app)
            [selectedFile,selectedFolder] = uigetfile( ...
                {"*.mat","Luminos snapshot MAT (*.mat)"}, ...
                "Select Camera 1 snapshot from the Luminos Snaps folder",pwd);
            if isequal(selectedFile,0), return; end
            snapshotPath=string(fullfile(selectedFolder,selectedFile));
            app.setStatus("Loading Luminos Camera 1 snapshot…"); drawnow;
            try
                [image,info] = adaptive_optopatch.read_reference_snapshot(snapshotPath);
                app.ReferenceImage=image; app.LoadInfo=info; app.clearRois();
                imagesc(app.Axes,image); axis(app.Axes,"image"); app.Axes.YDir="reverse";
                colormap(app.Axes,"gray"); app.applyContrast();
                title(app.Axes,sprintf("%s — %s snapshot", ...
                    info.metadata.rig_name,info.camera_name), ...
                    "Interpreter","none");
                app.setStatus(sprintf(["Loaded snapshot:\n%s\nCamera: %s, " ...
                    "%d × %d pixels, binning %.3g."], ...
                    info.snapshot_path,info.camera_name, ...
                    info.image_size(2),info.image_size(1),info.camera_bin));
                app.restoreLatestPlanning(info.snapshot_directory);
            catch exception
                app.showError(exception);
            end
        end

        function applyContrast(app)
            values=double(app.ReferenceImage(:)); values=values(isfinite(values));
            if isempty(values), return; end
            limits=prctile(values,[1 99.8]);
            if limits(2)>limits(1), app.Axes.CLim=limits; end
        end

        function addRoi(app)
            if isempty(app.ReferenceImage), uialert(app.Figure,"Load a Luminos snapshot first.","No reference image"); return; end
            app.RoisVisible=true;
            app.updateRoiVisibility();
            colors=lines(max(7,numel(app.RoiObjects)+1)); idx=numel(app.RoiObjects)+1;
            try
                roi=drawpolygon(app.Axes,"Color",colors(mod(idx-1,size(colors,1))+1,:), ...
                    "Label",sprintf("%d",idx),"LabelVisible","hover");
                if isempty(roi.Position) || size(roi.Position,1)<3, delete(roi); return; end
                addlistener(roi,"ROIMoved",@(~,~)app.updateQc());
                app.RoiObjects{end+1}=roi; app.updateQc();
                app.RoiList.Value=string(app.RoiList.Items(end)); app.highlightSelection();
            catch exception
                app.showError(exception);
            end
        end

        function deleteSelected(app)
            if isempty(app.RoiObjects) || isempty(app.RoiList.Value), return; end
            idx=find(strcmp(app.RoiList.Items,app.RoiList.Value),1);
            if isempty(idx), return; end
            if isvalid(app.RoiObjects{idx}), delete(app.RoiObjects{idx}); end
            app.RoiObjects(idx)=[]; app.renumberRois(); app.updateQc();
        end

        function clearRois(app)
            for k=1:numel(app.RoiObjects)
                if isvalid(app.RoiObjects{k}), delete(app.RoiObjects{k}); end
            end
            app.RoiObjects={}; app.RoiList.Items=strings(1,0); app.QcTable.Data=cell(0,6);
            app.RoisVisible=true; app.updateRoiVisibility();
            app.deletePreview();
        end

        function renumberRois(app)
            for k=1:numel(app.RoiObjects), app.RoiObjects{k}.Label=sprintf("%d",k); end
        end

        function highlightSelection(app)
            selected=find(strcmp(app.RoiList.Items,app.RoiList.Value),1);
            for k=1:numel(app.RoiObjects)
                app.RoiObjects{k}.LineWidth=1;
                if k==selected, app.RoiObjects{k}.LineWidth=3; end
            end
        end

        function masks = makeMasks(app)
            masks=false([size(app.ReferenceImage) numel(app.RoiObjects)]);
            for k=1:numel(app.RoiObjects)
                p=app.RoiObjects{k}.Position;
                masks(:,:,k)=poly2mask(p(:,1),p(:,2),size(masks,1),size(masks,2));
            end
        end

        function updateQc(app)
            n=numel(app.RoiObjects); items=compose("cell_%03d",1:n); data=cell(n,6);
            if n==0, app.RoiList.Items=strings(1,0); app.QcTable.Data=data; return; end
            masks=app.makeMasks(); overlap=sum(masks,3)>1;
            for k=1:n
                [y,x]=find(masks(:,:,k));
                if isempty(x)
                    area=0; cx=NaN; cy=NaN; edge=-1;
                else
                    area=numel(x); cx=mean(x); cy=mean(y);
                    edge=min([min(x)-1,size(masks,2)-max(x),min(y)-1,size(masks,1)-max(y)]);
                end
                pass=area>0 && edge>=2 && ~any(overlap & masks(:,:,k),"all");
                % Older MATLAB releases do not accept string scalars inside
                % a uitable cell-array Data value; use character vectors.
                data(k,:)={char(items(k)),area,round(cx,1),round(cy,1),edge, ...
                    ternary(pass,'PASS','CHECK')};
            end
            previous=string(app.RoiList.Value); app.RoiList.Items=reshape(items,1,[]);
            if ~isempty(previous) && any(strcmp(items,previous)), app.RoiList.Value=previous; end
            app.QcTable.Data=data;
        end

        function [reference,targets,manifest]=buildArtifacts(app)
            if isempty(app.ReferenceImage) || isempty(app.RoiObjects)
                error("adaptive_optopatch:NothingToSave","Load an image and draw at least one soma ROI.");
            end
            masks=app.makeMasks();
            fovId=string(matlab.lang.makeValidName(char(app.LoadInfo.snapshot_name)));
            reference=adaptive_optopatch.create_reference_model(app.ReferenceImage,masks, ...
                app.LoadInfo.metadata,"MicronsPerPixel",app.MicronsPerPixel.Value, ...
                "FovId",string(fovId),"SourceExperiment",app.LoadInfo.snapshot_directory);
            reference.source_snapshot=app.LoadInfo.snapshot_path;
            if ~isempty(app.LuminosApp)
                reference.luminos_settings_snapshot= ...
                    adaptive_optopatch.snapshot_luminos_settings(app.LuminosApp);
            else
                reference.luminos_settings_snapshot=struct([]);
            end
            [liveScanner,app.ScannerWarning]= ...
                adaptive_optopatch.get_live_scanner_calibration(app.LuminosApp);
            scannerSampleRate=200000;
            if ~isempty(liveScanner)
                reference.scanner=liveScanner;
                scannerSampleRate=liveScanner.sample_rate;
            elseif isfield(reference,"scanner") && isfield(reference.scanner,"raw_archive") && ...
                    isfield(reference.scanner.raw_archive,"sample_rate")
                scannerSampleRate=double(reference.scanner.raw_archive.sample_rate);
            end
            targets=adaptive_optopatch.build_target_bundle(reference, ...
                "SpiralRadiusUm",app.SpiralRadius.Value, ...
                "SpiralDensityPointsPerVolt",app.SpiralDensity.Value, ...
                "PulseDurationMs",app.PulseDuration.Value, ...
                "ScannerSampleRateHz",scannerSampleRate, ...
                "DmdErosionPixels",app.DmdErosion.Value);
            manifest=adaptive_optopatch.build_screen_manifest(reference,targets, ...
                "Mode",string(app.Mode.Value),"Repeats",app.Repeats.Value, ...
                "NullFraction",0, ...
                "PulseCount",app.PulseCount.Value, ...
                "PulseDurationMs",app.PulseDuration.Value, ...
                "DarkIntervalMs",[app.DarkIntervalMin.Value app.DarkIntervalMax.Value], ...
                "PreDelayMs",app.PreDelay.Value,"PostDelayMs",app.PostDelay.Value, ...
                "ModulatorVoltage",app.ModulatorVoltage.Value);
        end

        function session=buildSessionState(app)
            session=struct;
            session.schema_version="0.3.0";
            session.created_at=string(datetime("now","TimeZone","local"));
            session.source_directory=app.LoadInfo.snapshot_directory;
            session.source_snapshot=app.LoadInfo.snapshot_path;
            session.image_size=size(app.ReferenceImage);
            session.roi_positions=cell(numel(app.RoiObjects),1);
            for k=1:numel(app.RoiObjects)
                session.roi_positions{k}=app.RoiObjects{k}.Position;
            end
            session.parameters=struct( ...
                "stimulation_mode",string(app.Mode.Value), ...
                "microns_per_pixel",app.MicronsPerPixel.Value, ...
                "spiral_radius_um",app.SpiralRadius.Value, ...
                "spiral_density_points_per_volt",app.SpiralDensity.Value, ...
                "dmd_erosion_pixels",app.DmdErosion.Value, ...
                "screen_repeats",app.Repeats.Value, ...
                "pulse_count",app.PulseCount.Value, ...
                "pulse_duration_ms",app.PulseDuration.Value, ...
                "dark_interval_min_ms",app.DarkIntervalMin.Value, ...
                "dark_interval_max_ms",app.DarkIntervalMax.Value, ...
                "modulator_voltage",app.ModulatorVoltage.Value, ...
                "pre_delay_ms",app.PreDelay.Value, ...
                "post_delay_ms",app.PostDelay.Value);
        end

        function restoreLatestPlanning(app,searchFolder)
            bundle=adaptive_optopatch.find_latest_planning_bundle(searchFolder, ...
                "ExperimentDirectory",app.LoadInfo.snapshot_directory, ...
                "SourceSnapshot",app.LoadInfo.snapshot_path);
            if isempty(bundle), return; end
            loaded=load(bundle.session_path,"planning_session");
            if ~isfield(loaded,"planning_session"), return; end
            session=loaded.planning_session;
            if ~isfield(session,"image_size") || ...
                    any(double(session.image_size)~=size(app.ReferenceImage)) || ...
                    ~isfield(session,"roi_positions") || ...
                    ~isfield(session,"parameters")
                return
            end
            positions=session.roi_positions;
            parameters=session.parameters;
            app.restorePolygons(positions);
            app.applyParameters(parameters);
            app.setStatus(sprintf(['Loaded %s\nRestored %d polygon ROIs and ' ...
                'experimental parameters from latest planning bundle:\n%s'], ...
                app.LoadInfo.snapshot_path,numel(positions),bundle.folder));
        end

        function restorePolygons(app,positions)
            app.clearRois();
            colors=lines(max(7,numel(positions)));
            for k=1:numel(positions)
                p=positions{k};
                if isempty(p) || size(p,2)~=2, continue; end
                roi=drawpolygon(app.Axes,"Position",p, ...
                    "Color",colors(mod(k-1,size(colors,1))+1,:), ...
                    "Label",sprintf("%d",k),"LabelVisible","hover");
                addlistener(roi,"ROIMoved",@(~,~)app.updateQc());
                app.RoiObjects{end+1}=roi;
            end
            app.updateQc();
            app.RoisVisible=true;
            app.updateRoiVisibility();
        end

        function applyParameters(app,p)
            if isempty(fieldnames(p)), return; end
            set_if_present(app.Mode,p,"stimulation_mode");
            set_if_present(app.MicronsPerPixel,p,"microns_per_pixel");
            set_if_present(app.SpiralRadius,p,"spiral_radius_um");
            set_if_present(app.SpiralDensity,p,"spiral_density_points_per_volt");
            set_if_present(app.DmdErosion,p,"dmd_erosion_pixels");
            set_if_present(app.Repeats,p,"screen_repeats");
            set_if_present(app.PulseCount,p,"pulse_count");
            set_if_present(app.PulseDuration,p,"pulse_duration_ms");
            set_if_present(app.DarkIntervalMin,p,"dark_interval_min_ms");
            set_if_present(app.DarkIntervalMax,p,"dark_interval_max_ms");
            set_if_present(app.ModulatorVoltage,p,"modulator_voltage");
            set_if_present(app.PreDelay,p,"pre_delay_ms");
            set_if_present(app.PostDelay,p,"post_delay_ms");
        end

        function previewTargets(app)
            try
                [~,targets,~]=app.buildArtifacts(); app.deletePreview(); hold(app.Axes,"on");
                theta=linspace(0,2*pi,100);
                for k=1:numel(targets.targets)
                    if app.Mode.Value=="2p_spiral"
                        c=targets.targets(k).spiral_center_xy; r=targets.targets(k).spiral_radius_pixels;
                        plot(app.Axes,c(1)+r*cos(theta),c(2)+r*sin(theta),"c--", ...
                            "LineWidth",1.2,"Tag","TargetPreview");
                        spiral=adaptive_optopatch.generate_spiral_preview(c,r, ...
                            targets.targets(k).spiral_density_points_per_volt);
                        plot(app.Axes,spiral(:,1),spiral(:,2),"c-", ...
                            "LineWidth",1.1,"Tag","TargetPreview");
                        park=targets.targets(k).parking_point_xy;
                        plot(app.Axes,park(1),park(2),"mo","MarkerFaceColor","m", ...
                            "MarkerSize",7,"Tag","TargetPreview");
                        plot(app.Axes,[c(1) park(1)],[c(2) park(2)],"m--", ...
                            "LineWidth",1,"Tag","TargetPreview");
                    else
                        boundaries=bwboundaries(targets.dmd_camera_masks(:,:,k));
                        for j=1:numel(boundaries)
                            p=boundaries{j}; plot(app.Axes,p(:,2),p(:,1),"y-","LineWidth",1.5,"Tag","TargetPreview");
                        end
                    end
                end
                hold(app.Axes,"off");
                app.TargetsVisible=true;
                app.updateTargetVisibility();
                if app.Mode.Value=="2p_spiral"
                    warningLines=double(strlength(app.ScannerWarning)>0);
                    lines=strings(numel(targets.targets)+2+warningLines,1);
                    lines(1)=sprintf(['Cyan = double-spiral preview; magenta = automatic ' ...
                        'off-cell parking point and dark transition.']);
                    lines(2)=sprintf('Pulse duration %.3g ms; density %.3g points/V.', ...
                        app.PulseDuration.Value,app.SpiralDensity.Value);
                    offset=0;
                    if warningLines
                        lines(3)="WARNING: "+app.ScannerWarning;
                        offset=1;
                    end
                    for k=1:numel(targets.targets)
                        m=targets.targets(k).spiral_cycle_metrics;
                        if m.calibrated
                            lines(k+2+offset)=sprintf(['%s: %.3f cycles during pulse ' ...
                                '(%d complete; %d started), %.3f ms/cycle.'], ...
                                char(targets.targets(k).cell_id), ...
                                m.fractional_cycles_during_pulse, ...
                                m.complete_cycles_during_pulse, ...
                                m.cycles_started_during_pulse,m.cycle_duration_ms);
                        else
                            lines(k+2+offset)=sprintf(['%s: exact spirals/pulse pending a ' ...
                                'nonidentity scanner calibration.'], ...
                                char(targets.targets(k).cell_id));
                        end
                    end
                    app.Status.Value=lines;
                else
                    app.setStatus("Target preview updated. Yellow = eroded 1P DMD mask.");
                end
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
                [reference,targets,manifest]=app.buildArtifacts();
                session=app.buildSessionState();
                paths=adaptive_optopatch.save_bundle( ...
                    app.LoadInfo.snapshot_directory,reference,targets,manifest, ...
                    "CreateSubfolder",true,"SessionState",session);
                app.setStatus(sprintf("Created planning folder:\n%s\n\nSaved:\n%s\n%s\n%s\n%s\n\n%d acquisitions planned (%s).", ...
                    paths.output_directory,paths.reference,paths.targets,paths.manifest,paths.session, ...
                    height(manifest.trials),app.Mode.Value));
            catch exception
                app.showError(exception);
            end
        end

        function setStatus(app,message), app.Status.Value=reshape(splitlines(string(message)),[],1); end
        function showError(app,exception)
            app.setStatus("ERROR: "+string(exception.message));
            uialert(app.Figure,exception.message,"Adaptive Optopatch error","Icon","error");
        end
    end
end

function value=ternary(condition,yes,no)
if condition, value=yes; else, value=no; end
end

function set_if_present(control,parameters,name)
if isfield(parameters,name)
    control.Value=parameters.(name);
end
end
