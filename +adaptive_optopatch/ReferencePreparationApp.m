classdef ReferencePreparationApp < handle
    %REFERENCEPREPARATIONAPP Interactive soma annotation and target planning.
    properties (SetAccess=private)
        Figure
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
        CellIds string = strings(0,1)
        CurrentFovState = struct([])
        NextCellIndex double = 1
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

        function value=statusText(app)
            %STATUSTEXT Current status lines as one string array.
            value=reshape(string(app.Status.Value),[],1);
        end

        function fovState=saveCurrentFov(app,path)
            [reference,~]=app.buildSpatialArtifacts();
            positions=cellfun(@(roi)double(roi.Position),app.RoiObjects, ...
                "UniformOutput",false);
            fovState=adaptive_optopatch.create_fov_state(reference,positions, ...
                "StimulationMode",string(app.Mode.Value), ...
                "MicronsPerPixel",app.MicronsPerPixel.Value, ...
                "SpiralRadiusUm",app.SpiralRadius.Value, ...
                "SpiralDensityPointsPerVolt",app.SpiralDensity.Value, ...
                "OrangeExpansionPixels",app.OrangeExpansion.Value, ...
                "BlueMaskAdjustmentPixels",app.DmdErosion.Value);
            if ~isempty(app.CurrentFovState)
                fovState=merge_cell_state(fovState,app.CurrentFovState);
            end
            fovState.next_cell_index=max(double(fovState.next_cell_index),app.NextCellIndex);
            adaptive_optopatch.save_fov_state(path,fovState);
            app.CurrentFovState=fovState;
        end

        function fovState=loadFov(app,path)
            fovState=adaptive_optopatch.load_fov_state(path);
            app.setFovState(fovState);
        end

        function setFovState(app,fovState)
            reference=fovState.reference;
            app.matchSimulatedReferenceCamera(reference.voltage_camera);
            app.ReferenceImage=single(reference.reference_image);
            metadata=struct("rig_name",reference.rig_name, ...
                "voltage_camera",reference.voltage_camera);
            if isfield(reference,"stimulation_dmd"), metadata.stimulation_dmd=reference.stimulation_dmd; end
            if isfield(reference,"scanner"), metadata.scanner=reference.scanner; end
            sourceSnapshot=""; if isfield(reference,"source_snapshot"), sourceSnapshot=string(reference.source_snapshot); end
            sourceExperiment="";
            if isfield(reference,"source_experiment")
                sourceExperiment=string(reference.source_experiment);
            end
            cameraName="Camera 1";
            if isfield(reference.voltage_camera,"name")
                cameraName=string(reference.voltage_camera.name);
            end
            cameraBin=1;
            if isfield(reference.voltage_camera,"bin")
                cameraBin=double(reference.voltage_camera.bin);
            end
            app.LoadInfo=struct("metadata",metadata,"snapshot_path",sourceSnapshot, ...
                "snapshot_directory",sourceExperiment, ...
                "snapshot_name",string(reference.fov_id),"image_size",reference.image_size, ...
                "camera_name",cameraName,"camera_bin",cameraBin,"timestamp",[]);
            imagesc(app.Axes,app.ReferenceImage); axis(app.Axes,"image"); app.Axes.YDir="reverse";
            colormap(app.Axes,"gray"); app.applyContrast();
            app.CellIds=string({fovState.cells.cell_id})';
            app.NextCellIndex=double(fovState.next_cell_index);
            app.CurrentFovState=fovState;
            positions=fovState.canonical_roi_polygons;
            if isempty(positions)
                positions=masks_to_polygons(fovState.canonical_roi_masks);
            end
            app.restorePolygons(positions);
            app.restoreFovControls(fovState,reference);
            app.updateQc();
            app.setStatus(sprintf("Loaded persistent FOV %s with %d stable cells.", ...
                fovState.fov_id,numel(fovState.cells)));
            app.planChanged();
        end

        function setCellCalibration(app,cellId,commandVoltageV,notes)
            arguments
                app
                cellId (1,1) string
                commandVoltageV (1,1) double = NaN
                notes (1,1) string = ""
            end
            fovState=app.currentFovState();
            pulseDurationMs=app.currentPulseDurationMs();
            obisPowerW=app.currentObisPowerW();
            ids=string({fovState.cells.cell_id}); index=find(ids==cellId,1);
            replaceSnapshot=true;
            if isfield(fovState.cells,"blue_calibration")
                replaceSnapshot=isempty(fovState.cells(index).blue_calibration);
            end
            fovState=adaptive_optopatch.update_cell_calibration(fovState,cellId, ...
                "CommandVoltageV",commandVoltageV,"Notes",notes, ...
                "PulseDurationMs",pulseDurationMs,"ObisPowerW",obisPowerW, ...
                "ReplaceCalibrationSnapshot",replaceSnapshot);
            app.CurrentFovState=fovState;
            app.updateQc();
        end

        function fovState=setCellEligibility(app,cellId,options)
            arguments
                app
                cellId (1,1) string
                options.RecordingEnabled = []
                options.StimulationEnabled = []
            end
            if isempty(options.RecordingEnabled) && isempty(options.StimulationEnabled)
                error("adaptive_optopatch:CellEligibilityRequired", ...
                    "Specify RecordingEnabled or StimulationEnabled.");
            end
            fovState=app.currentFovState();
            fovState=adaptive_optopatch.update_cell_eligibility(fovState,cellId, ...
                "RecordingEnabled",options.RecordingEnabled, ...
                "StimulationEnabled",options.StimulationEnabled);
            app.CurrentFovState=fovState;
            app.updateQc();
        end

        function configuration=sendOrangeRecordingMask(app)
            [~,targets]=app.buildSpatialArtifacts();
            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app.LuminosApp,targets,"DryRun",false);
            app.setStatus(sprintf(['Sent Orange recording mask to %s: %d cells, ' ...
                'expansion %d px. Canonical ROIs were unchanged.'], ...
                configuration.dmd_name,configuration.recording_cell_count, ...
                configuration.orange_expansion_pixels));
        end

        function cellId=addCanonicalRoi(app,position)
            arguments
                app
                position (:,2) double
            end
            if isempty(app.ReferenceImage) || size(position,1)<3
                error("adaptive_optopatch:InvalidCanonicalRoi", ...
                    "Load a reference image and provide at least three polygon vertices.");
            end
            cellId=compose("cell_%03d",app.NextCellIndex);
            colors=lines(max(7,numel(app.RoiObjects)+1)); index=numel(app.RoiObjects)+1;
            roi=drawpolygon(app.Axes,"Position",position, ...
                "Color",colors(mod(index-1,size(colors,1))+1,:), ...
                "Label",char(cellId),"LabelVisible","hover");
            addlistener(roi,"ROIMoved",@(~,~)app.updateQc());
            app.RoiObjects{end+1}=roi; app.CellIds(end+1,1)=cellId;
            app.NextCellIndex=app.NextCellIndex+1; app.updateQc();
        end

        function deleteCell(app,cellId)
            index=find(app.CellIds==string(cellId),1);
            if isempty(index), error("adaptive_optopatch:UnknownCellId","Unknown cell ID: %s",cellId); end
            if isvalid(app.RoiObjects{index}), delete(app.RoiObjects{index}); end
            app.RoiObjects(index)=[]; app.CellIds(index)=[];
            app.renumberRois(); app.updateQc();
        end

        function setCanonicalRoi(app,cellId,position)
            index=find(app.CellIds==string(cellId),1);
            if isempty(index), error("adaptive_optopatch:UnknownCellId","Unknown cell ID: %s",cellId); end
            app.RoiObjects{index}.Position=double(position);
            app.updateQc();
        end

        function loadSnapshot(app,snapshotPath)
            [image,info]=adaptive_optopatch.read_reference_snapshot(snapshotPath);
            app.matchSimulatedReferenceCamera(info.metadata.voltage_camera);
            app.ReferenceImage=image; app.LoadInfo=info; app.clearRois();
            app.CurrentFovState=struct([]);
            app.NextCellIndex=1;
            imagesc(app.Axes,image); axis(app.Axes,"image"); app.Axes.YDir="reverse";
            colormap(app.Axes,"gray"); app.applyContrast();
            title(app.Axes,sprintf("%s — %s snapshot", ...
                info.metadata.rig_name,info.camera_name),"Interpreter","none");
            app.setStatus(sprintf(['Loaded snapshot:\n%s\nCamera: %s, ' ...
                '%d × %d pixels, binning %.3g.'], ...
                info.snapshot_path,info.camera_name, ...
                info.image_size(2),info.image_size(1),info.camera_bin));
            if app.restorePlanningBundleOnSnapshotLoad()
                app.restoreLatestPlanning(info.snapshot_directory);
            end
        end
    end

    methods (Access=protected)
        function matchSimulatedReferenceCamera(app,referenceCamera)
            % Real Luminos camera state is owned by Luminos and is never changed here.
            if isa(app.LuminosApp, ...
                    "adaptive_optopatch.testing.SimulatedLuminosApp")
                app.LuminosApp.matchReferenceCameraGeometry(referenceCamera);
            end
        end

        function buildUI(app,visible)
            app.Figure = uifigure("Name","Adaptive Optopatch — Reference & Targets", ...
                "Position",[80 80 1320 780],"Visible",visible);
            root = uigridlayout(app.Figure,[2 3]);
            root.RowHeight = {"1x",145}; root.ColumnWidth = {245,"1x",390};

            controls = uigridlayout(root,[24 2]); controls.Layout.Row = 1; controls.Layout.Column = 1;
            controls.RowHeight = repmat({28},1,24); controls.ColumnWidth = {"1x",90};
            b = uibutton(controls,"Text","Load Luminos snapshot…", ...
                "ButtonPushedFcn",@(~,~)app.chooseSnapshot()); b.Layout.Column = [1 2];
            b = uibutton(controls,"Text","Load saved FOV…", ...
                "ButtonPushedFcn",@(~,~)app.chooseFov()); b.Layout.Column = [1 2];
            b = uibutton(controls,"Text","Save FOV…", ...
                "ButtonPushedFcn",@(~,~)app.chooseSaveFov()); b.Layout.Column = [1 2];
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
            uilabel(controls,"Text","Pulse command (V)", ...
                "Tooltip","2P mod for spirals; mod488 for 1P DMD stimulation.");
            app.ModulatorVoltage = uieditfield(controls,"numeric","Value",1,"Limits",[eps 5]);
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

            app.Status = uitextarea(root,"Editable","off", ...
                "Value",["Ready. In Luminos, click Snap for Camera 1."; ...
                         "Then load its MAT file from the Luminos Snaps folder."]);
            app.Status.Layout.Row=2; app.Status.Layout.Column=[1 3];
            watched={app.Mode,app.MicronsPerPixel,app.SpiralRadius,app.OrangeExpansion, ...
                app.SpiralDensity,app.DmdErosion,app.Repeats,app.PulseCount, ...
                app.PulseDuration,app.DarkIntervalMin,app.DarkIntervalMax, ...
                app.ModulatorVoltage,app.PreDelay,app.PostDelay};
            for k=1:numel(watched)
                watched{k}.ValueChangedFcn=@(~,~)app.planChanged();
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
            if isempty(app.LoadInfo), app.setStatus("Load a snapshot before saving an FOV."); return; end
            suggested=string(app.LoadInfo.snapshot_name)+"_fov_state.mat";
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
            newCellId=compose("cell_%03d",app.NextCellIndex);
            try
                roi=drawpolygon(app.Axes,"Color",colors(mod(idx-1,size(colors,1))+1,:), ...
                    "Label",char(newCellId),"LabelVisible","hover");
                if isempty(roi.Position) || size(roi.Position,1)<3, delete(roi); return; end
                addlistener(roi,"ROIMoved",@(~,~)app.updateQc());
                app.RoiObjects{end+1}=roi; app.CellIds(end+1,1)=newCellId;
                app.NextCellIndex=app.NextCellIndex+1; app.updateQc();
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
            app.RoiObjects(idx)=[]; app.CellIds(idx)=[]; app.renumberRois(); app.updateQc();
        end

        function clearRois(app)
            for k=1:numel(app.RoiObjects)
                if isvalid(app.RoiObjects{k}), delete(app.RoiObjects{k}); end
            end
            app.RoiObjects={}; app.CellIds=strings(0,1); app.RoiList.Items=strings(1,0); app.QcTable.Data=cell(0,9);
            app.RoisVisible=true; app.updateRoiVisibility();
            app.deletePreview();
        end

        function renumberRois(app)
            for k=1:numel(app.RoiObjects), app.RoiObjects{k}.Label=char(app.CellIds(k)); end
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
            n=numel(app.RoiObjects);
            if numel(app.CellIds)~=n, app.CellIds=compose("cell_%03d",(1:n)'); end
            items=app.CellIds; data=cell(n,9);
            if n==0
                app.RoiList.Items=strings(1,0); app.QcTable.Data=data;
                app.planChanged(); return
            end
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
                state=cell_state_for_id(app.CurrentFovState,items(k));
                data(k,:)={char(items(k)),state.recording_enabled, ...
                    state.stimulation_enabled,state.selected_blue_voltage_v, ...
                    area,round(cx,1),round(cy,1),edge, ...
                    ternary(pass,'PASS','CHECK')};
            end
            previous=string(app.RoiList.Value); app.RoiList.Items=reshape(items,1,[]);
            if ~isempty(previous) && any(strcmp(items,previous)), app.RoiList.Value=previous; end
            app.QcTable.Data=data;
            app.planChanged();
        end

        function [reference,targets,manifest]=buildArtifacts(app)
            [reference,targets]=app.buildSpatialArtifacts( ...
                "PulseDurationMs",app.PulseDuration.Value);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",app.PulseCount.Value, ...
                "PulseDurationMs",app.PulseDuration.Value, ...
                "DarkIntervalMs",[app.DarkIntervalMin.Value app.DarkIntervalMax.Value], ...
                "PreDelayMs",app.PreDelay.Value,"PostDelayMs",app.PostDelay.Value, ...
                "RandomSeed",1);
            template=definition.acquisitions;
            definition.acquisitions=repmat(template,app.Repeats.Value,1);
            for repeat=1:app.Repeats.Value
                definition.acquisitions(repeat).acquisition_id=compose( ...
                    "screen_repeat_%03d",repeat);
            end
            fovState=app.currentFovState();
            reference=fovState.reference;
            defaults=struct("command_voltage_v",app.ModulatorVoltage.Value, ...
                "pulse_duration_s",app.PulseDuration.Value/1000, ...
                "blue_mask_adjustment_pixels",app.DmdErosion.Value, ...
                "orange_expansion_pixels",app.OrangeExpansion.Value, ...
                "spiral_radius_um",app.SpiralRadius.Value, ...
                "spiral_density_points_per_volt",app.SpiralDensity.Value);
            manifest=adaptive_optopatch.build_manifest(reference,targets,definition, ...
                "Mode",string(app.Mode.Value),"FovState",fovState, ...
                "GuiDefaults",defaults,"OutputPrefix","connectivity_screen");
        end

        function [reference,targets]=buildSpatialArtifacts(app,options)
            arguments
                app
                options.PulseDurationMs (1,1) double {mustBePositive} = 5
            end
            if isempty(app.ReferenceImage) || isempty(app.RoiObjects)
                error("adaptive_optopatch:NothingToSave","Load an image and draw at least one soma ROI.");
            end
            masks=app.makeMasks();
            fovId=string(matlab.lang.makeValidName(char(app.LoadInfo.snapshot_name)));
            reference=adaptive_optopatch.create_reference_model(app.ReferenceImage,masks, ...
                app.LoadInfo.metadata,"MicronsPerPixel",app.MicronsPerPixel.Value, ...
                "FovId",string(fovId),"SourceExperiment",app.LoadInfo.snapshot_directory, ...
                "CellIds",app.CellIds,"RoiPolygons", ...
                cellfun(@(roi)double(roi.Position),app.RoiObjects,"UniformOutput",false));
            if ~isempty(app.CurrentFovState)
                reference=merge_reference_cell_state(reference,app.CurrentFovState);
            end
            reference.source_snapshot=app.LoadInfo.snapshot_path;
            if ~isempty(app.LuminosApp)
                reference.luminos_settings_snapshot= ...
                    adaptive_optopatch.snapshot_luminos_settings(app.LuminosApp);
            else
                reference.luminos_settings_snapshot=struct([]);
            end
            [liveScanner,app.ScannerWarning]= ...
                adaptive_optopatch.get_live_scanner_calibration(app.LuminosApp);
            if isempty(liveScanner)
                [persistedScanner,persistedWarning]=persisted_scanner_calibration();
                if ~isempty(persistedScanner)
                    liveScanner=persistedScanner;
                    app.ScannerWarning="";
                elseif strlength(persistedWarning)>0
                    app.ScannerWarning=app.ScannerWarning+" "+persistedWarning;
                end
            end
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
                "PulseDurationMs",options.PulseDurationMs, ...
                "ScannerSampleRateHz",scannerSampleRate, ...
                "OrangeExpansionPixels",app.OrangeExpansion.Value, ...
                "BlueMaskAdjustmentPixels",app.DmdErosion.Value);
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
                "orange_expansion_pixels",app.OrangeExpansion.Value, ...
                "blue_mask_adjustment_pixels",app.DmdErosion.Value, ...
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
            app.planningSessionRestored(session);
            app.setStatus(sprintf(['Loaded %s\nRestored %d polygon ROIs and ' ...
                'experimental parameters from latest planning bundle:\n%s'], ...
                app.LoadInfo.snapshot_path,numel(positions),bundle.folder));
        end

        function restorePolygons(app,positions)
            savedIds=app.CellIds;
            app.clearRois();
            if numel(savedIds)==numel(positions), app.CellIds=savedIds;
            else, app.CellIds=compose("cell_%03d",(1:numel(positions))'); end
            colors=lines(max(7,numel(positions)));
            for k=1:numel(positions)
                p=positions{k};
                if isempty(p) || size(p,2)~=2, continue; end
                roi=drawpolygon(app.Axes,"Position",p, ...
                    "Color",colors(mod(k-1,size(colors,1))+1,:), ...
                    "Label",char(app.CellIds(k)),"LabelVisible","hover");
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
            set_if_present(app.OrangeExpansion,p,"orange_expansion_pixels");
            if isfield(p,"blue_mask_adjustment_pixels")
                app.DmdErosion.Value=p.blue_mask_adjustment_pixels;
            elseif isfield(p,"dmd_erosion_pixels")
                app.DmdErosion.Value=-p.dmd_erosion_pixels;
            end
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
                % Only spatial artifacts are needed here: the preview draws
                % resolved acquisitions when the subclass has them, and the
                % bundle's own defaults otherwise.
                [~,targets]=app.buildSpatialArtifacts( ...
                    "PulseDurationMs",app.currentPulseDurationMs());
                mode=string(app.Mode.Value);
                preview=adaptive_optopatch.build_target_preview(targets,mode, ...
                    "ResolvedProtocols",app.previewResolvedProtocols(targets), ...
                    "ScannerTransform",app.previewScannerTransform(targets), ...
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
                app.Status.Value=preview_status(preview,mode,app.ScannerWarning);
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

        function invokeOrangeMask(app)
            try
                app.sendOrangeRecordingMask();
            catch exception
                app.showError(exception);
            end
        end

        function fovState=currentFovState(app)
            [reference,~]=app.buildSpatialArtifacts();
            positions=cellfun(@(roi)double(roi.Position),app.RoiObjects, ...
                "UniformOutput",false);
            fovState=adaptive_optopatch.create_fov_state(reference,positions, ...
                "StimulationMode",string(app.Mode.Value), ...
                "MicronsPerPixel",app.MicronsPerPixel.Value, ...
                "SpiralRadiusUm",app.SpiralRadius.Value, ...
                "SpiralDensityPointsPerVolt",app.SpiralDensity.Value, ...
                "OrangeExpansionPixels",app.OrangeExpansion.Value, ...
                "BlueMaskAdjustmentPixels",app.DmdErosion.Value);
            if ~isempty(app.CurrentFovState)
                fovState=merge_cell_state(fovState,app.CurrentFovState);
            end
            fovState.next_cell_index=max(double(fovState.next_cell_index),app.NextCellIndex);
        end

        function qcCellEdited(app,source,event)
            row=event.Indices(1); column=event.Indices(2);
            if row<1 || row>numel(app.CellIds) || ~ismember(column,[2 3 4])
                app.updateQc();
                return
            end
            try
                cellId=app.CellIds(row);
                if column==2
                    app.setCellEligibility(cellId, ...
                        "RecordingEnabled",logical(event.NewData));
                elseif column==3
                    app.setCellEligibility(cellId, ...
                        "StimulationEnabled",logical(event.NewData));
                else
                    voltage=parse_blue_voltage(event.NewData);
                    app.setCellBlueVoltage(cellId,voltage);
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
                app.updateQc();
                app.showError(exception);
            end
        end

        function setCellBlueVoltage(app,cellId,voltage)
            fovState=app.currentFovState();
            ids=string({fovState.cells.cell_id}); index=find(ids==cellId,1);
            notes=""; acquisition="";
            if isfield(fovState.cells,"calibration_notes")
                notes=string(fovState.cells(index).calibration_notes);
            end
            if isfield(fovState.cells,"calibration_acquisition")
                acquisition=string(fovState.cells(index).calibration_acquisition);
            end
            fovState=adaptive_optopatch.update_cell_calibration(fovState,cellId, ...
                "CommandVoltageV",voltage,"Notes",notes, ...
                "Acquisition",acquisition,"ReplaceCalibrationSnapshot",false);
            app.CurrentFovState=fovState;
            app.updateQc();
        end


        function value=currentPulseDurationMs(app)
            value=app.PulseDuration.Value;
        end

        function value=currentObisPowerW(app)
            value=NaN;
            if isempty(app.LuminosApp), return; end
            try
                laser=app.LuminosApp.getDevice("Laser_Device","name","488", ...
                    "displayWarning",false);
                if ~isempty(laser), value=double(laser.SetPower); end
            catch
            end
        end

        function setStatus(app,message), app.Status.Value=reshape(splitlines(string(message)),[],1); end
        function showError(app,exception)
            app.setStatus("ERROR: "+string(exception.message));
            if app.Figure.Visible=="on"
                uialert(app.Figure,exception.message,"Adaptive Optopatch error","Icon","error");
            end
        end

        function planChanged(~)
            % Subclasses use this hook to invalidate previously built plans.
        end

        function planningSessionRestored(~,~)
            % Subclasses can restore additional planning-session state.
        end

        function protocols=previewResolvedProtocols(~,~)
            %PREVIEWRESOLVEDPROTOCOLS Resolved acquisitions the preview shows.
            %   The standalone planner has no protocol artifact, so its
            %   preview can only show the bundle's default values. Subclasses
            %   that resolve a protocol return those acquisitions so the
            %   preview draws what will actually run.
            protocols={};
        end

        function transform=previewScannerTransform(~,targets)
            %PREVIEWSCANNERTRANSFORM Transform used for spiral cycle metrics.
            transform=[];
            if isfield(targets,"scanner_transform")
                transform=targets.scanner_transform;
            end
        end

        function value=showPlanningBundleControl(~)
            value=true;
        end

        function value=restorePlanningBundleOnSnapshotLoad(~)
            value=true;
        end

        function restoreFovControls(app,fovState,reference)
            if isfield(fovState,"stimulation_mode") && ...
                    ismember(string(fovState.stimulation_mode),string(app.Mode.Items))
                app.Mode.Value=string(fovState.stimulation_mode);
            end
            app.MicronsPerPixel.Value=fov_number(fovState,"microns_per_pixel", ...
                reference.microns_per_pixel,app.MicronsPerPixel.Value);
            app.SpiralRadius.Value=fov_number(fovState,"spiral_radius_um", ...
                NaN,app.SpiralRadius.Value);
            app.SpiralDensity.Value=fov_number(fovState, ...
                "spiral_density_points_per_volt",NaN,app.SpiralDensity.Value);
            app.OrangeExpansion.Value=fov_number(fovState, ...
                "orange_expansion_pixels",NaN,app.OrangeExpansion.Value);
            app.DmdErosion.Value=fov_number(fovState, ...
                "blue_mask_adjustment_pixels",NaN,app.DmdErosion.Value);
        end
    end
end

function value=fov_number(fovState,name,preferredFallback,currentFallback)
value=currentFallback;
if isfinite(preferredFallback), value=double(preferredFallback); end
if isfield(fovState,name) && isscalar(fovState.(name)) && ...
        isfinite(double(fovState.(name)))
    value=double(fovState.(name));
end
end

function value=ternary(condition,yes,no)
if condition, value=yes; else, value=no; end
end

function voltage=parse_blue_voltage(value)
if isnumeric(value) && isscalar(value) && isreal(value)
    voltage=double(value);
elseif (ischar(value) || isstring(value)) && isscalar(string(value))
    voltage=str2double(string(value));
else
    voltage=NaN;
end
if ~isfinite(voltage) || voltage<=0 || voltage>5
    error("adaptive_optopatch:InvalidCellCalibration", ...
        "Blue V (1P) must be a finite number in (0,5] V.");
end
end

function set_if_present(control,parameters,name)
if isfield(parameters,name)
    control.Value=parameters.(name);
end
end

function cellState=cell_state_for_id(fovState,cellId)
cellState=struct("recording_enabled",true,"stimulation_enabled",true, ...
    "selected_blue_voltage_v",NaN);
if isempty(fovState) || ~isfield(fovState,"cells"), return; end
ids=string({fovState.cells.cell_id}); index=find(ids==cellId,1);
if isempty(index), return; end
for name=string(fieldnames(cellState))'
    if isfield(fovState.cells,name), cellState.(name)=fovState.cells(index).(name); end
end
end

function fovState=merge_cell_state(fovState,previous)
fovState.reference=merge_reference_cell_state(fovState.reference,previous);
fovState.cells=fovState.reference.cells;
end

function reference=merge_reference_cell_state(reference,previous)
if isempty(previous) || ~isfield(previous,"cells"), return; end
oldIds=string({previous.cells.cell_id});
stateFields=["recording_enabled","stimulation_enabled", ...
    "selected_blue_voltage_v", ...
    "calibration_notes","calibration_acquisition", ...
    "blue_calibration","blue_calibration_history"];
for k=1:numel(reference.cells)
    index=find(oldIds==string(reference.cells(k).cell_id),1);
    if isempty(index), continue; end
    for name=stateFields
        if isfield(previous.cells,name)
            reference.cells(k).(name)=previous.cells(index).(name);
        end
    end
end
end

function polygons=masks_to_polygons(masks)
polygons=cell(size(masks,3),1);
for k=1:size(masks,3)
    boundaries=bwboundaries(logical(masks(:,:,k)));
    if isempty(boundaries), polygons{k}=zeros(0,2); continue; end
    [~,index]=max(cellfun(@(p)size(p,1),boundaries));
    boundary=boundaries{index};
    polygons{k}=[boundary(:,2) boundary(:,1)];
end
end

function [calibration,warningMessage]=persisted_scanner_calibration()
calibration=struct([]); warningMessage="";
try
    [artifact,status]=adaptive_optopatch.get_active_galvo_calibration();
    if ~status.found, return; end
    validation=adaptive_optopatch.validate_galvo_calibration_artifact(artifact);
    if ~validation.passed
        warningMessage="Persisted calibration was rejected: "+ ...
            strjoin(validation.issues,"; ");
        return
    end
    profile=adaptive_optopatch.virtual_upright_2p_profile();
    calibration=struct("name",artifact.scanner_name, ...
        "device_type","Scanning_Device", ...
        "tform",artifact.calibration.tform, ...
        "sample_rate",profile.scanner.sample_rate_hz, ...
        "source","active_galvo_calibration", ...
        "calibration_id",artifact.calibration_id, ...
        "transform_direction","galvo_volts_to_camera_pixels");
catch exception
    warningMessage="Could not load persisted scanner calibration: "+ ...
        string(exception.message);
end
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
