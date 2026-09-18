function response=apply_controller_action(controller,action,payload,expectedRevision)
%APPLY_CONTROLLER_ACTION Run one named Adaptive Optopatch action from a frontend.
%   This is the whole write surface a non-MATLAB frontend has. It exists so
%   that "which operations may a browser invoke" is a list somebody wrote
%   down, in this repository, next to the controller whose vocabulary it is
%   - rather than a generic bridge that would let a request name any method
%   on a live experiment controller.
%
%   EVERY action is dispatched through the explicit switch below. There is
%   deliberately no controller.(action)(...) anywhere in this file: an
%   action that is not listed is refused, and adding one is an edit here and
%   a test beside it.
%
%   The contract, in both directions:
%
%     request   action              (1,1) string, from the list below
%               payload             struct of that action's arguments
%               expected_revision   the controller revision the caller saw
%
%     response  ok                  logical
%               status              applied | stale_revision | not_legal |
%                                   validation_error | unknown_action |
%                                   invalid_request | failed
%               message             what to tell the operator, "" when ok
%               identifier          the MATLAB error identifier, "" when ok
%               expected_revision   echoed back
%               revision            the revision AFTER the call
%               state               controller.getState() AFTER the call
%
%   `state` is returned on success AND on every rejection, because the thing
%   a frontend must do after either is the same: replace what it is showing
%   with what the controller actually holds. A rejected action leaves that
%   state untouched, so the caller ends up agreeing with the backend either
%   way, without waiting for the next poll to repair it.
%
%   STALE REQUESTS. A mutation carries the revision its caller was looking
%   at. If the controller has moved on - the MATLAB planning GUI edited the
%   same session, or another browser did - the action is refused with
%   status stale_revision and NOTHING is mutated. This is not conflict
%   resolution; it is the guarantee that an action means what the operator
%   saw when they asked for it.
%
%   stop_after_current is the one exemption, and deliberately: a run bumps
%   the revision continuously as it reports progress, so requiring a fresh
%   revision would make stopping fail exactly when it is wanted. It is also
%   the only action that is legal while an acquisition is running.
arguments
    controller (1,1) adaptive_optopatch.AdaptiveOptopatchController
    action (1,1) string
    payload = struct()
    expectedRevision = []
end

payload=normalize_payload(payload);

if ~is_known_action(action)
    response=reject(controller,action,"unknown_action", ...
        "Adaptive Optopatch does not offer an action called '"+action+"'.", ...
        expectedRevision);
    return
end

if action=="stop_after_current"
    % Asked of the controller rather than worked out here, so there is one
    % answer to "may this be stopped now" and this file is not a second
    % copy of it. No revision check: see the note above.
    if ~controller.legalActions().stop_after_current
        response=reject(controller,action,"not_legal", ...
            "No acquisition is running, or a stop has already been " + ...
            "requested.",expectedRevision);
        return
    end
else
    % Every other action is refused while an acquisition holds the session.
    % The controller enforces this for its own mutators (assertNotRunning);
    % runNext and runAll have no such guard of their own, because the
    % MATLAB GUI disables its buttons instead - and a second frontend
    % cannot be relied on to have done the same.
    if controller.LifecycleState=="RUNNING"
        response=reject(controller,action,"not_legal", ...
            "An acquisition is active. Only stop_after_current is " + ...
            "available until it finishes.",expectedRevision);
        return
    end

    [valid,revisionMessage]=check_revision(controller,expectedRevision);
    if ~valid
        response=reject(controller,action,"stale_revision", ...
            revisionMessage,expectedRevision);
        return
    end
end

try
    run_action(controller,action,payload);
catch exception
    response=reject(controller,action,classify(exception), ...
        string(exception.message),expectedRevision, ...
        string(exception.identifier));
    if response.status=="failed"
        % Not an Adaptive Optopatch refusal: something unexpected went wrong
        % inside the operation. Reported to the console as well as to the
        % caller, because a browser message is not a place to read a stack.
        warning("adaptive_optopatch:ActionFailed", ...
            "Adaptive Optopatch action '%s' failed:\n%s", ...
            action,getReport(exception));
    end
    return
end

response=envelope(controller,action,true,"applied","","",expectedRevision);
end

% -----------------------------------------------------------------------
% The allowlist
% -----------------------------------------------------------------------

function names=action_names()
%ACTION_NAMES Every action a frontend may invoke, and nothing else.
%   Present now, and why - these three were absent while the reason for
%   their absence held, and the reason has since been removed:
%
%     load_reference_choice
%         the chooser that snapshotChoices() and protocolChoices() were the
%         model for now exists for saved FOVs too. referenceChoices() lists
%         camera snapshots and saved Adaptive Optopatch FOVs together, each
%         typed and each with a choice_id, and this takes that id and
%         nothing else. There is still no way to send a path.
%
%     save_fov
%         takes no path at all. WHERE a FOV is written, and what it is
%         called, is the session's decision - beside the snapshot it was
%         drawn on, at the next unused number - exactly as freeze_run's
%         output root is. A browser asks for a save; it does not name a file.
%
%     apply_plan_draft
%         THE COMMIT BOUNDARY, and the reason the React tab can let an
%         experimenter pick targets without a round trip per checkbox. The
%         browser holds uncommitted edits; this is how they become
%         committed state and a prepared plan, in ONE action, under ONE
%         revision check, with the commit rolled back if the compile or the
%         audit refuses it.
%
%         It replaced a sequence - a set_plan_parameter per value, then a
%         batch of cell decisions, then update_plan - which left a window
%         where the third parameter could be refused after the first two
%         had been kept and before any plan existed. The controller would
%         then hold a configuration the experimenter never asked for.
%
%         It can express nothing the individual actions cannot. What it
%         adds is that the whole draft arrives or none of it does.
%
%     set_cell_blue_voltage
%         the per-cell 488 nm CALIBRATION, which the MATLAB cell table has
%         always been able to edit through the same controller method. It
%         is stored provenance, not a command source: resolve_protocol owns
%         command-voltage precedence and a stored calibration is the tier it
%         reaches only when the event, the acquisition and the protocol have
%         none. Editing it here cannot override a protocol that names a
%         voltage, and cannot reach a 2P Pockels command at all.
%
%   Deliberately absent, and why - the run lifecycle:
%
%     freeze_run / start_new_run / return_to_editing / start_new_batch
%         internal machinery for preparing, discarding and re-issuing an
%         execution plan. An experimenter does not freeze anything; they
%         update a plan and run it. update_plan IS freeze_run, gated and
%         named for what it does, and re-issuing a completed plan happens
%         inside run rather than as a separate press. The methods remain
%         on the controller and the MATLAB planning window still offers
%         them; no endpoint reaches them.
%
%     run_next / run_all
%         run_next executes ONE acquisition, which is a debugging
%         primitive rather than an experiment, and both of them freeze a
%         plan implicitly when none exists - which is exactly the hole
%         this pass closes. `run` executes the whole prepared plan and is
%         refused unless a prepared plan matches the current inputs. An
%         operator who wants one cell deselects Stim on the others and
%         updates the plan, so what will run is visible before it runs.
%
%   Deliberately still absent, and why:
%
%     resume_run
%         takes a run folder chosen by the operator. A browser cannot
%         present that chooser, and there is no MATLAB-owned listing of
%         resumable runs yet.
%
%     set_cell_calibration
%         writes a calibration SNAPSHOT - the pulse duration and OBIS power
%         a value was measured at - and belongs with the Blue-ramp review
%         that measures them, not with a typed-in number.
%
%     clear_somata
%         one click that discards every soma in the FOV. It stays where it
%         needs a second look before it happens.
%
%     send_orange_recording_mask
%         drives a DMD. Hardware output is not something a state-editing
%         surface should carry.
names=[ ...
    "load_reference_choice"
    "load_snapshot_choice"
    "save_fov"
    "set_cell_eligibility"
    "set_cell_blue_voltage"
    "add_soma"
    "update_soma"
    "delete_soma"
    "load_protocol_choice"
    "set_plan_parameter"
    "apply_plan_draft"
    "update_plan"
    "run"
    "stop_after_current"];
end

function tf=is_known_action(action)
tf=any(action_names()==action);
end

function run_action(controller,action,payload)
%RUN_ACTION Map one allowlisted name to one controller operation.
%   One deliberate line per action. Nothing here decides anything about the
%   experiment: validation, identity, eligibility, QC, legality and
%   execution all remain the controller's.
switch action
    case "load_reference_choice"
        % One id, out of a listing MATLAB produced, naming either a camera
        % snapshot or a saved Adaptive Optopatch FOV. Which of the two it
        % is, and therefore whether this starts a fresh FOV or restores
        % saved cells and decisions, is decided inside
        % loadReferenceChoice against that listing - not here, and never
        % by the caller.
        controller.loadReferenceChoice(required_text(payload,"choice_id"));

    case "save_fov"
        % No path, and no number. The bundle goes beside the snapshot this
        % FOV was drawn on, at the next unused number, and never replaces
        % one that is already there.
        controller.saveNextFov();

    case "set_cell_blue_voltage"
        % The stored per-cell 488 nm calibration, through the same
        % controller method the MATLAB cell table edits it with. The
        % controller validates the value; the resolver still owns what a
        % run actually commands.
        controller.setCellBlueVoltage(required_text(payload,"cell_id"), ...
            required_field(payload,"voltage_v"));

    case "load_snapshot_choice"
        % The browser sends a choice_id from a listing MATLAB produced, and
        % nothing else. Resolving it to a file, and reading the camera
        % identity, crop origin, binning and DMD transforms out of that file,
        % both happen inside the controller's own loadSnapshot.
        controller.loadSnapshotChoice(required_text(payload,"choice_id"));

    case "set_cell_eligibility"
        controller.setCellEligibility(required_text(payload,"cell_id"), ...
            "RecordingEnabled",optional_flag(payload,"recording_enabled"), ...
            "StimulationEnabled",optional_flag(payload,"stimulation_enabled"));


    case "add_soma"
        controller.addSomaPolygon(required_vertices(payload));

    case "update_soma"
        controller.updateSomaPolygon(required_text(payload,"cell_id"), ...
            required_vertices(payload));

    case "delete_soma"
        controller.deleteCell(required_text(payload,"cell_id"));

    case "load_protocol_choice"
        controller.loadProtocolChoice(required_text(payload,"choice_id"));

    case "set_plan_parameter"
        controller.setPlanParameter(required_text(payload,"name"), ...
            required_field(payload,"value"));

    case "apply_plan_draft"
        % One logical commit: the draft's cell decisions and plan
        % parameters, then compile, then audit. The controller owns
        % atomicity; this only reshapes the request into the struct it
        % takes. The revision the draft was built on has already been
        % checked above, by the same rule every other mutation uses.
        controller.applyPlanDraft(required_plan_draft(payload));

    case "update_plan"
        % Validate, resolve, preflight and archive an immutable execution
        % plan for the current experiment. No output root from the caller:
        % where a plan is written is the session's decision (RunRoot, or
        % the snapshot's own folder), not a browser's. Refused by the
        % controller when the experiment is not describable yet.
        controller.updatePlan();

    case "run"
        % Execute the whole prepared plan, repeated as many times as it
        % was prepared for. The controller refuses a plan that is absent,
        % out of date or already running, so this endpoint cannot do what
        % a greyed-out button will not - which is the point of gating it
        % there rather than in a frontend.
        controller.runPreparedPlan();

    case "stop_after_current"
        controller.stopAfterCurrent();

    otherwise
        % Unreachable: is_known_action has already refused anything absent
        % from action_names. Kept so that adding a name to that list and
        % forgetting to wire it here fails loudly instead of silently
        % reporting success.
        error("adaptive_optopatch:UnhandledAction", ...
            "Action '%s' is allowlisted but not implemented.",action);
end
end

% -----------------------------------------------------------------------
% Revision, payloads, and classification
% -----------------------------------------------------------------------

function [valid,message]=check_revision(controller,expectedRevision)
message="";
if ~isnumeric(expectedRevision) || ~isscalar(expectedRevision) || ...
        ~isfinite(expectedRevision)
    valid=false;
    message="This request carried no controller revision, so it could " + ...
        "not be checked against the current session state.";
    return
end
valid=double(expectedRevision)==controller.Revision;
if ~valid
    message=sprintf(['The session has changed since this was requested ' ...
        '(revision %g, now %g). Nothing was changed; the current state ' ...
        'is shown instead.'],double(expectedRevision),controller.Revision);
end
end

function status=classify(exception)
%CLASSIFY What kind of refusal this exception is, for the frontend.
identifier=string(exception.identifier);
if ~startsWith(identifier,"adaptive_optopatch:")
    status="failed"; return
end
lifecycle=["adaptive_optopatch:AcquisitionActive"
    "adaptive_optopatch:FrozenRunRequired"
    "adaptive_optopatch:CompletedBatchRequired"
    "adaptive_optopatch:PulseProtocolRequired"
    "adaptive_optopatch:PlanNotReady"
    "adaptive_optopatch:PlanUpdateRequired"];
if any(lifecycle==identifier)
    status="not_legal"; return
end
status="validation_error";
end

function payload=normalize_payload(payload)
%NORMALIZE_PAYLOAD Accept what jsondecode makes of a JSON object.
%   An absent or empty payload is a struct with no fields, which is exactly
%   what jsondecode produces from {} and is what the no-argument actions
%   want. Anything else is a malformed request.
if isempty(payload)
    payload=struct(); return
end
if ~isstruct(payload) || ~isscalar(payload)
    error("adaptive_optopatch:InvalidActionPayload", ...
        "An action payload must be a single object.");
end
end

function value=required_field(payload,name)
if ~isfield(payload,name)
    error("adaptive_optopatch:MissingActionArgument", ...
        "This action requires '%s'.",name);
end
value=payload.(name);
end

function value=required_text(payload,name)
value=required_field(payload,name);
if ~(ischar(value) || isstring(value)) || ~isscalar(string(value)) || ...
        strlength(string(value))==0
    error("adaptive_optopatch:InvalidActionArgument", ...
        "'%s' must be a nonempty name.",name);
end
value=string(value);
end

function value=optional_flag(payload,name)
%OPTIONAL_FLAG An omitted eligibility flag means "leave this one alone".
%   setCellEligibility reads empty as "not specified", which is how the
%   MATLAB table edits one checkbox without touching the other.
value=[];
if ~isfield(payload,name) || isempty(payload.(name)), return; end
value=logical(payload.(name));
end

function draft=required_plan_draft(payload)
%REQUIRED_PLAN_DRAFT The uncommitted edits a frontend is asking to commit.
%   A draft is SPARSE: it carries only what differs from the committed
%   state the frontend was looking at, so both fields are optional and a
%   draft with neither is simply "prepare a plan from what is already
%   committed".
%
%     cells            a list of per-cell decisions, each with a cell_id
%                      and whichever of recording_enabled and
%                      stimulation_enabled it means to change
%     plan_parameters  an object of canonical plan parameter values
%
%   Nothing here decides what a value means or whether it is allowed. The
%   controller validates the whole delta before it applies any of it.
draft=struct();
if isfield(payload,"cells") && ~isempty(payload.cells)
    draft.cells=cell_eligibility_edits(payload.cells);
end
if isfield(payload,"plan_parameters") && ~isempty(payload.plan_parameters)
    value=payload.plan_parameters;
    if ~isstruct(value) || ~isscalar(value)
        error("adaptive_optopatch:InvalidActionArgument", ...
            "'plan_parameters' must be a single object of parameter values.");
    end
    draft.plan_parameters=value;
end
end

function edits=cell_eligibility_edits(value)
%CELL_ELIGIBILITY_EDITS Per-cell decisions, as the controller wants them.
%   jsondecode turns a list of objects with identical fields into a struct
%   array and a list of one into a scalar struct; a list whose objects have
%   DIFFERENT fields - the normal case here, because an omitted flag means
%   "leave that decision alone" - arrives as a cell array of structs
%   instead. All three are normalised to the struct array the controller
%   takes, with the field names it uses.
if iscell(value)
    entries=value;
elseif isstruct(value)
    entries=num2cell(reshape(value,1,[]));
else
    error("adaptive_optopatch:InvalidActionArgument", ...
        "'cells' must be a list of per-cell eligibility edits.");
end
if isempty(entries)
    error("adaptive_optopatch:InvalidActionArgument", ...
        "'cells' must name at least one cell when it is sent at all.");
end

edits=repmat(struct("cell_id","","RecordingEnabled",[], ...
    "StimulationEnabled",[]),1,numel(entries));
for k=1:numel(entries)
    entry=entries{k};
    if ~isstruct(entry) || ~isscalar(entry)
        error("adaptive_optopatch:InvalidActionArgument", ...
            "Each entry of 'cells' must be a single object.");
    end
    edits(k).cell_id=required_text(entry,"cell_id");
    edits(k).RecordingEnabled=optional_flag(entry,"recording_enabled");
    edits(k).StimulationEnabled=optional_flag(entry,"stimulation_enabled");
end
end

function vertices=required_vertices(payload)
%REQUIRED_VERTICES The drawn outline, in canonical FOV coordinates.
%   vertices_xy is an N-by-2 list of [x y] in snapshot-intrinsic pixels -
%   1-based, pixel centres at integers - which is the one coordinate system
%   canonical soma geometry is kept in. A frontend converts its own canvas
%   coordinates into this before sending; nothing here rescales, flips, or
%   otherwise reinterprets what arrives.
%
%   jsondecode turns [[x,y],[x,y],...] into an N-by-2 matrix, and a single
%   vertex into a 1-by-2. Validation of the polygon itself belongs to
%   validate_soma_polygon, which the controller calls.
vertices=required_field(payload,"vertices_xy");
if ~isnumeric(vertices) || ~ismatrix(vertices) || size(vertices,2)~=2
    error("adaptive_optopatch:InvalidActionArgument", ...
        "'vertices_xy' must be an N-by-2 list of [x y] vertices in " + ...
        "snapshot-intrinsic pixels.");
end
vertices=double(vertices);
end

% -----------------------------------------------------------------------
% Responses
% -----------------------------------------------------------------------

function response=reject(controller,action,status,message,expectedRevision, ...
        identifier)
arguments
    controller
    action
    status
    message
    expectedRevision
    identifier (1,1) string = ""
end
response=envelope(controller,action,false,status,message,identifier, ...
    expectedRevision);
end

function response=envelope(controller,action,ok,status,message,identifier, ...
        expectedRevision)
%ENVELOPE One reply shape for every outcome.
%   Note the absence of a field called `error`: the browser's MATLAB bridge
%   reads that name as "the call threw", which this never does. A refusal is
%   a result, and carries the state that goes with it.
requested=NaN;
if isnumeric(expectedRevision) && isscalar(expectedRevision)
    requested=double(expectedRevision);
end
response=struct( ...
    "schema_version","1.0.0", ...
    "ok",logical(ok), ...
    "action",string(action), ...
    "status",string(status), ...
    "message",string(message), ...
    "identifier",string(identifier), ...
    "expected_revision",requested, ...
    "revision",controller.Revision, ...
    "state",controller.getState());
end
