classdef AdaptiveOptopatchController < handle
    %ADAPTIVEOPTOPATCHCONTROLLER UI-independent owner of Adaptive Optopatch session state.
    %   The controller holds every piece of mutable Adaptive Optopatch
    %   session state that an experiment depends on: the reference FOV,
    %   canonical soma geometry and stable cell identity, per-cell
    %   decisions, editable plan parameters, the loaded pulse protocol, the
    %   frozen run, and the run lifecycle. It can be created without a
    %   figure, so the same state is reachable from the MATLAB GUI and from
    %   a future non-MATLAB frontend.
    %
    %   The controller orchestrates existing package functions; it does not
    %   duplicate protocol resolution, DMD/FLUT planning, waveform
    %   generation, or acquisition execution. Graphics objects are views of
    %   this state and never the state itself.

    properties (SetAccess=private)
        %REVISION Monotonic counter bumped whenever getState() would change.
        Revision (1,1) double = 0
        %LIFECYCLESTATE Run lifecycle: EDITABLE, FROZEN, or RUNNING.
        LifecycleState (1,1) string = "EDITABLE"
        StopRequested (1,1) logical = false
        Status string = strings(0,1)
        ScannerWarning (1,1) string = ""
        ReferenceImage = []
        ReferenceInfo struct = struct([])
        %REFERENCEREVISION Bumped whenever the displayed reference image changes.
        ReferenceRevision (1,1) double = 0
        FovGeometry struct
        %CELLSTATE Per-cell decisions and calibration carried across edits.
        CellState struct = struct([])
        PlanParameters struct
        Protocol struct = struct([])
        ProtocolPath (1,1) string = ""
        ProtocolSummary struct = struct([])
        ActiveRunPlan struct = struct([])
        ActiveRunFolder (1,1) string = ""
        LastRun struct = struct([])
        EditableStateChanged (1,1) logical = true
    end

    properties
        %STATECHANGEDFCN Called with no arguments after every state change.
        %   One callback, not an observer framework: the MATLAB GUI uses it
        %   to redraw itself from getState().
        StateChangedFcn = []
        RunRoot (1,1) string = ""
    end

    properties (Access=private)
        LuminosApp = []
        CellSummaryCache = []
    end

    methods
        function controller=AdaptiveOptopatchController(options)
            arguments
                options.LuminosApp = []
                options.RunRoot (1,1) string = ""
            end
            controller.LuminosApp=options.LuminosApp;
            controller.RunRoot=options.RunRoot;
            controller.FovGeometry=adaptive_optopatch.create_fov_geometry();
            controller.PlanParameters=default_plan_parameters();
            controller.Status=["Ready. In Luminos, click Snap for Camera 1."; ...
                "Then load its MAT file from the Luminos Snaps folder."];
        end

        function state=getState(controller)
            %GETSTATE Lightweight, jsonencode-ready snapshot of AO state.
            %   Reference images, ROI masks, targets, waveforms, and frozen
            %   manifests are deliberately excluded; they are fetched
            %   through their own accessors when a view actually needs them.
            state=struct;
            state.schema_version="1.0.0";
            state.revision=controller.Revision;
            state.lifecycle=controller.lifecycle();
            state.plan_state=controller.LifecycleState;
            state.editable_state_changed=controller.EditableStateChanged;
            state.stop_after_current_requested=controller.StopRequested;
            state.status=controller.Status;
            state.scanner_warning=controller.ScannerWarning;
            state.fov=controller.fovSummary();
            state.cells=controller.cellRows();
            state.soma_polygons=controller.FovGeometry.polygons;
            state.protocol=controller.protocolState();
            state.plan_parameters=controller.PlanParameters;
            state.active_run=controller.activeRunSummary();
            state.legal_actions=controller.legalActions();
        end

        function value=lifecycle(controller)
            %LIFECYCLE Explicit lifecycle name for frontends.
            %   RUNNING splits into running and stopping_after_current so a
            %   frontend never has to infer a pending stop from a button.
            switch controller.LifecycleState
                case "FROZEN", value="frozen";
                case "RUNNING"
                    value=ternary(controller.StopRequested, ...
                        "stopping_after_current","running");
                otherwise, value="editing";
            end
        end

        function actions=legalActions(controller)
            %LEGALACTIONS Which operations the backend will currently accept.
            editing=controller.LifecycleState~="RUNNING";
            hasFov=~isempty(controller.ReferenceImage);
            hasCells=~isempty(controller.FovGeometry.polygons);
            hasFrozenRun=~isempty(controller.ActiveRunPlan) && ...
                strlength(controller.ActiveRunFolder)>0;
            actions=struct( ...
                "edit_cells",editing && hasFov, ...
                "edit_plan_parameters",editing, ...
                "load_protocol",editing, ...
                "load_fov",editing, ...
                "freeze_run",editing && hasFov && hasCells && ...
                    ~isempty(controller.Protocol), ...
                "run",editing, ...
                "stop_after_current",controller.LifecycleState=="RUNNING" && ...
                    ~controller.StopRequested, ...
                "return_to_editing",controller.returnToEditingEnabled(), ...
                "start_new_batch",controller.startNewBatchEnabled(), ...
                "resume_run",editing);
        end

        function value=statusText(controller)
            value=reshape(controller.Status,[],1);
        end

        function setStatus(controller,message)
            controller.Status=reshape(splitlines(string(message)),[],1);
            controller.bumpRevision();
        end

        % ---------------------------------------------------------------
        % Reference FOV
        % ---------------------------------------------------------------
        function loadSnapshot(controller,snapshotPath)
            %LOADSNAPSHOT Replace the FOV from a Luminos camera snapshot.
            arguments
                controller
                snapshotPath (1,1) string
            end
            controller.assertNotRunning("Loading a snapshot");
            [image,info]=adaptive_optopatch.read_reference_snapshot(snapshotPath);
            controller.matchSimulatedReferenceCamera(info.metadata.voltage_camera);
            controller.adoptReference(image,info);
            controller.setStatus(sprintf(['Loaded snapshot:\n%s\nCamera: %s, ' ...
                '%d × %d pixels, binning %.3g.'],info.snapshot_path, ...
                info.camera_name,info.image_size(2),info.image_size(1), ...
                info.camera_bin));
        end

        function setReferenceData(controller,image,info,somaPolygons)
            %SETREFERENCEDATA Install a reference image and optional somata.
            arguments
                controller
                image (:,:) {mustBeNumeric}
                info (1,1) struct
                somaPolygons cell = {}
            end
            controller.assertNotRunning("Replacing the reference image");
            controller.adoptReference(image,info);
            controller.setSomaPolygons(somaPolygons);
        end

        function fovState=loadFov(controller,path)
            fovState=adaptive_optopatch.load_fov_state(path);
            controller.setFovState(fovState);
        end

        function setFovState(controller,fovState)
            %SETFOVSTATE Adopt a persistent FOV as the canonical session FOV.
            arguments
                controller
                fovState (1,1) struct
            end
            controller.assertNotRunning("Loading a saved FOV");
            reference=fovState.reference;
            controller.matchSimulatedReferenceCamera(reference.voltage_camera);
            controller.ReferenceImage=single(reference.reference_image);
            controller.ReferenceInfo=reference_info_from_model(reference);
            controller.ReferenceRevision=controller.ReferenceRevision+1;
            polygons=fovState.canonical_roi_polygons;
            if isempty(polygons)
                polygons=masks_to_polygons(fovState.canonical_roi_masks);
            end
            controller.FovGeometry=adaptive_optopatch.create_fov_geometry( ...
                double(reference.image_size(1:2)));
            controller.FovGeometry.polygons=reshape(polygons,[],1);
            controller.FovGeometry.cell_ids=string({fovState.cells.cell_id})';
            controller.FovGeometry.next_cell_index= ...
                double(fovState.next_cell_index);
            controller.CellState=fovState;
            controller.applyFovPlanParameters(fovState,reference);
            controller.invalidateCellSummary();
            controller.markEditableChanged();
            controller.setStatus(sprintf( ...
                "Loaded persistent FOV %s with %d stable cells.", ...
                fovState.fov_id,numel(fovState.cells)));
        end

        function fovState=saveFov(controller,path)
            fovState=controller.currentFovState();
            adaptive_optopatch.save_fov_state(path,fovState);
            controller.CellState=fovState;
            controller.bumpRevision();
        end

        function setSomaPolygons(controller,polygons,options)
            %SETSOMAPOLYGONS Replace all canonical somata at once.
            %   Saved cell IDs are kept when their count matches, so a
            %   restored FOV or planning bundle does not renumber cells.
            arguments
                controller
                polygons cell
                options.CellIds string = strings(0,1)
            end
            controller.assertNotRunning("Replacing soma polygons");
            polygons=reshape(polygons,[],1);
            keep=true(numel(polygons),1);
            for k=1:numel(polygons)
                keep(k)=~isempty(polygons{k}) && size(polygons{k},2)==2;
            end
            polygons=polygons(keep);
            cellIds=reshape(options.CellIds,[],1);
            if numel(cellIds)~=numel(polygons)
                cellIds=compose("cell_%03d",(1:numel(polygons))');
            end
            geometry=adaptive_optopatch.create_fov_geometry( ...
                controller.referenceImageSize());
            geometry.polygons=polygons;
            geometry.cell_ids=cellIds;
            geometry.next_cell_index=next_index_after(cellIds);
            controller.FovGeometry=geometry;
            controller.invalidateCellSummary();
            controller.markEditableChanged();
            controller.bumpRevision();
        end

        function clearSomata(controller)
            controller.setSomaPolygons({});
        end

        % ---------------------------------------------------------------
        % Canonical soma geometry and per-cell decisions
        % ---------------------------------------------------------------
        function cellId=addSomaPolygon(controller,verticesXy)
            %ADDSOMAPOLYGON Commit one drawn soma into canonical state.
            arguments
                controller
                verticesXy (:,2) double
            end
            controller.assertNotRunning("Adding a soma");
            if isempty(controller.ReferenceImage)
                error("adaptive_optopatch:InvalidCanonicalRoi", ...
                    "Load a reference image before adding a soma polygon.");
            end
            [controller.FovGeometry,cellId]=adaptive_optopatch.add_soma_polygon( ...
                controller.FovGeometry,verticesXy);
            controller.invalidateCellSummary();
            controller.markEditableChanged();
            controller.bumpRevision();
        end

        function updateSomaPolygon(controller,cellId,verticesXy)
            %UPDATESOMAPOLYGON Move one soma without changing its identity.
            arguments
                controller
                cellId (1,1) string
                verticesXy (:,2) double
            end
            controller.assertNotRunning("Editing a soma");
            controller.FovGeometry=adaptive_optopatch.update_soma_polygon( ...
                controller.FovGeometry,cellId,verticesXy);
            controller.invalidateCellSummary();
            controller.markEditableChanged();
            controller.bumpRevision();
        end

        function deleteCell(controller,cellId)
            arguments
                controller
                cellId (1,1) string
            end
            controller.assertNotRunning("Deleting a soma");
            controller.FovGeometry=adaptive_optopatch.delete_soma_polygon( ...
                controller.FovGeometry,cellId);
            controller.invalidateCellSummary();
            controller.markEditableChanged();
            controller.bumpRevision();
        end

        function fovState=setCellEligibility(controller,cellId,options)
            arguments
                controller
                cellId (1,1) string
                options.RecordingEnabled = []
                options.StimulationEnabled = []
            end
            if isempty(options.RecordingEnabled) && isempty(options.StimulationEnabled)
                error("adaptive_optopatch:CellEligibilityRequired", ...
                    "Specify RecordingEnabled or StimulationEnabled.");
            end
            controller.assertNotRunning("Changing cell eligibility");
            fovState=adaptive_optopatch.update_cell_eligibility( ...
                controller.currentFovState(),cellId, ...
                "RecordingEnabled",options.RecordingEnabled, ...
                "StimulationEnabled",options.StimulationEnabled);
            controller.CellState=fovState;
            controller.invalidateCellSummary();
            controller.bumpRevision();
        end

        function setCellCalibration(controller,cellId,commandVoltageV,notes)
            arguments
                controller
                cellId (1,1) string
                commandVoltageV (1,1) double = NaN
                notes (1,1) string = ""
            end
            controller.assertNotRunning("Changing a cell calibration");
            fovState=controller.currentFovState();
            ids=string({fovState.cells.cell_id}); index=find(ids==cellId,1);
            replaceSnapshot=true;
            if isfield(fovState.cells,"blue_calibration")
                replaceSnapshot=isempty(fovState.cells(index).blue_calibration);
            end
            fovState=adaptive_optopatch.update_cell_calibration(fovState,cellId, ...
                "CommandVoltageV",commandVoltageV,"Notes",notes, ...
                "PulseDurationMs",controller.currentPulseDurationMs(), ...
                "ObisPowerW",controller.currentObisPowerW(), ...
                "ReplaceCalibrationSnapshot",replaceSnapshot);
            controller.CellState=fovState;
            controller.invalidateCellSummary();
            controller.bumpRevision();
        end

        function setCellBlueVoltage(controller,cellId,voltage)
            %SETCELLBLUEVOLTAGE Edit the per-cell 488 nm calibration value.
            %   This is a stored calibration, not a GUI command source: the
            %   resolver still owns 1P voltage precedence.
            arguments
                controller
                cellId (1,1) string
                voltage
            end
            controller.assertNotRunning("Changing a cell calibration");
            voltage=validate_blue_voltage(voltage);
            fovState=controller.currentFovState();
            ids=string({fovState.cells.cell_id}); index=find(ids==cellId,1);
            if isempty(index)
                error("adaptive_optopatch:UnknownCellId", ...
                    "Unknown cell ID: %s",cellId);
            end
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
            controller.CellState=fovState;
            controller.invalidateCellSummary();
            controller.bumpRevision();
        end

        function applyCellState(controller,fovState)
            %APPLYCELLSTATE Adopt per-cell decisions produced elsewhere.
            %   The Blue-ramp review returns a whole FOV state; its cell
            %   records become canonical without disturbing geometry.
            arguments
                controller
                fovState (1,1) struct
            end
            controller.assertNotRunning("Applying a calibration decision");
            controller.CellState=fovState;
            controller.invalidateCellSummary();
            controller.bumpRevision();
        end

        function summary=cellSummary(controller)
            %CELLSUMMARY Canonical per-cell geometry, QC, and decisions.
            if isempty(controller.CellSummaryCache)
                controller.CellSummaryCache= ...
                    adaptive_optopatch.summarize_soma_geometry( ...
                    controller.FovGeometry);
            end
            summary=controller.CellSummaryCache;
        end

        function masks=somaMasks(controller)
            masks=adaptive_optopatch.soma_polygon_masks(controller.FovGeometry);
        end

        % ---------------------------------------------------------------
        % Editable plan parameters
        % ---------------------------------------------------------------
        function setPlanParameter(controller,name,value)
            %SETPLANPARAMETER Update one canonical editable plan value.
            name=plan_parameter_name(name);
            controller.assertNotRunning("Changing plan parameters");
            controller.PlanParameters.(name)=coerce_plan_value(name,value);
            controller.markEditableChanged();
            controller.bumpRevision();
        end

        function setPlanParameters(controller,parameters)
            %SETPLANPARAMETERS Apply every recognized field of a parameter struct.
            arguments
                controller
                parameters (1,1) struct
            end
            controller.assertNotRunning("Changing plan parameters");
            names=string(fieldnames(parameters))';
            for name=names
                if name=="dmd_erosion_pixels" && ...
                        ~isfield(parameters,"blue_mask_adjustment_pixels")
                    % Legacy bundles stored an erosion magnitude; the
                    % canonical parameter is a signed adjustment.
                    controller.PlanParameters.blue_mask_adjustment_pixels= ...
                        -double(parameters.dmd_erosion_pixels);
                    continue
                end
                if ~isfield(controller.PlanParameters,name), continue; end
                controller.PlanParameters.(name)= ...
                    coerce_plan_value(name,parameters.(name));
            end
            controller.markEditableChanged();
            controller.bumpRevision();
        end

        % ---------------------------------------------------------------
        % Pulse protocol
        % ---------------------------------------------------------------
        function protocol=loadProtocol(controller,path)
            protocol=adaptive_optopatch.load_protocol(path);
            controller.setProtocol(protocol,path);
        end

        function setProtocol(controller,protocol,path)
            arguments
                controller
                protocol (1,1) struct
                path (1,1) string = ""
            end
            controller.assertNotRunning("Loading a protocol");
            report=adaptive_optopatch.validate_protocol(protocol);
            if ~report.passed
                error("adaptive_optopatch:InvalidProtocol", ...
                    "%s",strjoin(report.issues,newline));
            end
            controller.Protocol=report.protocol;
            controller.ProtocolPath=path;
            controller.ProtocolSummary= ...
                adaptive_optopatch.summarize_protocol(report.protocol);
            controller.markEditableChanged();
            controller.bumpRevision();
        end

        function forgetMissingProtocol(controller,path)
            %FORGETMISSINGPROTOCOL Record a protocol path that no longer exists.
            arguments
                controller
                path (1,1) string
            end
            controller.Protocol=struct([]);
            controller.ProtocolPath=path;
            controller.ProtocolSummary=struct([]);
            controller.setStatus("Protocol file not found — select a pulse protocol."+ ...
                newline+path);
        end

        % ---------------------------------------------------------------
        % Planning artifacts
        % ---------------------------------------------------------------
        function [reference,targets]=buildSpatialArtifacts(controller,options)
            %BUILDSPATIALARTIFACTS Reference model and target bundle for the current FOV.
            arguments
                controller
                options.PulseDurationMs (1,1) double {mustBePositive} = 5
            end
            geometry=controller.FovGeometry;
            if isempty(controller.ReferenceImage) || isempty(geometry.polygons)
                error("adaptive_optopatch:NothingToSave", ...
                    "Load an image and draw at least one soma ROI.");
            end
            parameters=controller.PlanParameters;
            masks=controller.somaMasks();
            fovId=string(matlab.lang.makeValidName( ...
                char(controller.ReferenceInfo.snapshot_name)));
            reference=adaptive_optopatch.create_reference_model( ...
                controller.ReferenceImage,masks,controller.ReferenceInfo.metadata, ...
                "MicronsPerPixel",parameters.microns_per_pixel, ...
                "FovId",fovId, ...
                "SourceExperiment",controller.ReferenceInfo.snapshot_directory, ...
                "CellIds",geometry.cell_ids,"RoiPolygons",geometry.polygons);
            if ~isempty(controller.CellState)
                reference=merge_reference_cell_state(reference,controller.CellState);
            end
            reference.source_snapshot=controller.ReferenceInfo.snapshot_path;
            if ~isempty(controller.LuminosApp)
                reference.luminos_settings_snapshot= ...
                    adaptive_optopatch.snapshot_luminos_settings(controller.LuminosApp);
            else
                reference.luminos_settings_snapshot=struct([]);
            end
            [liveScanner,controller.ScannerWarning]= ...
                adaptive_optopatch.get_live_scanner_calibration(controller.LuminosApp);
            if isempty(liveScanner)
                [persistedScanner,persistedWarning]=persisted_scanner_calibration();
                if ~isempty(persistedScanner)
                    liveScanner=persistedScanner;
                    controller.ScannerWarning="";
                elseif strlength(persistedWarning)>0
                    controller.ScannerWarning= ...
                        controller.ScannerWarning+" "+persistedWarning;
                end
            end
            scannerSampleRate=200000;
            if ~isempty(liveScanner)
                reference.scanner=liveScanner;
                scannerSampleRate=liveScanner.sample_rate;
            elseif isfield(reference,"scanner") && ...
                    isfield(reference.scanner,"raw_archive") && ...
                    isfield(reference.scanner.raw_archive,"sample_rate")
                scannerSampleRate=double(reference.scanner.raw_archive.sample_rate);
            end
            targets=adaptive_optopatch.build_target_bundle(reference, ...
                "SpiralRadiusUm",parameters.spiral_radius_um, ...
                "SpiralDensityPointsPerVolt",parameters.spiral_density_points_per_volt, ...
                "PulseDurationMs",options.PulseDurationMs, ...
                "ScannerSampleRateHz",scannerSampleRate, ...
                "OrangeExpansionPixels",parameters.orange_expansion_pixels, ...
                "BlueMaskAdjustmentPixels",parameters.blue_mask_adjustment_pixels);
        end

        function fovState=currentFovState(controller)
            %CURRENTFOVSTATE Canonical schema-2 FOV state for the current session.
            [reference,~]=controller.buildSpatialArtifacts();
            parameters=controller.PlanParameters;
            fovState=adaptive_optopatch.create_fov_state(reference, ...
                controller.FovGeometry.polygons, ...
                "StimulationMode",parameters.stimulation_mode, ...
                "MicronsPerPixel",parameters.microns_per_pixel, ...
                "SpiralRadiusUm",parameters.spiral_radius_um, ...
                "SpiralDensityPointsPerVolt",parameters.spiral_density_points_per_volt, ...
                "OrangeExpansionPixels",parameters.orange_expansion_pixels, ...
                "BlueMaskAdjustmentPixels",parameters.blue_mask_adjustment_pixels);
            if ~isempty(controller.CellState)
                fovState=merge_cell_state(fovState,controller.CellState);
            end
            fovState.next_cell_index=max(double(fovState.next_cell_index), ...
                controller.FovGeometry.next_cell_index);
        end

        function session=buildSessionState(controller)
            parameters=controller.PlanParameters;
            session=struct;
            session.schema_version="0.3.0";
            session.created_at=string(datetime("now","TimeZone","local"));
            session.source_directory=controller.ReferenceInfo.snapshot_directory;
            session.source_snapshot=controller.ReferenceInfo.snapshot_path;
            session.image_size=size(controller.ReferenceImage);
            session.roi_positions=controller.FovGeometry.polygons;
            session.parameters=struct( ...
                "stimulation_mode",parameters.stimulation_mode, ...
                "microns_per_pixel",parameters.microns_per_pixel, ...
                "spiral_radius_um",parameters.spiral_radius_um, ...
                "spiral_density_points_per_volt",parameters.spiral_density_points_per_volt, ...
                "orange_expansion_pixels",parameters.orange_expansion_pixels, ...
                "blue_mask_adjustment_pixels",parameters.blue_mask_adjustment_pixels, ...
                "screen_repeats",parameters.screen_repeats, ...
                "pulse_count",parameters.pulse_count, ...
                "pulse_duration_ms",parameters.pulse_duration_ms, ...
                "dark_interval_min_ms",parameters.dark_interval_min_ms, ...
                "dark_interval_max_ms",parameters.dark_interval_max_ms, ...
                "pre_delay_ms",parameters.pre_delay_ms, ...
                "post_delay_ms",parameters.post_delay_ms);
        end

        function [reference,targets,manifest]=buildScreenPlanningArtifacts(controller)
            %BUILDSCREENPLANNINGARTIFACTS Standalone connectivity-screen plan.
            parameters=controller.PlanParameters;
            [reference,targets]=controller.buildSpatialArtifacts( ...
                "PulseDurationMs",parameters.pulse_duration_ms);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",parameters.pulse_count, ...
                "PulseDurationMs",parameters.pulse_duration_ms, ...
                "DarkIntervalMs",[parameters.dark_interval_min_ms ...
                    parameters.dark_interval_max_ms], ...
                "PreDelayMs",parameters.pre_delay_ms, ...
                "PostDelayMs",parameters.post_delay_ms,"RandomSeed",1);
            template=definition.acquisitions;
            definition.acquisitions=repmat(template,parameters.screen_repeats,1);
            for repeat=1:parameters.screen_repeats
                definition.acquisitions(repeat).acquisition_id=compose( ...
                    "screen_repeat_%03d",repeat);
            end
            fovState=controller.currentFovState();
            reference=fovState.reference;
            defaults=struct("command_voltage_v",NaN, ...
                "pulse_duration_s",parameters.pulse_duration_ms/1000, ...
                "blue_mask_adjustment_pixels",parameters.blue_mask_adjustment_pixels, ...
                "orange_expansion_pixels",parameters.orange_expansion_pixels, ...
                "spiral_radius_um",parameters.spiral_radius_um, ...
                "spiral_density_points_per_volt",parameters.spiral_density_points_per_volt);
            manifest=adaptive_optopatch.build_manifest(reference,targets,definition, ...
                "Mode",parameters.stimulation_mode,"FovState",fovState, ...
                "GuiDefaults",defaults,"OutputPrefix","connectivity_screen");
        end

        function plan=buildPlan(controller)
            %BUILDPLAN Editable state resolved into a complete run plan.
            if isempty(controller.Protocol)
                error("adaptive_optopatch:PulseProtocolRequired", ...
                    "Load a validated pulse_protocol.mat before previewing or running.");
            end
            parameters=controller.PlanParameters;
            mode=parameters.stimulation_mode;
            protocol=adaptive_optopatch.normalize_protocol(controller.Protocol);
            compatibility=adaptive_optopatch.validate_protocol_for_mode(protocol,mode);
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
            [~,targets]=controller.buildSpatialArtifacts( ...
                "PulseDurationMs",representativePulseMs);
            fovState=controller.currentFovState();
            reference=fovState.reference;
            guiDefaults=struct("command_voltage_v",NaN, ...
                "pulse_duration_s",representativePulseMs/1000, ...
                "blue_mask_adjustment_pixels",parameters.blue_mask_adjustment_pixels, ...
                "orange_expansion_pixels",parameters.orange_expansion_pixels, ...
                "spiral_radius_um",parameters.spiral_radius_um, ...
                "spiral_density_points_per_volt",parameters.spiral_density_points_per_volt);
            [manifest,resolvedProtocols]=adaptive_optopatch.build_manifest( ...
                reference,targets,protocol,"Mode",mode, ...
                "OutputPrefix",string(protocol.protocol_id), ...
                "CurrentObisPowerW",controller.currentObisPowerW(), ...
                "FovState",fovState,"GuiDefaults",guiDefaults);
            session=controller.buildSessionState();
            legacyTimingFields=["screen_repeats","pulse_count","pulse_duration_ms", ...
                "dark_interval_min_ms","dark_interval_max_ms", ...
                "pre_delay_ms","post_delay_ms"];
            for field=legacyTimingFields
                if isfield(session.parameters,field)
                    session.parameters=rmfield(session.parameters,field);
                end
            end
            session.pulse_protocol_path=controller.ProtocolPath;
            session.pulse_protocol_id=string(protocol.protocol_id);
            session.pulse_protocol_summary=controller.ProtocolSummary;
            session.run_controls=controller.captureRunControls();
            plan=struct("schema_version","1.0.0", ...
                "built_at",string(datetime("now","TimeZone","local")), ...
                "software",adaptive_optopatch.software_provenance(), ...
                "reference",reference,"targets",targets,"fov_state",fovState, ...
                "protocol_definition",protocol,"protocol",protocol, ...
                "resolved_protocols",{resolvedProtocols}, ...
                "manifest",manifest,"session",session, ...
                "advisories",manifest.advisories);
        end

        function protocols=resolvedProtocolsForPreview(controller)
            %RESOLVEDPROTOCOLSFORPREVIEW Acquisitions the target preview draws.
            protocols={};
            if isempty(controller.Protocol), return; end
            protocols=controller.buildPlan().resolved_protocols;
        end

        function value=currentPulseDurationMs(controller)
            %CURRENTPULSEDURATIONMS Representative pulse duration for previews.
            value=controller.PlanParameters.pulse_duration_ms;
            if isempty(controller.Protocol), return; end
            protocol=adaptive_optopatch.normalize_protocol(controller.Protocol);
            durations=[];
            for acquisition=protocol.acquisitions
                selected=~acquisition.events.is_null & ...
                    isfinite(acquisition.events.duration_s);
                durations=[durations;acquisition.events.duration_s(selected)]; %#ok<AGROW>
            end
            if ~isempty(durations), value=1000*durations(1); end
        end

        function configuration=sendOrangeRecordingMask(controller)
            [~,targets]=controller.buildSpatialArtifacts();
            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                controller.LuminosApp,targets,"DryRun",false);
            controller.setStatus(sprintf(['Sent Orange recording mask to %s: ' ...
                '%d cells, expansion %d px. Canonical ROIs were unchanged.'], ...
                configuration.dmd_name,configuration.recording_cell_count, ...
                configuration.orange_expansion_pixels));
        end

        function report=preflightPlan(controller,plan)
            %PREFLIGHTPLAN Reject concrete execution incompatibilities.
            issues=strings(0,1);
            parameters=controller.PlanParameters;
            for k=1:height(plan.manifest.trials)
                preflight=adaptive_optopatch.preflight_trial( ...
                    plan.targets,plan.manifest.trials(k,:), ...
                    "RequireConfirmedLiveProtocol",false, ...
                    "LiveProtocolConfirmed",true, ...
                    "Advisories",plan.manifest.advisories);
                issues=[issues;preflight.issues(:)]; %#ok<AGROW>
            end
            mode=parameters.stimulation_mode;
            if mode=="1p_dmd"
                if isempty(issues)
                    hardware=adaptive_optopatch.resolve_luminos_1p_hardware( ...
                        controller.LuminosApp);
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
                        preflight_camera_frames(hardware.cameras, ...
                            globalProps.total_time,false);
                    end
                end
            else
                bundleReport=adaptive_optopatch.validate_2p_planning_bundle(plan.targets);
                issues=[issues;bundleReport.issues(:)];
                if isempty(issues)
                    hardware=adaptive_optopatch.resolve_luminos_2p_hardware( ...
                        controller.LuminosApp,"ApplyCalibration",false);
                    adaptive_optopatch.validate_camera_geometry( ...
                        hardware.voltage_camera,plan.targets);
                    rows=find(~plan.manifest.trials.is_null);
                    for rowIndex=reshape(rows,1,[])
                        row=plan.manifest.trials(rowIndex,:);
                        target=adaptive_optopatch.resolve_trial_target(plan.targets,row);
                        protocol=protocol_with_effective_voltage( ...
                            row.pulse_schedule{1},row.is_null);
                        preview=adaptive_optopatch.build_2p_plan_preview( ...
                            protocol,target,hardware,"ReleaseLevel","standard", ...
                            "MaximumVelocityVPerS",parameters.maximum_velocity_v_per_s, ...
                            "MaximumAccelerationVPerS2", ...
                                parameters.maximum_acceleration_v_per_s2, ...
                            "AllowCalibrationExtrapolation", ...
                                parameters.allow_calibration_extrapolation, ...
                            "TargetingTransform",plan_targeting_transform(plan));
                        [globalProps,~,~]= ...
                            adaptive_optopatch.build_luminos_2p_waveform_config( ...
                            hardware.daq.global_props,hardware.daq.wfm_data, ...
                            preview.waveforms);
                        preflight_camera_frames(hardware.cameras, ...
                            globalProps.total_time, ...
                            parameters.allow_camera_rate_override);
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

        function report=preflightCurrentPlan(controller)
            report=controller.preflightPlan(controller.buildPlan());
        end

        function report=validateCurrentPlan(controller)
            plan=controller.buildPlan();
            report=controller.preflightPlan(plan);
            if ~report.passed, return; end
            if isempty(plan.advisories)
                controller.setStatus(["Configuration check passed. " ...
                    "Runs will rebuild and freeze current settings."]);
            else
                messages=reshape(string({plan.advisories.message}),[],1);
                controller.setStatus([ ...
                    "Configuration check passed with nonblocking advisories:"; ...
                    messages]);
            end
        end

        function waveforms=build2pPreviewWaveforms(controller,plan)
            %BUILD2PPREVIEWWAVEFORMS Galvo/Pockels commands a view can plot.
            parameters=controller.PlanParameters;
            hardware=adaptive_optopatch.resolve_luminos_2p_hardware( ...
                controller.LuminosApp,"ApplyCalibration",false);
            row=plan.manifest.trials(find(~plan.manifest.trials.is_null,1),:);
            target=adaptive_optopatch.resolve_trial_target(plan.targets,row);
            protocol=protocol_with_effective_voltage( ...
                row.pulse_schedule{1},row.is_null);
            preview=adaptive_optopatch.build_2p_plan_preview( ...
                protocol,target,hardware,"ReleaseLevel","standard", ...
                "MaximumVelocityVPerS",parameters.maximum_velocity_v_per_s, ...
                "MaximumAccelerationVPerS2",parameters.maximum_acceleration_v_per_s2, ...
                "AllowCalibrationExtrapolation", ...
                    parameters.allow_calibration_extrapolation, ...
                "TargetingTransform",plan_targeting_transform(plan));
            waveforms=preview.waveforms;
        end

        % ---------------------------------------------------------------
        % Run lifecycle
        % ---------------------------------------------------------------
        function paths=freezeRun(controller,outputRoot)
            %FREEZERUN Archive the current controller state as the active run.
            arguments
                controller
                outputRoot (1,1) string = ""
            end
            controller.assertNotRunning("Freezing a run");
            plan=controller.buildPlan();
            controller.preflightPlan(plan);
            if strlength(outputRoot)==0, outputRoot=controller.defaultRunRoot(); end
            [plan,paths]=controller.saveExecutionBatch(plan,outputRoot,1,struct([]));
            controller.ActiveRunPlan=plan;
            controller.ActiveRunFolder=paths.output_directory;
            controller.LastRun=struct([]);
            controller.EditableStateChanged=false;
            controller.LifecycleState="FROZEN";
            controller.setStatus("Frozen run plan created before acquisition:"+ ...
                newline+controller.ActiveRunFolder);
        end

        function paths=startNewRun(controller,outputRoot)
            %STARTNEWRUN Freeze current editable state as the active run.
            arguments
                controller
                outputRoot (1,1) string = ""
            end
            previousFolder=controller.ActiveRunFolder;
            paths=controller.freezeRun(outputRoot);
            if strlength(previousFolder)>0
                controller.setStatus(["Froze a new run and made it active:"; ...
                    controller.ActiveRunFolder; ...
                    "The previous run remains on disk and can be continued "+ ...
                    "with Resume run…:";previousFolder]);
            end
        end

        function paths=startNewBatch(controller,outputRoot,options)
            %STARTNEWBATCH Reuse one completed frozen definition in a new batch.
            arguments
                controller
                outputRoot (1,1) string = ""
                options.Automatic (1,1) logical = false
            end
            if isempty(controller.ActiveRunPlan) || ...
                    strlength(controller.ActiveRunFolder)==0
                error("adaptive_optopatch:FrozenRunRequired", ...
                    "Freeze or resume a run before starting a new batch.");
            end
            if ~options.Automatic
                controller.assertNotRunning("Starting a new batch");
            end
            if ~batch_is_complete(controller.currentBatchTrials())
                error("adaptive_optopatch:CompletedBatchRequired", ...
                    "Start new batch is available only after the current batch completes.");
            end
            sourcePlan=controller.ActiveRunPlan;
            sourceFolder=controller.ActiveRunFolder;
            sourceBatch=batch_identity(sourcePlan,sourceFolder);
            plan=reresolve_batch_schedule(sourcePlan);
            plan.manifest=reset_execution_state(plan.manifest);
            if strlength(outputRoot)==0
                outputRoot=string(fileparts(char(sourceFolder)));
            end
            [plan,paths]=controller.saveExecutionBatch( ...
                plan,outputRoot,double(sourceBatch.batch_number)+1,sourceBatch);
            controller.ActiveRunPlan=plan;
            controller.ActiveRunFolder=paths.output_directory;
            controller.LastRun=struct([]);
            controller.EditableStateChanged=false;
            controller.LifecycleState="FROZEN";
            controller.setStatus(["Fresh execution batch ready:"; ...
                controller.ActiveRunFolder; ...
                "Same experiment definition with a fresh randomized schedule."; ...
                "Previous completed batch preserved at:";sourceFolder]);
        end

        function value=startNewBatchEnabled(controller)
            value=false;
            if isempty(controller.ActiveRunPlan) || ...
                    strlength(controller.ActiveRunFolder)==0 || ...
                    controller.LifecycleState=="RUNNING"
                return
            end
            value=batch_is_complete(controller.currentBatchTrials());
        end

        function returnToEditing(controller)
            controller.assertNotRunning("Returning to editing");
            controller.ActiveRunPlan=struct([]);
            controller.ActiveRunFolder="";
            controller.LastRun=struct([]);
            controller.LifecycleState="EDITABLE";
            controller.EditableStateChanged=false;
            controller.setStatus( ...
                "Returned to editing. Frozen run artifacts remain on disk.");
        end

        function value=returnToEditingEnabled(controller)
            value=~isempty(controller.ActiveRunPlan) && ...
                strlength(controller.ActiveRunFolder)>0 && ...
                controller.LifecycleState~="RUNNING";
        end

        function plan=resumeRun(controller,folder)
            arguments
                controller
                folder (1,1) string
            end
            controller.assertNotRunning("Resuming a run");
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
            plan.execution_batch=batch_identity(plan,folder);
            controller.ActiveRunPlan=plan;
            controller.ActiveRunFolder=folder;
            controller.LastRun=struct([]);
            controller.EditableStateChanged=false;
            controller.LifecycleState="FROZEN";
            controller.setStatus(["Loaded frozen run for resume. " ...
                "Editable controls were not substituted into it."]);
        end

        function run=runNext(controller)
            run=controller.executePlan(1);
        end

        function run=runAll(controller)
            run=controller.executeRepeatedBatches();
        end

        function stopAfterCurrent(controller)
            %STOPAFTERCURRENT Ask the active runner to stop after this trial.
            controller.StopRequested=true;
            controller.bumpRevision();
        end

        function trials=currentBatchTrials(controller)
            %CURRENTBATCHTRIALS Frozen trials updated by this batch's checkpoint.
            trials=table;
            if isempty(controller.ActiveRunPlan), return; end
            trials=controller.ActiveRunPlan.manifest.trials;
            checkpoint=batch_checkpoint_path(controller.ActiveRunFolder,trials);
            if strlength(checkpoint)==0 || ~isfile(checkpoint), return; end
            saved=load(checkpoint,"run");
            if isfield(saved,"run") && isfield(saved.run,"trials") && ...
                    height(saved.run.trials)==height(trials)
                trials=saved.run.trials;
            end
        end

        function root=defaultRunRoot(controller)
            root=controller.RunRoot;
            if strlength(root)==0 && isfield(controller.ReferenceInfo,"snapshot_directory")
                root=string(controller.ReferenceInfo.snapshot_directory);
            end
            if strlength(root)==0, root=string(pwd); end
        end

        function value=currentObisPowerW(controller)
            value=NaN;
            if isempty(controller.LuminosApp), return; end
            try
                laser=controller.LuminosApp.getDevice("Laser_Device","name","488", ...
                    "displayWarning",false);
                if ~isempty(laser), value=double(laser.SetPower); end
            catch
            end
        end
    end

    methods (Access=private)
        function bumpRevision(controller)
            controller.Revision=controller.Revision+1;
            if isa(controller.StateChangedFcn,"function_handle")
                controller.StateChangedFcn();
            end
        end

        function invalidateCellSummary(controller)
            controller.CellSummaryCache=[];
        end

        function assertNotRunning(controller,action)
            %ASSERTNOTRUNNING Refuse mutations that would corrupt a live run.
            %   The backend enforces this rather than relying on disabled
            %   widgets, so any frontend gets the same protection.
            if controller.LifecycleState=="RUNNING"
                error("adaptive_optopatch:AcquisitionActive", ...
                    "%s is unavailable while an acquisition is active.",action);
            end
        end

        function markEditableChanged(controller)
            % A frozen run (or one loaded via resumeRun) is authoritative
            % once it exists and is never mutated or discarded here:
            % editable edits made afterward apply only to a future run.
            if controller.LifecycleState=="RUNNING", return; end
            controller.EditableStateChanged=true;
            if strlength(controller.ActiveRunFolder)==0
                controller.ActiveRunPlan=struct([]);
                controller.LifecycleState="EDITABLE";
            end
        end

        function adoptReference(controller,image,info)
            controller.ReferenceImage=image;
            controller.ReferenceInfo=info;
            controller.ReferenceRevision=controller.ReferenceRevision+1;
            controller.CellState=struct([]);
            controller.FovGeometry=adaptive_optopatch.create_fov_geometry( ...
                double(size(image,1:2)));
            controller.invalidateCellSummary();
            controller.markEditableChanged();
            controller.bumpRevision();
        end

        function matchSimulatedReferenceCamera(controller,referenceCamera)
            % Real Luminos camera state is owned by Luminos and never changed here.
            if isa(controller.LuminosApp, ...
                    "adaptive_optopatch.testing.SimulatedLuminosApp")
                controller.LuminosApp.matchReferenceCameraGeometry(referenceCamera);
            end
        end

        function applyFovPlanParameters(controller,fovState,reference)
            parameters=controller.PlanParameters;
            if isfield(fovState,"stimulation_mode") && ...
                    ismember(string(fovState.stimulation_mode),["1p_dmd","2p_spiral"])
                parameters.stimulation_mode=string(fovState.stimulation_mode);
            end
            parameters.microns_per_pixel=fov_number(fovState,"microns_per_pixel", ...
                reference.microns_per_pixel,parameters.microns_per_pixel);
            parameters.spiral_radius_um=fov_number(fovState,"spiral_radius_um", ...
                NaN,parameters.spiral_radius_um);
            parameters.spiral_density_points_per_volt=fov_number(fovState, ...
                "spiral_density_points_per_volt",NaN, ...
                parameters.spiral_density_points_per_volt);
            parameters.orange_expansion_pixels=fov_number(fovState, ...
                "orange_expansion_pixels",NaN,parameters.orange_expansion_pixels);
            parameters.blue_mask_adjustment_pixels=fov_number(fovState, ...
                "blue_mask_adjustment_pixels",NaN, ...
                parameters.blue_mask_adjustment_pixels);
            controller.PlanParameters=parameters;
        end

        function value=referenceImageSize(controller)
            value=[0 0];
            if ~isempty(controller.ReferenceImage)
                value=double(size(controller.ReferenceImage,1:2));
            end
        end

        function value=captureRunControls(controller)
            parameters=controller.PlanParameters;
            value=struct("active_obis_power_w",controller.currentObisPowerW(), ...
                "maximum_velocity_v_per_s",parameters.maximum_velocity_v_per_s, ...
                "maximum_acceleration_v_per_s2",parameters.maximum_acceleration_v_per_s2, ...
                "allow_calibration_extrapolation",parameters.allow_calibration_extrapolation, ...
                "allow_camera_rate_override",parameters.allow_camera_rate_override);
        end

        function [plan,paths]=saveExecutionBatch( ...
                controller,plan,outputRoot,batchNumber,sourceBatch) %#ok<INUSL>
            paths=adaptive_optopatch.save_bundle(outputRoot, ...
                plan.reference,plan.targets,plan.manifest, ...
                "CreateSubfolder",true, ...
                "SubfolderPrefix","adaptive_optopatch_run", ...
                "SessionState",plan.session,"FovState",plan.fov_state);
            identity=make_batch_identity( ...
                paths.output_directory,batchNumber,sourceBatch);
            plan.manifest=attach_batch_identity(plan.manifest,identity);
            plan.session.execution_batch=identity;
            plan.execution_batch=identity;
            manifest=plan.manifest; %#ok<NASGU>
            save(paths.manifest,"manifest");
            planning_session=plan.session; %#ok<NASGU>
            save(paths.session,"planning_session","-v7.3");
            paths.protocol=fullfile(paths.output_directory,"pulse_protocol.mat");
            save_frozen_protocol_archive(paths.protocol,plan.resolved_protocols, ...
                plan.manifest.trials.trial_id);
            paths.protocol_definition=fullfile(paths.output_directory, ...
                "protocol_definition.mat");
            adaptive_optopatch.save_protocol(paths.protocol_definition, ...
                plan.protocol_definition);
        end

        function run=executeRepeatedBatches(controller)
            if isempty(controller.ActiveRunPlan) || ...
                    strlength(controller.ActiveRunFolder)==0
                controller.freezeRun();
            end
            batchCount=controller.PlanParameters.repeat_batch_count;
            controller.enterRunningState();
            cleanup=onCleanup(@()controller.finishRunning()); %#ok<NASGU>
            for batch=1:batchCount
                controller.setStatus(sprintf("Running batch %d of %d", ...
                    batch,batchCount));
                run=controller.executePlan(0,"ManageRunState",false);
                if controller.StopRequested || ~batch_is_complete(run.trials)
                    return
                end
                controller.setStatus(sprintf("Completed batch %d of %d", ...
                    batch,batchCount));
                if batch<batchCount
                    controller.startNewBatch("","Automatic",true);
                    controller.LifecycleState="RUNNING";
                end
            end
        end

        function run=executePlan(controller,count,options)
            % Continue an existing active frozen run whenever one exists.
            % Editable changes since freezing do not by themselves trigger a
            % new freeze here; only the absence of an active frozen run does.
            arguments
                controller
                count (1,1) double
                options.ManageRunState (1,1) logical = true
            end
            if isempty(controller.ActiveRunPlan) || ...
                    strlength(controller.ActiveRunFolder)==0
                controller.freezeRun();
            end
            plan=controller.ActiveRunPlan;
            if options.ManageRunState
                controller.enterRunningState();
                cleanup=onCleanup(@()controller.finishRunning()); %#ok<NASGU>
            end
            simulation=isa(controller.LuminosApp, ...
                "adaptive_optopatch.testing.SimulatedLuminosApp");
            outputRoot="";
            if simulation
                outputRoot=fullfile(controller.ActiveRunFolder,"simulation_runs");
            end
            mode=unique(string(plan.manifest.trials.stimulation_mode));
            frozenControls=frozen_run_controls(plan);
            if isequal(mode,"1p_dmd")
                run=adaptive_optopatch.run_1p_manifest( ...
                    plan.manifest,plan.targets,controller.LuminosApp, ...
                    "OutputDirectory",controller.ActiveRunFolder, ...
                    "OutputRoot",outputRoot, ...
                    "Resume",true,"StopAfterTrial",count, ...
                    "ConfirmLiveOutput",true, ...
                    "LaserPowerW",frozenControls.laser_power_w, ...
                    "StopRequestedFcn",@()controller.StopRequested);
            else
                if ~isfield(plan.reference,"scanner") || ...
                        ~isfield(plan.reference.scanner,"tform")
                    error("adaptive_optopatch:FrozenScannerCalibrationMissing", ...
                        "The frozen reference model does not contain a scanner " + ...
                        "targeting calibration to execute this run with.");
                end
                run=adaptive_optopatch.run_2p_manifest( ...
                    plan.manifest,plan.targets,controller.LuminosApp, ...
                    "ReleaseLevel","standard", ...
                    "OutputDirectory",controller.ActiveRunFolder, ...
                    "OutputRoot",outputRoot, ...
                    "Resume",true,"StopAfterTrial",count, ...
                    "ConfirmTrajectoryTest",true,"ConfirmLiveOutput",true, ...
                    "MaximumVelocityVPerS",frozenControls.maximum_velocity_v_per_s, ...
                    "MaximumAccelerationVPerS2",frozenControls.maximum_acceleration_v_per_s2, ...
                    "AllowCalibrationExtrapolation",frozenControls.allow_calibration_extrapolation, ...
                    "AllowCameraRateOverride",frozenControls.allow_camera_rate_override, ...
                    "StopRequestedFcn",@()controller.StopRequested, ...
                    "ScannerCalibration",plan.reference.scanner);
            end
            controller.LastRun=run;
            controller.setStatus("Run stopped normally. Frozen plan: "+ ...
                controller.ActiveRunFolder);
        end

        function enterRunningState(controller)
            controller.LifecycleState="RUNNING";
            controller.StopRequested=false;
            controller.bumpRevision();
        end

        function finishRunning(controller)
            controller.StopRequested=false;
            if controller.LifecycleState=="RUNNING"
                controller.LifecycleState="FROZEN";
            end
            controller.bumpRevision();
        end

        function summary=fovSummary(controller)
            geometry=controller.FovGeometry;
            summary=struct("loaded",~isempty(controller.ReferenceImage), ...
                "fov_id","","rig_name","","camera_name","","camera_bin",NaN, ...
                "snapshot_path","","snapshot_directory","", ...
                "image_size",geometry.image_size, ...
                "reference_revision",controller.ReferenceRevision, ...
                "cell_count",numel(geometry.polygons), ...
                "next_cell_index",geometry.next_cell_index, ...
                "image_coordinate_space","snapshot_intrinsic_pixels");
            info=controller.ReferenceInfo;
            if isempty(info), return; end
            summary.fov_id=info_string(info,"snapshot_name");
            summary.snapshot_path=info_string(info,"snapshot_path");
            summary.snapshot_directory=info_string(info,"snapshot_directory");
            summary.camera_name=info_string(info,"camera_name");
            if isfield(info,"camera_bin"), summary.camera_bin=double(info.camera_bin); end
            if isfield(info,"metadata") && isfield(info.metadata,"rig_name")
                summary.rig_name=string(info.metadata.rig_name);
            end
        end

        function rows=cellRows(controller)
            summary=controller.cellSummary();
            n=numel(summary);
            rows=repmat(struct("cell_id","","recording_enabled",true, ...
                "stimulation_enabled",true,"selected_blue_voltage_v",NaN, ...
                "area_pixels",0,"centroid_xy",[NaN NaN], ...
                "edge_distance_pixels",-1,"qc_status","CHECK", ...
                "vertex_count",0),n,1);
            for k=1:n
                decisions=cell_state_for_id(controller.CellState,summary(k).cell_id);
                rows(k).cell_id=summary(k).cell_id;
                rows(k).recording_enabled=logical(decisions.recording_enabled);
                rows(k).stimulation_enabled=logical(decisions.stimulation_enabled);
                rows(k).selected_blue_voltage_v= ...
                    double(decisions.selected_blue_voltage_v);
                rows(k).area_pixels=summary(k).area_pixels;
                rows(k).centroid_xy=summary(k).centroid_xy;
                rows(k).edge_distance_pixels=summary(k).edge_distance_pixels;
                rows(k).qc_status=summary(k).qc_status;
                rows(k).vertex_count=size(controller.FovGeometry.polygons{k},1);
            end
        end

        function state=protocolState(controller)
            state=struct("loaded",~isempty(controller.Protocol), ...
                "path",controller.ProtocolPath,"summary",struct());
            if ~isempty(controller.ProtocolSummary)
                state.summary=controller.ProtocolSummary;
            end
        end

        function summary=activeRunSummary(controller)
            summary=struct("frozen",false,"folder",controller.ActiveRunFolder, ...
                "batch_id","","batch_number",NaN,"trial_count",0, ...
                "completed_trial_count",0,"batch_complete",false);
            if isempty(controller.ActiveRunPlan) || ...
                    strlength(controller.ActiveRunFolder)==0
                return
            end
            trials=controller.currentBatchTrials();
            identity=batch_identity(controller.ActiveRunPlan, ...
                controller.ActiveRunFolder);
            summary.frozen=true;
            summary.batch_id=string(identity.batch_id);
            summary.batch_number=double(identity.batch_number);
            summary.trial_count=height(trials);
            summary.completed_trial_count=sum(ismember( ...
                string(trials.acquisition_status),["completed","analyzed"]));
            summary.batch_complete=batch_is_complete(trials);
        end
    end
end

function parameters=default_plan_parameters()
%DEFAULT_PLAN_PARAMETERS Canonical editable planning values.
%   These are the values the GUI controls used to hold literally. Blue
%   command voltage is deliberately absent: it is resolved from the
%   protocol, acquisition, event, or per-cell calibration.
parameters=struct( ...
    "stimulation_mode","2p_spiral", ...
    "microns_per_pixel",0.35, ...
    "spiral_radius_um",6, ...
    "spiral_density_points_per_volt",10, ...
    "orange_expansion_pixels",2, ...
    "blue_mask_adjustment_pixels",-1, ...
    "screen_repeats",1, ...
    "pulse_count",200, ...
    "pulse_duration_ms",5, ...
    "dark_interval_min_ms",45, ...
    "dark_interval_max_ms",55, ...
    "pre_delay_ms",100, ...
    "post_delay_ms",100, ...
    "maximum_velocity_v_per_s",1000, ...
    "maximum_acceleration_v_per_s2",6e6, ...
    "allow_calibration_extrapolation",false, ...
    "allow_camera_rate_override",false, ...
    "repeat_batch_count",1);
end

function name=plan_parameter_name(name)
%PLAN_PARAMETER_NAME Resolve an accepted alias to its canonical field.
name=lower(string(name));
aliases=struct("mode","stimulation_mode", ...
    "dmd_erosion_pixels","blue_mask_adjustment_pixels", ...
    "maximum_velocity","maximum_velocity_v_per_s", ...
    "maximum_acceleration","maximum_acceleration_v_per_s2");
if isfield(aliases,char(name)), name=string(aliases.(char(name))); end
if ~isfield(default_plan_parameters(),char(name))
    error("adaptive_optopatch:UnknownPlanParameter", ...
        "Unknown editable plan parameter: %s",name);
end
end

function value=coerce_plan_value(name,value)
switch name
    case "stimulation_mode"
        value=string(value);
        if ~ismember(value,["1p_dmd","2p_spiral"])
            error("adaptive_optopatch:UnknownStimulationMode", ...
                "Stimulation mode must be 1p_dmd or 2p_spiral.");
        end
    case {"allow_calibration_extrapolation","allow_camera_rate_override"}
        value=logical(value);
    otherwise
        value=double(value);
        if ~isscalar(value) || ~isfinite(value)
            error("adaptive_optopatch:InvalidPlanParameter", ...
                "%s must be a finite scalar.",name);
        end
end
end

function voltage=validate_blue_voltage(value)
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

function value=next_index_after(cellIds)
numbers=zeros(numel(cellIds),1);
for k=1:numel(cellIds)
    token=regexp(char(cellIds(k)),'^cell_(\d+)$','tokens','once');
    if ~isempty(token), numbers(k)=str2double(token{1}); end
end
value=max([numbers;0])+1;
end

function info=reference_info_from_model(reference)
metadata=struct("rig_name",reference.rig_name, ...
    "voltage_camera",reference.voltage_camera);
if isfield(reference,"stimulation_dmd")
    metadata.stimulation_dmd=reference.stimulation_dmd;
end
if isfield(reference,"scanner"), metadata.scanner=reference.scanner; end
sourceSnapshot="";
if isfield(reference,"source_snapshot")
    sourceSnapshot=string(reference.source_snapshot);
end
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
info=struct("metadata",metadata,"snapshot_path",sourceSnapshot, ...
    "snapshot_directory",sourceExperiment, ...
    "snapshot_name",string(reference.fov_id), ...
    "image_size",reference.image_size, ...
    "camera_name",cameraName,"camera_bin",cameraBin,"timestamp",[]);
end

function value=info_string(info,name)
value="";
if isfield(info,name), value=string(info.(name)); end
end

function value=fov_number(fovState,name,preferredFallback,currentFallback)
value=currentFallback;
if isfinite(preferredFallback), value=double(preferredFallback); end
if isfield(fovState,name) && isscalar(fovState.(name)) && ...
        isfinite(double(fovState.(name)))
    value=double(fovState.(name));
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

function protocol=protocol_with_effective_voltage(protocol,isNull)
protocol=adaptive_optopatch.normalize_protocol(protocol);
if isNull, protocol.events.command_voltage_v(:)=0; end
end

function controls=frozen_run_controls(plan)
saved=plan.session.run_controls;
controls=struct;
% Luminos/React owns the OBIS setpoint. NaN tells the runner to preserve
% it; the observed value remains archived in the plan.
controls.laser_power_w=NaN;
% Command voltages are resolved per event and frozen into the manifest;
% there is no run-level voltage control to restore.
controls.maximum_velocity_v_per_s=saved.maximum_velocity_v_per_s;
controls.maximum_acceleration_v_per_s2=saved.maximum_acceleration_v_per_s2;
controls.allow_calibration_extrapolation=saved.allow_calibration_extrapolation;
controls.allow_camera_rate_override=saved.allow_camera_rate_override;
end

function preflight_camera_frames(cameras,durationS,allowOverride)
original=arrayfun(@(camera)double(camera.frames_requested),cameras);
cleanup=onCleanup(@()restore_camera_frames(cameras,original)); %#ok<NASGU>
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

function identity=make_batch_identity(folder,batchNumber,source)
[~,batchId]=fileparts(char(folder));
if isempty(source)
    frozenDefinitionId=string(batchId);
    frozenDefinitionDirectory=string(folder);
    rerunOfBatchId="";
    rerunOfBatchDirectory="";
else
    frozenDefinitionId=string(source.frozen_definition_id);
    frozenDefinitionDirectory=string(source.frozen_definition_directory);
    rerunOfBatchId=string(source.batch_id);
    rerunOfBatchDirectory=string(source.batch_directory);
end
identity=struct("schema_version","1.0.0", ...
    "batch_id",string(batchId),"batch_number",double(batchNumber), ...
    "batch_directory",string(folder), ...
    "frozen_definition_id",frozenDefinitionId, ...
    "frozen_definition_directory",frozenDefinitionDirectory, ...
    "rerun_of_batch_id",rerunOfBatchId, ...
    "rerun_of_batch_directory",rerunOfBatchDirectory, ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "randomized_schedule_reused",false);
end

function identity=batch_identity(plan,folder)
if isfield(plan,"execution_batch") && ~isempty(plan.execution_batch)
    identity=plan.execution_batch;
elseif isfield(plan,"manifest") && isfield(plan.manifest,"execution_batch")
    identity=plan.manifest.execution_batch;
elseif isfield(plan,"session") && isfield(plan.session,"execution_batch")
    identity=plan.session.execution_batch;
else
    % Compatibility for frozen runs created before execution-batch metadata.
    identity=make_batch_identity(folder,1,struct([]));
end
end

function manifest=attach_batch_identity(manifest,identity)
manifest.execution_batch=identity;
n=height(manifest.trials);
manifest.trials.batch_id=repmat(identity.batch_id,n,1);
manifest.trials.batch_number=repmat(identity.batch_number,n,1);
manifest.trials.frozen_definition_id= ...
    repmat(identity.frozen_definition_id,n,1);
manifest.trials.rerun_of_batch_id=repmat(identity.rerun_of_batch_id,n,1);
end

function manifest=reset_execution_state(manifest)
n=height(manifest.trials);
manifest.trials.acquisition_status(:)="planned";
for name=["experiment_directory","analysis_status","error_message"]
    if ismember(name,string(manifest.trials.Properties.VariableNames))
        manifest.trials.(name)=repmat("",n,1);
    end
end
for name=["preflight_report","target_configuration","orange_configuration", ...
        "settings_snapshot","waveform_summary","executed_pulse_schedule"]
    if ismember(name,string(manifest.trials.Properties.VariableNames))
        manifest.trials.(name)=cell(n,1);
    end
end
end

function plan=reresolve_batch_schedule(plan)
mode=string(plan.session.parameters.stimulation_mode);
defaults=frozen_gui_defaults(plan);
resolved=adaptive_optopatch.resolve_protocol(plan.protocol_definition, ...
    plan.fov_state,plan.targets,defaults,"Mode",mode, ...
    "FreshRandomization",true);
if numel(resolved)~=height(plan.manifest.trials)
    error("adaptive_optopatch:FrozenPlanMismatch", ...
        "Re-resolving the frozen definition changed the acquisition count.");
end
plan.resolved_protocols=resolved;
for k=1:numel(resolved)
    schedule=resolved{k};
    events=schedule.events;
    used=unique(events.target_cell_id(~events.is_null),"stable");
    if isscalar(used)
        plan.manifest.trials.target_cell_id(k)=used;
        plan.manifest.trials.target_index(k)= ...
            events.target_index(find(~events.is_null,1));
    else
        plan.manifest.trials.target_cell_id(k)="multiple";
        plan.manifest.trials.target_index(k)=NaN;
    end
    plan.manifest.trials.pulse_schedule{k}=schedule;
    plan.manifest.trials.acquisition_duration_s(k)= ...
        schedule.acquisition_duration_s;
end
end

function defaults=frozen_gui_defaults(plan)
firstSchedule=plan.resolved_protocols{1};
firstEvent=firstSchedule.events(1,:);
parameters=plan.session.parameters;
defaults=struct( ...
    "command_voltage_v",NaN, ...
    "pulse_duration_s",double(firstEvent.duration_s), ...
    "blue_mask_adjustment_pixels",double(parameters.blue_mask_adjustment_pixels), ...
    "orange_expansion_pixels",double(parameters.orange_expansion_pixels), ...
    "spiral_radius_um",double(parameters.spiral_radius_um), ...
    "spiral_density_points_per_volt", ...
        double(parameters.spiral_density_points_per_volt));
end

function path=batch_checkpoint_path(folder,trials)
path="";
if strlength(folder)==0 || isempty(trials), return; end
mode=unique(string(trials.stimulation_mode));
if isscalar(mode) && mode=="1p_dmd"
    path=fullfile(folder,"run_checkpoint.mat");
elseif isscalar(mode) && mode=="2p_spiral"
    path=fullfile(folder,"run_2p_checkpoint.mat");
end
end

function value=batch_is_complete(trials)
value=~isempty(trials) && all(ismember( ...
    string(trials.acquisition_status),["completed","analyzed"]));
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

function value=ternary(condition,yes,no)
if condition, value=yes; else, value=no; end
end
