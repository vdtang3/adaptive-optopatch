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
        %REFERENCESOURCEKIND Which of the two things the reference came from.
        %   "snapshot" for a fresh FOV read from a Luminos camera snap,
        %   "ao_fov" for a saved Adaptive Optopatch FOV whose cells and
        %   decisions were restored, "" before anything is loaded or when a
        %   reference was installed directly rather than from a file. A
        %   frontend needs this to say WHICH entry of the unified chooser is
        %   in use, and an AO FOV must never be reported as a camera snap.
        ReferenceSourceKind (1,1) string = ""
        %REFERENCESOURCEPATH The file the reference was loaded from.
        ReferenceSourcePath (1,1) string = ""
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
        %RUNPROGRESS Where one press of Run has got to, across its repeats.
        %   Maintained by the repeat loop so progress is the controller's
        %   answer rather than something a view infers from a batch number
        %   that also advances for other reasons. Empty between runs.
        RunProgress struct = struct([])
    end

    properties
        %STATECHANGEDFCN Called with no arguments after every state change.
        %   One callback, not an observer framework: the MATLAB GUI uses it
        %   to redraw itself from getState().
        StateChangedFcn = []
        RunRoot (1,1) string = ""
        %SNAPSHOTROOT Folder snapshotChoices() offers camera snapshots from.
        %   Empty means the attached Luminos session's own Snaps folder, which
        %   is where Camera_Snap writes. A session that keeps snapshots
        %   elsewhere sets this once; no frontend ever names a folder.
        SnapshotRoot (1,1) string = ""
        %PROTOCOLROOT Folder protocolChoices() offers protocols from.
        %   Empty means adaptive_optopatch.default_protocol_root(), which is
        %   where the generators under pulse-protocols/ write. A session that
        %   keeps its protocols elsewhere sets this once; no frontend ever
        %   names a folder.
        ProtocolRoot (1,1) string = ""
    end

    properties (Access=private)
        LuminosApp = []
        CellSummaryCache = []
        %PROTOCOLCHOICECACHE The listing loadProtocolChoice resolves against.
        ProtocolChoiceCache = []
        %SNAPSHOTCHOICECACHE The listing loadSnapshotChoice resolves against.
        SnapshotChoiceCache = []
        %REFERENCECHOICECACHE The listing loadReferenceChoice resolves against.
        ReferenceChoiceCache = []
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
            % The experimenter-facing lifecycle: one word for what may be
            % done next, why, what the prepared plan would do, and how far
            % a run has got. All four are the controller's answers.
            state.plan_status=controller.planStatus();
            state.plan_readiness=controller.planReadiness();
            state.plan_summary=controller.planSummary();
            state.run_progress=controller.runProgress();
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
            %   `update_plan` and `run` are the experimenter-facing pair and
            %   are answered by planStatus, which is the authority both the
            %   controller's own guards and the action endpoint use. A
            %   frontend renders these; it never works them out for itself,
            %   and a request that ignores them is refused anyway.
            %
            %   `freeze_run`, `return_to_editing` and `start_new_batch`
            %   remain because the MATLAB planning window still offers them
            %   as separate controls. They are internal machinery now: no
            %   action endpoint reaches them, and `update_plan` is the one
            %   name for preparing a plan.
            editing=controller.LifecycleState~="RUNNING";
            hasFov=~isempty(controller.ReferenceImage);
            hasCells=~isempty(controller.FovGeometry.polygons);
            status=controller.planStatus();
            actions=struct( ...
                "edit_cells",editing && hasFov, ...
                "edit_plan_parameters",editing, ...
                "load_protocol",editing, ...
                "load_fov",editing, ...
                "save_fov",editing && hasFov, ...
                "update_plan",status=="update_required" || status=="ready", ...
                "run",status=="ready", ...
                "freeze_run",editing && hasFov && hasCells && ...
                    ~isempty(controller.Protocol), ...
                "stop_after_current",controller.LifecycleState=="RUNNING" && ...
                    ~controller.StopRequested, ...
                "return_to_editing",controller.returnToEditingEnabled(), ...
                "start_new_batch",controller.startNewBatchEnabled(), ...
                "resume_run",editing);
        end

        % ---------------------------------------------------------------
        % The experimenter-facing plan lifecycle
        % ---------------------------------------------------------------
        function inputs=executionInputs(controller)
            %EXECUTIONINPUTS Exactly the state a prepared plan is built from.
            %   THE LIST IS EXPLICIT ON PURPOSE. Revision is bumped by
            %   everything - a status line, a poll that re-reads a
            %   checkpoint, saving a FOV - and equating it with plan
            %   validity would make the plan look stale for reasons that
            %   cannot change what executes. What can change what executes
            %   is enumerated here, grouped so that a stale plan can say
            %   WHICH group moved.
            %
            %   Audited against buildPlan():
            %
            %     reference       create_reference_model reads the image,
            %                     the camera identity and the crop.
            %     somata          canonical polygons and stable IDs are
            %                     rasterised into the ROI masks.
            %     cell_decisions  stimulation_enabled selects targets (a
            %                     deselected cell drops its acquisition),
            %                     recording_enabled selects the Orange
            %                     mask, and selected_blue_voltage_v is the
            %                     resolver's fov_cell tier.
            %     protocol        the definition itself, not its name: two
            %                     files can share a protocol_id.
            %     spatial         the plan parameters build_target_bundle
            %                     and create_reference_model consume.
            %     run_controls    what captureRunControls archives and
            %                     frozen_run_controls restores at
            %                     execution, including how many repeats one
            %                     press of Run performs.
            %
            %   Deliberately absent: status text, the loaded run folder,
            %   the reference display stretch, the legacy timing defaults
            %   (buildPlan strips them from the session and every onset
            %   comes from the protocol), and the live scanner calibration
            %   and OBIS power - those are hardware readings rather than
            %   operator decisions, and the transform a frozen run will
            %   execute is archived with it rather than re-read.
            parameters=controller.PlanParameters;
            rows=controller.cellRows();

            inputs=struct("schema_version","1.0.0");
            inputs.reference=struct( ...
                "fov_id",info_string(controller.ReferenceInfo,"snapshot_name"), ...
                "snapshot_path",info_string(controller.ReferenceInfo,"snapshot_path"), ...
                "image_size",controller.referenceImageSize(), ...
                "reference_revision",controller.ReferenceRevision);

            somata=struct("cell_ids",reshape(controller.FovGeometry.cell_ids,[],1));
            somata.polygons=reshape(controller.FovGeometry.polygons,[],1);
            inputs.somata=somata;

            % The three decisions, and nothing else from the cell record:
            % calibration history, notes and acquisition provenance travel
            % with a cell but cannot change what executes, and including
            % them would let saving a FOV stale the plan.
            inputs.cell_decisions=struct( ...
                "cell_ids",reshape([rows.cell_id],[],1), ...
                "recording_enabled",reshape([rows.recording_enabled],[],1), ...
                "stimulation_enabled",reshape([rows.stimulation_enabled],[],1), ...
                "selected_blue_voltage_v", ...
                    reshape([rows.selected_blue_voltage_v],[],1));

            inputs.protocol=struct("path",controller.ProtocolPath);
            inputs.protocol.definition=controller.Protocol;

            inputs.spatial=struct( ...
                "stimulation_mode",parameters.stimulation_mode, ...
                "microns_per_pixel",parameters.microns_per_pixel, ...
                "spiral_radius_um",parameters.spiral_radius_um, ...
                "spiral_density_points_per_volt", ...
                    parameters.spiral_density_points_per_volt, ...
                "orange_expansion_pixels",parameters.orange_expansion_pixels, ...
                "blue_mask_adjustment_pixels", ...
                    parameters.blue_mask_adjustment_pixels);

            inputs.run_controls=controller.captureRunControls();
            % Observed rather than chosen: it is archived for provenance and
            % must not make a plan look out of date when the laser drifts.
            inputs.run_controls=rmfield(inputs.run_controls, ...
                "active_obis_power_w");
        end

        function issues=planBlockingIssues(controller)
            %PLANBLOCKINGISSUES Why no plan could be prepared at all.
            %   The structural prerequisites of buildPlan, in the order an
            %   operator meets them. Anything subtler than these is left to
            %   updatePlan's own validation, which reports the canonical
            %   message rather than a second opinion about it.
            issues=strings(0,1);
            if isempty(controller.ReferenceImage)
                issues(end+1,1)="Load a reference FOV.";
            end
            if isempty(controller.FovGeometry.polygons)
                issues(end+1,1)="Draw at least one soma.";
            elseif ~any([controller.cellRows().stimulation_enabled])
                % NoAcceptedTargets otherwise, at resolution time.
                issues(end+1,1)= ...
                    "Enable Stim on at least one cell.";
            end
            if isempty(controller.Protocol)
                issues(end+1,1)="Load a pulse protocol.";
            end
        end

        function names=stalePlanInputs(controller)
            %STALEPLANINPUTS Which groups of inputs the prepared plan predates.
            %   Empty when there is no prepared plan to compare against:
            %   "there is nothing prepared" and "what is prepared is out of
            %   date" are different answers and planStatus tells them apart.
            names=strings(0,1);
            plan=controller.ActiveRunPlan;
            if isempty(plan) || ~isfield(plan,"execution_inputs"), return; end
            current=controller.executionInputs();
            prepared=plan.execution_inputs;
            for name=reshape(string(fieldnames(current)),1,[])
                if name=="schema_version", continue; end
                if ~isfield(prepared,name) || ...
                        ~isequaln(prepared.(name),current.(name))
                    names(end+1,1)=name; %#ok<AGROW>
                end
            end
        end

        function value=planStatus(controller)
            %PLANSTATUS What the experimenter may do next, in one word.
            %
            %     not_ready        the experiment is not describable yet
            %     update_required  describable, but nothing prepared matches it
            %     ready            a prepared plan matches the current inputs
            %     running          an acquisition is in progress
            %
            %   AUTHORITATIVE. Run and Update plan are gated on this, here,
            %   so a direct endpoint call is refused by the same rule a
            %   button is greyed out by. A frontend renders it; it does not
            %   compute it.
            if controller.LifecycleState=="RUNNING", value="running"; return; end
            if ~isempty(controller.planBlockingIssues()), value="not_ready"; return; end
            if isempty(controller.ActiveRunPlan) || ...
                    strlength(controller.ActiveRunFolder)==0
                value="update_required"; return
            end
            if ~isempty(controller.stalePlanInputs())
                value="update_required"; return
            end
            value="ready";
        end

        function report=planReadiness(controller)
            %PLANREADINESS planStatus, and why it is what it is.
            status=controller.planStatus();
            stale=controller.stalePlanInputs();
            report=struct("schema_version","1.0.0","status",status, ...
                "can_update_plan",status=="update_required" || status=="ready", ...
                "can_run",status=="ready", ...
                "blocking_issues",controller.planBlockingIssues(), ...
                "stale_inputs",stale, ...
                "prepared",~isempty(controller.ActiveRunPlan) && ...
                    strlength(controller.ActiveRunFolder)>0);
            report.message=plan_status_message(status,report);
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
            controller.ReferenceSourceKind="snapshot";
            controller.ReferenceSourcePath=snapshotPath;
            controller.setStatus(sprintf(['Loaded snapshot:\n%s\nCamera: %s, ' ...
                '%d × %d pixels, binning %.3g.'],info.snapshot_path, ...
                info.camera_name,info.image_size(2),info.image_size(1), ...
                info.camera_bin));
        end

        function choices=snapshotChoices(controller)
            %SNAPSHOTCHOICES Camera snapshots a frontend may ask to have loaded.
            %   MATLAB discovers them; a frontend chooses a choice_id out of
            %   this list. Read from disk on demand rather than carried in
            %   getState(), which is polled and must stay cheap - and this one
            %   opens an image per candidate to answer `loadable` honestly.
            %
            %   The folder of the currently loaded snapshot is always
            %   included, so the reference in use stays visible and is marked
            %   is_current even when the session's Snaps folder has rolled
            %   over to a new day.
            choices=adaptive_optopatch.list_snapshot_choices( ...
                "Roots",controller.snapshotSearchRoots());
            currentPath=info_string(controller.ReferenceInfo,"snapshot_path");
            for k=1:numel(choices)
                choices(k).is_current=strlength(currentPath)>0 && ...
                    choices(k).path==currentPath;
            end
            controller.SnapshotChoiceCache=choices;
        end

        function loadSnapshotChoice(controller,choiceId)
            %LOADSNAPSHOTCHOICE Load one snapshot named by snapshotChoices().
            %   The id is resolved against a listing this controller produced,
            %   never treated as a path. An id that is not in the current
            %   listing is rejected rather than guessed at - which is what
            %   happens when a file has been removed, or renamed, since the
            %   frontend last asked.
            %
            %   The load itself is loadSnapshot: one canonical path into the
            %   reference FOV, shared with the MATLAB GUI, so camera identity,
            %   crop origin, binning and the DMD transforms recorded with the
            %   snap are read exactly once and in one place.
            arguments
                controller
                choiceId (1,1) string
            end
            choices=controller.SnapshotChoiceCache;
            if isempty(choices) || ~known_and_present(choices,choiceId)
                % Re-listed when the id is unknown OR when the file behind it
                % has gone since the listing was made. Both are the same thing
                % to an operator - the list is out of date - and a stale cache
                % must not turn into a file-not-found naming a path they
                % never chose.
                choices=controller.snapshotChoices();
            end
            index=find([choices.choice_id]==choiceId,1);
            if isempty(index)
                error("adaptive_optopatch:UnknownSnapshotChoice", ...
                    "No camera snapshot is offered as '%s'. Refresh the " + ...
                    "snapshot list and choose again.",choiceId);
            end
            controller.loadSnapshot(choices(index).path);
        end

        function choices=referenceChoices(controller)
            %REFERENCECHOICES Everything this session can start a FOV from.
            %   One listing, two kinds: camera snapshots and saved Adaptive
            %   Optopatch FOVs (see list_reference_choices). MATLAB
            %   discovers them; a frontend picks a choice_id out of this
            %   list and sends that and nothing else.
            %
            %   Read from disk on demand rather than carried in getState(),
            %   which is polled and must stay cheap - this opens an image
            %   per snapshot and a MAT per bundle to answer `loadable`
            %   honestly.
            choices=adaptive_optopatch.list_reference_choices( ...
                "Roots",controller.snapshotSearchRoots());
            currentPath=controller.ReferenceSourcePath;
            for k=1:numel(choices)
                choices(k).is_current=strlength(currentPath)>0 && ...
                    choices(k).path==currentPath;
            end
            controller.ReferenceChoiceCache=choices;
        end

        function loadReferenceChoice(controller,choiceId)
            %LOADREFERENCECHOICE Load one entry named by referenceChoices().
            %   The id is resolved against a listing this controller
            %   produced, never treated as a path, exactly as
            %   loadSnapshotChoice does - and for the same reason.
            %
            %   The listing says which of the two canonical paths the entry
            %   takes, and this dispatches to it unchanged:
            %
            %     snapshot -> loadSnapshot, a fresh FOV with no cells
            %     ao_fov   -> loadFov, restoring geometry, stable IDs,
            %                 eligibility, calibration and provenance
            %
            %   Nothing here blends the two. An Adaptive Optopatch FOV is
            %   not read through the snapshot reader and does not pretend to
            %   be a camera snap.
            arguments
                controller
                choiceId (1,1) string
            end
            choices=controller.ReferenceChoiceCache;
            if isempty(choices) || ~known_and_present(choices,choiceId)
                % Re-listed when the id is unknown OR the file behind it has
                % gone since the listing was made. Both mean the same thing
                % to an operator - the list is out of date - and a stale
                % cache must not become a file-not-found naming a path they
                % never chose.
                choices=controller.referenceChoices();
            end
            index=find([choices.choice_id]==choiceId,1);
            if isempty(index)
                error("adaptive_optopatch:UnknownReferenceChoice", ...
                    "No reference is offered as '%s'. Refresh the list " + ...
                    "and choose again.",choiceId);
            end
            choice=choices(index);
            if ~choice.loadable
                % The listing already opened this file and could not read
                % it. Refused here with the reason it recorded, rather than
                % left to fail deeper as a raw MAT-file error: an operator
                % gets MATLAB's own explanation, and a genuine fault stays
                % distinguishable from a file that is simply not loadable.
                error("adaptive_optopatch:UnloadableReferenceChoice", ...
                    "'%s' cannot be loaded: %s Refresh the list if this " + ...
                    "has since changed.",choiceId,choice.issue);
            end
            switch choice.kind
                case "snapshot"
                    controller.loadSnapshot(choice.path);
                case "ao_fov"
                    controller.loadFov(choice.path);
                otherwise
                    error("adaptive_optopatch:UnknownReferenceKind", ...
                        "'%s' is offered as kind '%s', which this " + ...
                        "package does not know how to load.", ...
                        choiceId,choice.kind);
            end
        end

        function [path,fovState]=saveNextFov(controller)
            %SAVENEXTFOV Save the current FOV as the next numbered bundle.
            %   Writes <snapshot>_FOV###.mat beside the camera snapshot this
            %   FOV was drawn on, taking the next unused number. It never
            %   replaces an existing bundle and never touches the snapshot
            %   itself - see next_fov_bundle_path.
            %
            %   The bundle is the existing schema-2 FOV state, written by
            %   the existing save_fov_state, so what comes back through
            %   loadFov is what every other saved FOV carries. There is
            %   deliberately no second persistence format for "the FOV a
            %   browser saved".
            controller.assertNotRunning("Saving a FOV");
            [folder,stem]=controller.fovBundleIdentity();
            path=adaptive_optopatch.next_fov_bundle_path(folder,stem);
            fovState=controller.saveFov(path);
            % The listing now has an entry it did not have, and the newly
            % written bundle is what the session is working from.
            controller.ReferenceSourceKind="ao_fov";
            controller.ReferenceSourcePath=path;
            controller.ReferenceChoiceCache=[];
            controller.setStatus(sprintf( ...
                "Saved FOV %s with %d cells to\n%s", ...
                fovState.fov_id,numel(fovState.cells),path));
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
            %LOADFOV Restore a saved Adaptive Optopatch FOV from its bundle.
            %   The canonical path for kind="ao_fov" in the unified chooser,
            %   and the one the MATLAB planning window's file dialog uses.
            %   Everything about what a bundle contains, and what restoring
            %   it means, is setFovState's; this adds only the file.
            arguments
                controller
                path (1,1) string
            end
            fovState=adaptive_optopatch.load_fov_state(path);
            controller.setFovState(fovState);
            controller.ReferenceSourceKind="ao_fov";
            controller.ReferenceSourcePath=path;
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
            % A saved FOV, whether or not it arrived from a file: loadFov
            % adds the path afterwards. Never "snapshot" - the cells and
            % decisions restored here are exactly what a snapshot has none of.
            controller.ReferenceSourceKind="ao_fov";
            controller.ReferenceSourcePath="";
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

        function display=referenceDisplayImage(controller)
            %REFERENCEDISPLAYIMAGE Eight-bit view of the reference FOV.
            %   Deliberately not part of getState(): a state snapshot is read
            %   about once a second by every open frontend, and an image on
            %   that poll would put a camera frame on the wire each time. A
            %   view fetches this separately, and only when
            %   fov.reference_revision says the reference has changed.
            %
            %   Same size as the reference image, so a pixel here is the same
            %   pixel there and snapshot-intrinsic coordinates carry over
            %   unchanged. Empty before a reference is loaded.
            %
            %   READ ONLY: it derives a picture from state that already
            %   exists and bumps no revision.
            display=adaptive_optopatch.reference_display_image( ...
                controller.ReferenceImage);
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

        function choices=protocolChoices(controller)
            %PROTOCOLCHOICES Protocols a frontend may ask to have loaded.
            %   MATLAB discovers them; a frontend chooses a choice_id out of
            %   this list. Read from disk on demand rather than carried in
            %   getState(), which is polled and must stay cheap.
            %
            %   The folder of an already loaded protocol is always included,
            %   so a protocol loaded from somewhere else stays selectable and
            %   is marked is_current.
            choices=adaptive_optopatch.list_protocol_choices( ...
                "Roots",controller.protocolSearchRoots());
            for k=1:numel(choices)
                choices(k).is_current=strlength(controller.ProtocolPath)>0 && ...
                    choices(k).path==controller.ProtocolPath;
            end
            controller.ProtocolChoiceCache=choices;
        end

        function protocol=loadProtocolChoice(controller,choiceId)
            %LOADPROTOCOLCHOICE Load one protocol named by protocolChoices().
            %   The id is resolved against a listing this controller produced,
            %   never treated as a path. An id that is not in the current
            %   listing is rejected rather than guessed at - which is what
            %   happens when a file has been removed since the frontend last
            %   asked.
            arguments
                controller
                choiceId (1,1) string
            end
            choices=controller.ProtocolChoiceCache;
            if isempty(choices) || ~any([choices.choice_id]==choiceId)
                choices=controller.protocolChoices();
            end
            index=find([choices.choice_id]==choiceId,1);
            if isempty(index)
                error("adaptive_optopatch:UnknownProtocolChoice", ...
                    "No pulse protocol is offered as '%s'. Refresh the " + ...
                    "protocol list and choose again.",choiceId);
            end
            protocol=controller.loadProtocol(choices(index).path);
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

        function preview=spatialPreview(controller,mode)
            %SPATIALPREVIEW Canonical targeting geometry, as outlines to draw.
            %   The same preview the MATLAB planning window draws with
            %   "Preview targets", in the same coordinates, computed by the
            %   same canonical code: buildSpatialArtifacts for the target
            %   bundle, build_target_preview for the masks and spiral
            %   specifications - which derive Blue masks through
            %   apply_blue_mask_adjustment and 2P geometry through
            %   apply_acquisition_parameters when a protocol is loaded - and
            %   generate_spiral_preview for the scan path itself.
            %
            %   What is returned is OUTLINES, not masks: bwboundaries of the
            %   same logical masks the GUI plots, in snapshot-intrinsic
            %   pixels, so a frontend draws the boundary MATLAB computed
            %   rather than rasterising or eroding anything itself. Nothing
            %   here reconstructs erosion, expansion or spiral geometry
            %   outside the canonical functions.
            %
            %   READ ONLY AND HARDWARE-INERT. It builds artifacts in memory
            %   and measures them. No mask is programmed, no scanner moves,
            %   no DAQ output is written, and the controller's canonical
            %   state is unchanged - including ScannerWarning, which
            %   buildSpatialArtifacts refreshes and which is restored here
            %   and reported in the payload instead, so that asking for a
            %   preview cannot change what the state poll says.
            arguments
                controller
                mode (1,1) string ...
                    {mustBeMember(mode,["1p_dmd","2p_spiral"])}
            end
            preview=struct("schema_version","1.0.0","mode",mode, ...
                "available",false,"message","","source","", ...
                "coordinate_space","snapshot_intrinsic_pixels", ...
                "image_size",controller.referenceImageSize(), ...
                "reference_revision",controller.ReferenceRevision, ...
                "revision",controller.Revision,"scanner_warning","");
            preview.blue=empty_outline_array();
            preview.orange=empty_outline_array();
            preview.spiral=empty_spiral_array();
            if isempty(controller.ReferenceImage)
                preview.message="Load a reference FOV to preview targeting.";
                return
            end
            if isempty(controller.FovGeometry.polygons)
                preview.message="Draw at least one soma to preview targeting.";
                return
            end
            warningBefore=controller.ScannerWarning;
            restore=onCleanup(@()set_scanner_warning(controller,warningBefore));
            [~,targets]=controller.buildSpatialArtifacts( ...
                "PulseDurationMs",controller.currentPulseDurationMs());
            canonical=adaptive_optopatch.build_target_preview(targets,mode, ...
                "ResolvedProtocols",controller.resolvedProtocolsForPreview(), ...
                "ScannerTransform",targets.scanner_transform, ...
                "ScannerSampleRateHz",targets.parameters.scanner_sample_rate_hz);
            preview.available=true;
            preview.source=string(canonical.source);
            preview.scanner_warning=controller.ScannerWarning;
            for k=1:numel(canonical.orange)
                preview.orange(end+1,1)=mask_outline( ...
                    canonical.orange(k).mask,canonical.orange(k).cell_id, ...
                    "expansion_pixels", ...
                    canonical.orange(k).expansion_pixels);
            end
            for k=1:numel(canonical.blue)
                preview.blue(end+1,1)=mask_outline( ...
                    canonical.blue(k).mask,canonical.blue(k).cell_id, ...
                    "adjustment_pixels", ...
                    canonical.blue(k).adjustment_pixels);
            end
            for k=1:numel(canonical.spiral)
                preview.spiral(end+1,1)= ...
                    spiral_geometry(canonical.spiral(k));
            end
        end

        function preview=waveformPreview(controller,options)
            %WAVEFORMPREVIEW Plotting-ready commands for the frozen-shape plan.
            %   The same thing the MATLAB planning window's Preview button
            %   plots, produced by the same canonical code and handed over
            %   as numbers instead of drawn into an axes:
            %
            %     2p_spiral   build2pPreviewWaveforms, which is
            %                 build_2p_plan_preview -> build_2p_trial_waveforms:
            %                 the galvo X and Y commands and the Pockels
            %                 command, in volts, at the scanner sample rate.
            %
            %     1p_dmd      flatten_pulse_schedule on the resolved
            %                 acquisition, rendered as the mod488 step trace
            %                 the GUI plots, plus every event's target,
            %                 timing and command voltage.
            %
            %   No schedule resolution, no waveform synthesis and no
            %   attenuation happens anywhere but in those functions. A
            %   frontend receives samples and draws them.
            %
            %   READ ONLY AND HARDWARE-INERT. Both paths resolve hardware
            %   with ApplyCalibration=false - the live scanner's targeting
            %   transform is never overwritten - and neither writes a DAQ
            %   output, programs a DMD, moves a scanner nor touches a
            %   shutter. Nothing is committed and no revision is bumped.
            %
            %   Only the channels the canonical preview produces are
            %   reported. Orange illumination and the camera trigger are not
            %   among them: those are built by
            %   build_luminos_1p_waveform_config and
            %   build_luminos_2p_waveform_config at execution setup, against
            %   live devices, and a read-only preview does not manufacture
            %   stand-ins for them. The acquisition duration every channel
            %   is drawn against is reported instead.
            arguments
                controller
                %MAXIMUMPOINTS Samples per channel a view is asked to draw.
                options.MaximumPoints (1,1) double ...
                    {mustBePositive,mustBeInteger} = 4000
            end
            mode=controller.PlanParameters.stimulation_mode;
            preview=struct("schema_version","1.0.0","available",false, ...
                "message","","mode",mode,"revision",controller.Revision, ...
                "acquisition_id","","protocol_id","", ...
                "duration_s",NaN,"sample_rate_hz",NaN, ...
                "decimation_step",1,"truncated",false, ...
                "window_s",[0 0],"time_s",[]);
            preview.channels=empty_channel_array();
            preview.events=empty_waveform_event_array();
            preview.targets=empty_target_summary_array();
            if isempty(controller.Protocol)
                preview.message="Load a pulse protocol to preview waveforms.";
                return
            end
            if isempty(controller.ReferenceImage) || ...
                    isempty(controller.FovGeometry.polygons)
                preview.message=["A reference FOV with at least one soma " ...
                    "is needed before a waveform can be resolved."];
                return
            end
            warningBefore=controller.ScannerWarning;
            restore=onCleanup(@()set_scanner_warning(controller,warningBefore));
            plan=controller.buildPlan();
            preview.protocol_id=string(plan.protocol.protocol_id);
            if mode=="2p_spiral"
                preview=fill_2p_waveform_preview(preview, ...
                    controller.build2pPreviewWaveforms(plan), ...
                    options.MaximumPoints);
            else
                preview=fill_1p_waveform_preview(preview,plan, ...
                    options.MaximumPoints);
            end
            preview.available=true;
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
            accountingReports={};
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
                        [globalProps,wfmData]= ...
                            adaptive_optopatch.build_luminos_1p_waveform_config( ...
                            hardware.daq.global_props,hardware.daq.wfm_data, ...
                            resolved,adaptive_optopatch.virtual_upright_1p_profile(), ...
                            "DmdSequencePlan",sequencePlan);
                        accounting=adaptive_optopatch.account_stimulation_outputs( ...
                            globalProps,wfmData,"Modality","1p_dmd", ...
                            "Context",sprintf("preflight trial %d",rowIndex));
                        accountingReports{end+1}=accounting; %#ok<AGROW>
                        issues=[issues;accounting.blocking(:)]; %#ok<AGROW>
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
                        [globalProps,wfmData,~]= ...
                            adaptive_optopatch.build_luminos_2p_waveform_config( ...
                            hardware.daq.global_props,hardware.daq.wfm_data, ...
                            preview.waveforms);
                        accounting=adaptive_optopatch.account_stimulation_outputs( ...
                            globalProps,wfmData,"Modality","2p_spiral", ...
                            "Context",sprintf("preflight trial %d",rowIndex));
                        accountingReports{end+1}=accounting; %#ok<AGROW>
                        issues=[issues;accounting.blocking(:)]; %#ok<AGROW>
                        preflight_camera_frames(hardware.cameras, ...
                            globalProps.total_time, ...
                            parameters.allow_camera_rate_override);
                    end
                end
            end
            issues=unique(issues(strlength(issues)>0),"stable");
            report=struct("schema_version","0.2.0","passed",isempty(issues), ...
                "validated_at",string(datetime("now","TimeZone","local")), ...
                "mode",mode,"issues",issues);
            % Accounting reaches the experimenter through the validation the
            % lifecycle already runs, rather than through a second status of
            % its own. Under report-only its unaccounted terminals arrive
            % here as advisories; what the code can prove unsafe arrived
            % above, in issues, and has already failed the plan.
            report.stimulation_accounting=accountingReports;
            report.stimulation_advisories=accounting_advisories(accountingReports);
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
            messages=strings(0,1);
            if ~isempty(plan.advisories)
                messages=[messages;reshape(string({plan.advisories.message}),[],1)];
            end
            messages=[messages;report.stimulation_advisories(:)];
            if isempty(messages)
                controller.setStatus(["Configuration check passed. " ...
                    "Runs will rebuild and freeze current settings."]);
            else
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
            % What this plan was built from, so a later edit can be seen to
            % have invalidated it. In memory with the plan rather than in
            % the bundle: it describes the controller's editable state at
            % freeze time, not the archived artifact, and the artifact is
            % already complete without it.
            plan.execution_inputs=controller.executionInputs();
            controller.ActiveRunPlan=plan;
            controller.ActiveRunFolder=paths.output_directory;
            controller.LastRun=struct([]);
            % A new plan has not been run. Progress is cleared here rather
            % than when a run ends, so a finished run keeps reporting the
            % count it reached instead of snapping back to zero the moment
            % the last acquisition lands.
            controller.RunProgress=struct([]);
            controller.EditableStateChanged=false;
            controller.LifecycleState="FROZEN";
            controller.setStatus("Frozen run plan created before acquisition:"+ ...
                newline+controller.ActiveRunFolder);
        end

        function paths=updatePlan(controller)
            %UPDATEPLAN Prepare the current experiment for execution.
            %   THE experimenter-facing preparation step, and deliberately
            %   nothing new: it is freezeRun, which already validates,
            %   resolves the protocol against the FOV, builds the targets,
            %   preflights the result, archives an immutable execution plan
            %   and makes it active. What this adds is the record of WHICH
            %   inputs that plan was built from, so that a later edit can
            %   be seen to have invalidated it.
            %
            %   It is called Update plan rather than Upload plan because it
            %   uploads nothing: no DMD pattern is programmed, no scanner
            %   moves and no DAQ output is written. Whatever hardware
            %   preparation an acquisition needs still happens inside the
            %   runners, unchanged.
            controller.assertNotRunning("Updating the plan");
            issues=controller.planBlockingIssues();
            if ~isempty(issues)
                error("adaptive_optopatch:PlanNotReady","%s", ...
                    strjoin(["The experiment is not ready to be prepared:";
                        issues],newline));
            end
            paths=controller.freezeRun();
            controller.setStatus(["Plan updated and ready to run.";
                controller.planSummaryText();
                controller.ActiveRunFolder]);
        end

        function assertRunnable(controller)
            %ASSERTRUNNABLE Refuse anything but a prepared, current plan.
            %   The gate, on its own, so that the rule lives in exactly one
            %   place: runPreparedPlan calls it, legalActions reports the
            %   same answer through planStatus, and the action endpoint
            %   inherits both rather than re-deciding.
            status=controller.planStatus();
            if status=="ready", return; end
            error(plan_refusal_identifier(status),"%s", ...
                controller.planReadiness().message);
        end

        function run=runPreparedPlan(controller)
            %RUNPREPAREDPLAN Execute the prepared experiment, start to finish.
            %   ONE Run. It executes the whole prepared plan - every
            %   acquisition of it - and then repeats it as many times as
            %   the plan was prepared for. There is no experimenter-facing
            %   single-acquisition run: an operator who wants one cell
            %   deselects Stim on the others and updates the plan, which
            %   makes what runs visible in the summary beforehand rather
            %   than implicit in which button was pressed.
            %
            %   GATED HERE, not in a frontend. A plan that is absent,
            %   stale, unpreparable or already running is refused by the
            %   controller, so a direct endpoint call cannot do what a
            %   greyed-out button will not.
            controller.assertRunnable();
            % A completed plan is still a valid plan: with nothing changed,
            % Run means run it again. startNewBatch is the existing
            % transition for that - a sibling run folder from the same
            % frozen definition, with its own checkpoint - and is exactly
            % what the repeat loop already uses between repeats.
            if batch_is_complete(controller.currentBatchTrials())
                controller.startNewBatch();
            end
            run=controller.executeRepeatedBatches();
        end

        function summary=planSummary(controller)
            %PLANSUMMARY What the prepared plan will actually do.
            %   Derived from the prepared manifest, not from the editable
            %   state and not from anything a view could add up. The
            %   distinction that matters: a manifest ROW is one acquisition
            %   (build_manifest sets one_acquisition_per_row), and an
            %   acquisition contains many events, so events are neither
            %   acquisitions nor pulses per cell.
            summary=struct("schema_version","1.0.0","prepared",false, ...
                "stimulating_cell_count",0,"acquisitions_per_repeat",0, ...
                "repeats",double(controller.PlanParameters.repeat_batch_count), ...
                "total_acquisitions",0,"light_event_count",0, ...
                "acquisition_duration_s",NaN,"protocol_id","", ...
                "stimulating_cell_ids",strings(0,1));
            plan=controller.ActiveRunPlan;
            if isempty(plan) || ~isfield(plan,"manifest"), return; end
            trials=plan.manifest.trials;
            summary.prepared=true;
            summary.protocol_id=string(plan.manifest.source_protocol_id);
            summary.acquisitions_per_repeat=height(trials);
            summary.repeats=prepared_repeat_count(plan, ...
                controller.PlanParameters.repeat_batch_count);
            summary.total_acquisitions= ...
                summary.acquisitions_per_repeat*summary.repeats;
            summary.acquisition_duration_s= ...
                sum(double(trials.acquisition_duration_s));
            % Which cells actually receive light, read off the resolved
            % schedules rather than off the eligibility checkboxes: a cell
            % can be enabled and still not be addressed by the protocol.
            cells=strings(0,1); lightEvents=0;
            for k=1:height(trials)
                events=trials.pulse_schedule{k}.events;
                illuminated=~events.is_null;
                lightEvents=lightEvents+sum(illuminated);
                cells=[cells;string(events.target_cell_id(illuminated))]; %#ok<AGROW>
            end
            summary.stimulating_cell_ids=unique(cells,"stable");
            summary.stimulating_cell_count=numel(summary.stimulating_cell_ids);
            summary.light_event_count=lightEvents;
        end

        function line=planSummaryText(controller)
            %PLANSUMMARYTEXT One line of the summary, for the status area.
            summary=controller.planSummary();
            if ~summary.prepared, line="No plan is prepared."; return; end
            line=sprintf(['%d stimulating cells, %d acquisitions per ' ...
                'repeat, %d repeats, %d acquisitions in total.'], ...
                summary.stimulating_cell_count, ...
                summary.acquisitions_per_repeat,summary.repeats, ...
                summary.total_acquisitions);
        end

        function progress=runProgress(controller)
            %RUNPROGRESS How far one press of Run has got.
            %   Counted in ACQUISITIONS across every repeat, because that
            %   is the unit an operator watches. The repeat loop records
            %   which repeat is in flight; the acquisitions completed
            %   within it come from the batch's own checkpoint, which the
            %   runner writes as it goes.
            summary=controller.planSummary();
            progress=struct("schema_version","1.0.0","running",false, ...
                "stop_requested",controller.StopRequested, ...
                "repeat_index",0, ...
                "repeat_count",summary.repeats, ...
                "acquisitions_per_repeat",summary.acquisitions_per_repeat, ...
                "completed_acquisitions",0, ...
                "total_acquisitions",summary.total_acquisitions);
            if isempty(controller.RunProgress), return; end
            progress.running=controller.LifecycleState=="RUNNING";
            progress.repeat_index=double(controller.RunProgress.repeat_index);
            progress.repeat_count=double(controller.RunProgress.repeat_count);
            progress.acquisitions_per_repeat= ...
                double(controller.RunProgress.acquisitions_per_repeat);
            progress.total_acquisitions= ...
                progress.acquisitions_per_repeat*progress.repeat_count;
            completedBefore=(progress.repeat_index-1)* ...
                progress.acquisitions_per_repeat;
            trials=controller.currentBatchTrials();
            inBatch=0;
            if ~isempty(trials) && height(trials)>0
                inBatch=sum(ismember(string(trials.acquisition_status), ...
                    ["completed","analyzed"]));
            end
            progress.completed_acquisitions=min( ...
                max(completedBefore,0)+inBatch,progress.total_acquisitions);
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
            % The same experiment definition, so the same inputs: a fresh
            % batch of an unchanged plan is still a plan that matches what
            % the operator configured, and Run must stay available.
            if isfield(sourcePlan,"execution_inputs")
                plan.execution_inputs=sourcePlan.execution_inputs;
            end
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
            % A resumed run is the active plan by the operator's choice,
            % the same claim the cleared EditableStateChanged flag has
            % always made. Adopting the current inputs makes it READY
            % rather than permanently out of date; any edit after this
            % stales it like any other plan.
            plan.execution_inputs=controller.executionInputs();
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
            % Cleared rather than left behind: whatever installed this
            % reference sets it afterwards, and a stale provenance would
            % have the chooser mark the wrong entry as the loaded one.
            controller.ReferenceSourceKind="";
            controller.ReferenceSourcePath="";
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

        function [folder,stem]=fovBundleIdentity(controller)
            %FOVBUNDLEIDENTITY Where a saved FOV goes, and what it is called.
            %   Both are derived from the CAMERA SNAPSHOT this FOV descends
            %   from, not from whatever file was last loaded. A FOV saved
            %   from snap_FOV001 is therefore snap_FOV002 and not
            %   snap_FOV001_FOV001: reference.source_snapshot survives a
            %   save/load round trip, so the whole chain of bundles stays
            %   named for, and grouped with, the one snapshot they all view.
            if isempty(controller.ReferenceImage)
                error("adaptive_optopatch:NothingToSave", ...
                    "Load a reference FOV before saving one.");
            end
            snapshotPath=info_string(controller.ReferenceInfo,"snapshot_path");
            folder=""; stem="";
            if strlength(snapshotPath)>0
                [folder,stem]=fileparts(snapshotPath);
                folder=string(folder); stem=string(stem);
            end
            if strlength(stem)==0
                % A reference installed directly rather than read from a
                % file - the FOV still has an identity, and it is the one
                % every artifact built from it already uses.
                stem=info_string(controller.ReferenceInfo,"snapshot_name");
            end
            if strlength(folder)==0
                roots=controller.snapshotSearchRoots();
                roots=roots(strlength(roots)>0);
                if ~isempty(roots), folder=roots(1); end
            end
        end

        function roots=snapshotSearchRoots(controller)
            %SNAPSHOTSEARCHROOTS Folders snapshotChoices() reads, in order.
            roots=controller.SnapshotRoot;
            if strlength(roots)==0
                roots=adaptive_optopatch.luminos_snapshot_root( ...
                    controller.LuminosApp);
            end
            currentPath=info_string(controller.ReferenceInfo,"snapshot_path");
            if strlength(currentPath)>0
                roots(end+1,1)=string(fileparts(currentPath));
            end
        end

        function roots=protocolSearchRoots(controller)
            %PROTOCOLSEARCHROOTS Folders protocolChoices() reads, in order.
            roots=controller.ProtocolRoot;
            if strlength(roots)==0
                roots=adaptive_optopatch.default_protocol_root();
            end
            if strlength(controller.ProtocolPath)>0
                roots(end+1,1)=string(fileparts(controller.ProtocolPath));
            end
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
                "repeat_batch_count",parameters.repeat_batch_count, ...
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
            % Read from the PREPARED plan, not from the editable field.
            % Both hold the same number inside one prepare-then-run cycle -
            % changing the field stales the plan, so it cannot be run until
            % it is prepared again - and taking it from the plan is what
            % makes the summary's repeat count and the progress total
            % describe the thing that is actually executing.
            batchCount=prepared_repeat_count(controller.ActiveRunPlan, ...
                controller.PlanParameters.repeat_batch_count);
            perRepeat=height(controller.ActiveRunPlan.manifest.trials);
            controller.enterRunningState();
            cleanup=onCleanup(@()controller.finishRunning()); %#ok<NASGU>
            for batch=1:batchCount
                controller.RunProgress=struct("repeat_index",batch, ...
                    "repeat_count",batchCount, ...
                    "acquisitions_per_repeat",perRepeat);
                controller.setStatus(sprintf("Running repeat %d of %d", ...
                    batch,batchCount));
                run=controller.executePlan(0,"ManageRunState",false);
                if controller.StopRequested || ~batch_is_complete(run.trials)
                    return
                end
                controller.setStatus(sprintf("Completed repeat %d of %d", ...
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
            % source_kind and source_path report WHICH entry of the unified
            % chooser is loaded and which kind it was, so a view can say
            % whether the cells on screen were restored from a saved FOV or
            % drawn on a fresh snapshot in this session.
            geometry=controller.FovGeometry;
            summary=struct("loaded",~isempty(controller.ReferenceImage), ...
                "fov_id","","rig_name","","camera_name","","camera_bin",NaN, ...
                "snapshot_path","","snapshot_directory","", ...
                "source_kind",controller.ReferenceSourceKind, ...
                "source_path",controller.ReferenceSourcePath, ...
                "image_size",geometry.image_size, ...
                "roi_origin_xy",[NaN NaN], ...
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
            % Where this frame sits on the sensor. Reported so a view can say
            % WHICH crop is loaded; it is not a transform anything applies -
            % canonical vertices are intrinsic to this image and stay that way.
            if isfield(info,"metadata") && ...
                    isfield(info.metadata,"voltage_camera") && ...
                    isfield(info.metadata.voltage_camera,"ROI")
                roi=double(info.metadata.voltage_camera.ROI);
                if numel(roi)>=3, summary.roi_origin_xy=[roi(1) roi(3)]; end
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

function advisories=accounting_advisories(reports)
%ACCOUNTING_ADVISORIES Unaccounted terminals, once, across every trial.
%   Under report-only these do not block, but they must not disappear
%   either: the point of this rollout is to find out what is really on the
%   VU's outputs, and the operator is who reads it.
advisories=strings(0,1);
for k=1:numel(reports)
    advisories=[advisories;reports{k}.warnings(:)]; %#ok<AGROW>
end
advisories=unique(advisories,"stable");
end

function value=prepared_repeat_count(plan,fallback)
%PREPARED_REPEAT_COUNT How many repeats one press of Run performs.
%   Taken from the plan that will execute, so the number an operator is
%   shown and the number the loop runs are the same number. A plan from
%   before repeats were archived, or one reconstructed by resume, falls back
%   to the editable value.
value=double(fallback);
if isempty(plan) || ~isfield(plan,"session") || ...
        ~isfield(plan.session,"run_controls")
    return
end
controls=plan.session.run_controls;
if isfield(controls,"repeat_batch_count") && ...
        isfinite(double(controls.repeat_batch_count))
    value=double(controls.repeat_batch_count);
end
end

function identifier=plan_refusal_identifier(status)
%PLAN_REFUSAL_IDENTIFIER Which refusal a non-ready plan is.
%   Distinct identifiers so the endpoint can classify them as lifecycle
%   refusals rather than as faults, and so a caller can tell "there is
%   nothing to run" from "what there is is out of date".
switch status
    case "running", identifier="adaptive_optopatch:AcquisitionActive";
    case "not_ready", identifier="adaptive_optopatch:PlanNotReady";
    otherwise, identifier="adaptive_optopatch:PlanUpdateRequired";
end
end

function message=plan_status_message(status,report)
%PLAN_STATUS_MESSAGE What to tell the operator about the plan, in their words.
%   No internal vocabulary: no freeze, no batch, no lifecycle. The stale
%   groups are named because "something changed" is not actionable and
%   "the somata changed" is.
switch status
    case "not_ready"
        message="Not ready. "+strjoin(report.blocking_issues," ");
    case "running"
        message="Running.";
    case "ready"
        message="Ready to run.";
    otherwise
        if ~report.prepared
            message="Press Update plan to prepare this experiment."; return
        end
        message="The plan is out of date ("+ ...
            strjoin(stale_input_labels(report.stale_inputs),", ")+ ...
            "). Press Update plan.";
end
end

function labels=stale_input_labels(names)
%STALE_INPUT_LABELS Group names as an experimenter would say them.
known=struct( ...
    "reference","the reference FOV", ...
    "somata","soma geometry", ...
    "cell_decisions","cell Record/Stim/Blue V", ...
    "protocol","the pulse protocol", ...
    "spatial","spatial settings", ...
    "run_controls","run settings");
labels=strings(0,1);
for name=reshape(string(names),1,[])
    if isfield(known,char(name))
        labels(end+1,1)=string(known.(char(name))); %#ok<AGROW>
    else
        labels(end+1,1)=name; %#ok<AGROW>
    end
end
if isempty(labels), labels="the experiment"; end
end

function set_scanner_warning(controller,value)
%SET_SCANNER_WARNING Put back the warning a read-only preview refreshed.
%   buildSpatialArtifacts re-reads the live scanner calibration and records
%   what it found. That is the right thing during planning and the wrong
%   thing during a preview: the preview reports the warning in its own
%   payload, and the state poll must not change because somebody looked.
controller.ScannerWarning=value;
end

% -----------------------------------------------------------------------
% Spatial preview
% -----------------------------------------------------------------------

function outline=mask_outline(mask,cellId,parameterName,parameterValue)
%MASK_OUTLINE One canonical mask, as the boundaries the GUI plots.
%   bwboundaries of exactly the mask build_target_preview produced, in
%   [row column] which is [y x] in snapshot-intrinsic pixels - the same
%   conversion the MATLAB axes do when they plot p(:,2) against p(:,1).
%   Several rings are possible for one mask and all are returned; nothing
%   here closes, simplifies or smooths them.
boundaries=bwboundaries(logical(mask));
rings=cell(numel(boundaries),1);
for k=1:numel(boundaries)
    ring=boundaries{k};
    rings{k}=[ring(:,2) ring(:,1)];
end
outline=empty_outline();
outline.cell_id=string(cellId);
outline.rings=rings;
outline.pixel_count=sum(logical(mask),"all");
outline.(parameterName)=double(parameterValue);
end

function outline=empty_outline()
% rings is assigned rather than passed to struct(): a cell value there is
% read as one struct element per cell entry, and {} would produce an empty
% struct array instead of a struct with an empty cell in it.
outline=struct("cell_id","","pixel_count",0, ...
    "adjustment_pixels",NaN,"expansion_pixels",NaN);
outline.rings={};
end

function outlines=empty_outline_array()
outlines=repmat(empty_outline(),0,1);
end

function geometry=spiral_geometry(entry)
%SPIRAL_GEOMETRY One target's 2P scan geometry, as points to draw.
%   The circle bounding the spiral, the spiral path itself, and the
%   automatic off-cell parking point with the dark transition to it - the
%   three things the MATLAB preview draws. The path comes from
%   generate_spiral_preview, which is Luminos's Fermat spiral; it is not
%   recomputed anywhere else.
geometry=empty_spiral();
geometry.cell_id=string(entry.cell_id);
geometry.center_xy=double(entry.center_xy);
geometry.radius_pixels=double(entry.radius_pixels);
geometry.density_points_per_volt=double(entry.density_points_per_volt);
geometry.parking_xy=double(entry.parking_xy);
geometry.pulse_duration_ms=double(entry.pulse_duration_ms);
geometry.cycle_metrics=entry.cycle_metrics;
if all(isfinite(geometry.center_xy)) && isfinite(geometry.radius_pixels) && ...
        geometry.radius_pixels>0 && isfinite(geometry.density_points_per_volt) && ...
        geometry.density_points_per_volt>0
    % Capped well below the function's own default: this is a path drawn
    % in a browser, and a spiral that would need fifty thousand points to
    % render is one nobody can see the turns of anyway.
    geometry.path_xy=adaptive_optopatch.generate_spiral_preview( ...
        geometry.center_xy,geometry.radius_pixels, ...
        geometry.density_points_per_volt,"MaximumDisplayPoints",2000);
end
end

function geometry=empty_spiral()
geometry=struct("cell_id","","center_xy",[NaN NaN],"radius_pixels",NaN, ...
    "density_points_per_volt",NaN,"parking_xy",[NaN NaN], ...
    "pulse_duration_ms",NaN,"path_xy",zeros(0,2), ...
    "cycle_metrics",struct("calibrated",false));
end

function geometries=empty_spiral_array()
geometries=repmat(empty_spiral(),0,1);
end

% -----------------------------------------------------------------------
% Waveform preview
% -----------------------------------------------------------------------

function channel=make_channel(name,units,values,kind)
channel=struct("name",string(name),"units",string(units), ...
    "kind",string(kind),"values",reshape(double(values),1,[]));
end

function channels=empty_channel_array()
channels=repmat(make_channel("","",[],"analog"),0,1);
end

function event=empty_waveform_event()
event=struct("cell_id","","onset_s",NaN,"offset_s",NaN, ...
    "command_voltage_v",NaN,"is_null",false);
end

function events=empty_waveform_event_array()
events=repmat(empty_waveform_event(),0,1);
end

function summary=empty_target_summary()
summary=struct("cell_id","","event_count",0);
end

function summaries=empty_target_summary_array()
summaries=repmat(empty_target_summary(),0,1);
end

function preview=fill_2p_waveform_preview(preview,waveforms,maximumPoints)
%FILL_2P_WAVEFORM_PREVIEW Galvo and Pockels commands, decimated for a view.
%   Uniform decimation, exactly as the MATLAB preview axes do it: these are
%   dense sample vectors at the scanner rate and a plot cannot show them
%   all. The step is reported so a view can say what it is drawing.
rate=double(waveforms.sample_rate_hz);
n=numel(waveforms.x_v);
step=max(1,ceil(n/maximumPoints));
index=1:step:n;
preview.sample_rate_hz=rate;
preview.duration_s=double(waveforms.actual_acquisition_duration_s);
preview.decimation_step=step;
preview.time_s=(index-1)/rate;
preview.window_s=[0 preview.duration_s];
preview.channels=[ ...
    make_channel("Galvo X","V",waveforms.x_v(index),"analog")
    make_channel("Galvo Y","V",waveforms.y_v(index),"analog")
    make_channel("Pockels","V",waveforms.pockels_v(index),"analog")];
% The illuminated windows, from the same per-pulse record the waveform was
% built from, so an event boundary lands exactly where the command changes.
for k=1:numel(waveforms.per_pulse)
    pulse=waveforms.per_pulse(k);
    event=empty_waveform_event();
    event.onset_s=double(pulse.on_sample)/rate;
    event.offset_s=double(pulse.off_sample)/rate;
    preview.events(end+1,1)=event;
end
end

function preview=fill_1p_waveform_preview(preview,plan,maximumPoints)
%FILL_1P_WAVEFORM_PREVIEW The mod488 step trace and the events behind it.
%   The first resolved acquisition of the frozen-shape plan, flattened by
%   flatten_pulse_schedule - which is where a resolved event's concrete
%   command voltage comes from - and rendered as the same rising/falling
%   edge trace the MATLAB preview plots.
resolved=plan.manifest.trials.pulse_schedule{1};
preview.acquisition_id=string(resolved.acquisition_id);
preview.duration_s=double(resolved.acquisition_duration_s);
pulses=adaptive_optopatch.flatten_pulse_schedule(resolved);

% Four edge samples per pulse. A long round robin would ask a browser to
% draw more than it usefully can, so the trace is cut at a whole pulse and
% the window it covers is reported rather than the pulses being thinned,
% which would show a schedule that was never scheduled.
maximumPulses=max(1,floor(maximumPoints/4));
if height(pulses)>maximumPulses
    pulses=pulses(1:maximumPulses,:);
    preview.truncated=true;
end
preview.window_s=[0 max(double(pulses.offset_s(end)),0)];
if ~preview.truncated, preview.window_s=[0 preview.duration_s]; end

onset=double(pulses.onset_s); offset=double(pulses.offset_s);
command=double(pulses.modulator_voltage);
zero=zeros(height(pulses),1);
preview.time_s=reshape([onset onset offset offset]',1,[]);
preview.channels=make_channel("mod488","V", ...
    reshape([zero command command zero]',1,[]),"analog");
preview.sample_rate_hz=NaN;

isNull=logical(pulses.is_null);
cellIds=string(pulses.target_cell_id);
for k=1:height(pulses)
    event=empty_waveform_event();
    event.cell_id=cellIds(k);
    event.onset_s=onset(k);
    event.offset_s=offset(k);
    event.command_voltage_v=command(k);
    event.is_null=isNull(k);
    preview.events(end+1,1)=event;
end
for id=reshape(unique(cellIds(~isNull),"stable"),1,[])
    summary=empty_target_summary();
    summary.cell_id=id;
    summary.event_count=sum(cellIds==id & ~isNull);
    preview.targets(end+1,1)=summary;
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

function tf=known_and_present(choices,choiceId)
%KNOWN_AND_PRESENT Whether a cached choice still names a file on disk.
index=find([choices.choice_id]==choiceId,1);
tf=~isempty(index) && isfile(choices(index).path);
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
% How many repeats one press of Run performs. Archived with the plan so the
% summary and the progress count describe the plan rather than whatever the
% editable field says now; a bundle written before this carried it reports
% one repeat, which is what running it once has always meant.
controls.repeat_batch_count=1;
if isfield(saved,"repeat_batch_count")
    controls.repeat_batch_count=double(saved.repeat_batch_count);
end
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
