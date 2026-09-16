# Engineering notebook

## 2026-09-16 — A snapshot is chosen by its stem, not by its path

Loading the first camera snapshot was the last step of the normal workflow
that still required the MATLAB planning window, and it required it for one
reason: it needed a file chooser. `snapshotChoices()` and
`load_snapshot_choice` remove that, the same way `protocolChoices()` removed
it for pulse protocols — MATLAB lists what it is willing to load, the browser
returns one id, and the file is resolved on this side.

The id is the snapshot's STEM, and that is a reuse rather than an invention.
`Camera_Snap` writes `<stem>.tiff`, `<stem>.mat` and a browser-visible
`<stem>.png` from one stem, and Luminos's own patterning image pickers already
identify a snapshot by exactly that stem — they hand it to `Load_Ref_Im_JS`,
which ignores the extension and resolves the `.mat` beside it. So a snapshot is
called the same thing in the Adaptive Optopatch tab as in the DMD tab, and a
frontend that wants the thumbnail Luminos already serves can find it by name.

What was NOT reused is how the patterning picker gets there. It reads
`datafolder` in the browser, concatenates `/Snaps/<name>`, and sends that
string. That is a path on the wire, and it is the thing this contract exists to
avoid: a browser that can name a path can name any path. Here the browser sends
the id alone and `loadSnapshotChoice` resolves it against a listing this
controller produced. A choice_id that happens to be a full path resolves to
nothing, which is a test.

Its listing source was not reused either, and that was the harder call. The
picker lists the relay's copies of today's snaps under
`User_Interface/relay/imgs` — PNGs, written for the browser to display. That is
the right source for a thumbnail and the wrong one for this: it cannot say
whether the `.mat` Adaptive Optopatch actually reads is present, cannot report
the camera identity, crop origin or binning recorded inside it, and covers one
day's folder rather than the session's Snaps directory. So
`list_snapshot_choices` reads `<datafolder>/Snaps/*.mat` itself and opens each
candidate through `read_reference_snapshot` — the same function `loadSnapshot`
uses — so that `loadable` means "loading this would succeed" rather than "this
file looks plausible". A snap from the wrong camera is listed with that reason
rather than hidden, because an operator who cannot see the snap they just took
has no way to find out why.

Opening every candidate costs an image load each, so the listing is capped at
forty and ordered newest first by file time. That is also the right order:
the snapshot somebody wants is almost always the one they just took.

Loading itself is `loadSnapshot`, unchanged and shared with the MATLAB GUI.
Nothing about a snapshot is interpreted anywhere else: camera identity, crop
origin, binning and the DMD transforms recorded with the snap are read once, in
`read_reference_snapshot`, and the browser is told the results. `fov` gained
`roi_origin_xy` so a view can say WHICH crop is loaded; it is reported, not
applied — canonical vertices stay intrinsic to the reference image, and the
half-pixel canvas conversion is still the only transform a frontend performs.

One error-contract fix fell out of it. `read_reference_snapshot` called
`whos('-file', ...)` unguarded, so a truncated or foreign MAT file threw
MATLAB's raw file error rather than an `adaptive_optopatch:` one — which the
action dispatcher then classified as an internal failure and reported with a
console warning, when it is an unusable input and nothing more. It now raises
`InvalidSnapshot` like every other malformed snapshot.

## 2026-09-16 — The write surface is a list somebody wrote down

React can now change an Adaptive Optopatch session, and the whole of what it
can change is `action_names()` in
`+adaptive_optopatch/apply_controller_action.m`: thirteen names, each mapped by
an explicit `switch` to exactly one controller call. There is no
`controller.(action)(...)` anywhere. The alternative — a generic bridge that
resolves a method name off a live experiment controller — would have made
"what can a browser do to a run" unanswerable without reading the whole class,
and would have grown new capabilities every time the controller did.

The list lives HERE rather than in Luminos, and Luminos's
`adaptive_optopatch_action_js` is three lines of resolve-and-delegate. Two
reasons. Luminos is shared by the whole lab and which Adaptive Optopatch
operations exist is not its business — the same reason it holds no AO paths.
And `Rig_Control_App` cannot be constructed on Linux, so an allowlist in
Luminos would be the one part of the production write path that could never be
tested here; in this repository it is covered by
`tests/TestAdaptiveOptopatchActions.m` against the real controller. It is not a
weaker boundary either way: JS_Server already lets a browser call any app
method, so the trust edge is "anything in Luminos" with or without this file.

Deliberately absent, and why: anything taking a filesystem path chosen by the
operator (`loadSnapshot`, `loadFov`, `saveFov`, `resumeRun`) — a browser cannot
present that chooser and must not be handed a path to send; `setCellBlueVoltage`
and `setCellCalibration` — the per-cell 488 nm value is provenance a frontend
displays, not a command source it edits; `clearSomata` — one click that
discards every soma; `sendOrangeRecordingMask` — hardware output has no place
on a state-editing surface. Protocols were the one path-shaped operation worth
solving, and `list_protocol_choices` solves it by inverting the direction:
MATLAB lists what it is willing to load, React returns one `choice_id`, and no
request can name a file the listing did not offer.

Every action carries the revision its caller was looking at, and is refused
without mutating anything if the controller has moved on. That is not conflict
resolution — the MATLAB GUI and the tab are still two views of one session and
last writer wins — it is the guarantee that an action means what the operator
saw. `stop_after_current` is exempt, because a run bumps the revision
continuously as it reports progress and requiring a fresh one would make
stopping fail exactly when it is wanted; it is also the only action legal while
an acquisition is active, which `apply_controller_action` enforces for
`runNext` and `runAll` because the controller does not (the MATLAB GUI disables
its buttons instead, and a second frontend cannot be relied on to have done the
same).

A refusal is a RESULT, not an exception. It comes back with `ok:false`, a
`status` naming which kind it was, and `controller.getState()` afterwards — so
a rejected request leaves the browser agreeing with the backend immediately
rather than waiting for a poll to repair it. The envelope deliberately has no
field called `error`: the browser's MATLAB bridge reads that name as "the call
threw", discards the result and raises a snackbar, which is the wrong treatment
for an answer.

## 2026-09-16 — The reference image is its own endpoint, and half a pixel is the whole transform

`get_adaptive_optopatch_reference_image_js` is separate from the state poll
because the state poll runs about once a second behind every tab that is
mounted, which is all of them. An image field on `getState()` would be a camera
frame per second forever. The state snapshot instead reports
`fov.image_size` and `fov.reference_revision`, and a view fetches the pixels
only when that revision changes.

It returns a uint8 ROW VECTOR, not a matrix and not a struct. JS_Server can
frame either a JSON value or one binary array, never a struct containing one,
so the dimensions cannot travel with the pixels — and a matrix would arrive as
nested rows through the JSON path and flat through the binary path, which is
two shapes for the frontend to handle depending on how big the image happened
to be. A vector is the same flat, column-major list either way. If the
reference changes between the poll that reported its size and the fetch, the
length will not match and the browser discards it; the next poll reports the
new revision and it refetches. That is cheaper and more robust than a lock.

The eight-bit stretch is applied in MATLAB, by `reference_display_image`, using
`reference_contrast_limits` — which `ReferencePreparationApp.applyContrast` now
also calls. One rule, so the planning axes and any other frontend show the same
picture of the same FOV rather than each inventing a mapping. The result is a
display artifact: canonical intensities stay in `controller.ReferenceImage`, and
nothing measures anything from what goes over the wire.

The coordinate contract is the part worth being exact about. Canonical soma
vertices are snapshot-intrinsic pixels — MATLAB's own indexing, one-based, pixel
centres at integers, what `create_fov_geometry` states and `poly2mask` assumes.
The browser's SVG viewBox is the same grid measured from the image's top-left
corner and zero-based, so the two differ by exactly half a pixel in each axis
and by nothing else. There is no flip (the planning axes draw with `YDir
reverse`, so row 1 is at the top in both), no transpose, no binning factor, no
crop origin, and no camera transform. Those are real and they are all applied on
this side already: the reference image IS the cropped, binned snapshot, and
full-sensor world limits live in the reference model where the DMD and scanner
calibrations read them. A browser applying any of them a second time would put
every soma in the wrong place. Zoom and pan move the viewBox, so pointer
positions invert through the SVG's own screen transform and the half pixel is
still the only correction.

## 2026-09-16 — What React is allowed to think is editable

The controller holds eighteen plan parameters and they are not all the same kind
of thing. React offers the eleven the MATLAB GUI routes into
`setPlanParameter`, gated by stimulation mode the way
`refreshModeVisibility` gates them, and shows the other seven read-only.

Those seven — screen repeats, pulses per neuron, pulse duration, both dark-gap
bounds, and the pre and post delays — are the ones `AdaptiveOptopatchApp`
already hides, because pulse-protocol scripts own biological timing and write an
explicit onset for every event; `buildPlan` strips them out of the saved session
entirely. Making them typeable in a second frontend would have quietly
reintroduced a GUI tier under the protocol, which is the thing removing the
mod488 field was about. They are shown rather than dropped because an operator
who has used the older GUI will look for them, and "the protocol owns this" is
a more useful answer than their absence.

No control has a default of its own. A frontend default is a second source of
truth for a planning value, and the first time it disagreed the operator would
be running something other than what the panel showed. Every control renders
what MATLAB sent and writes back through the action endpoint; a number box holds
typed text only while it is focused.

## 2026-09-16 — One controller per Luminos session, two frontends over it

Luminos now owns an optional Adaptive Optopatch controller and hands the same
handle to everyone who asks:
`Rig_Control_App.getAdaptiveOptopatchController` builds one lazily the first
time it is called and returns that one thereafter. The read-only endpoint
`get_adaptive_optopatch_state_js` reports `controller.getState()` through it, so
the interface's Adaptive Optopatch tab and the MATLAB planning GUI are two views
of one state rather than two states that happen to look alike. Two controllers
would mean two different answers to "what would be run", which is the one thing
that must never be ambiguous.

The AO side of that is one optional argument. `ReferencePreparationApp` already
accepted `Controller`; `AdaptiveOptopatchApp` did not forward it, so the GUI
operators actually launch always built its own. It now forwards it, and
`launch_adaptive_optopatch_gui` asks the Luminos app it was already given for
the session's controller — duck-typed on `ismethod`, so the simulated backend
and any Luminos predating this simply fall through to building one, and
standalone AO is unchanged. Opening the GUI also no longer assigns `RunRoot`
unless the caller named one; the old unconditional assignment was harmless for a
controller the GUI had just built and wiped the run root off a shared one.

`StateChangedFcn` is a single property, not a listener list, so whoever assigns
last owns it — and the planning GUI assigns it in its constructor. Luminos
therefore installs no callback at all, which is why React polls instead: it
reads `getState()` and compares revisions, so the GUI keeps its callback and
nothing has to arbitrate. This is also why a small event framework was not
worth building; the only client that would use one is the GUI, which already
has it. Two planning GUIs on one controller would still contend, as they always
have.

Luminos discovers Adaptive Optopatch by asking whether
`adaptive_optopatch.AdaptiveOptopatchController` resolves on the MATLAB path —
the `addpath` the VU startup already performs. No path is committed to Luminos,
the check is repeated per call so adding the repository mid-session works, and a
rig without this package gets an empty controller, which the endpoint turns into
the null the tab already renders as "no Adaptive Optopatch controller". A
controller that is present but throws is different and is reported once, loudly,
rather than being folded into "not installed".

On shutdown Luminos releases the reference rather than deleting the controller.
It owns no figure, device, file handle or timer, so dropping the reference is
the whole of its cleanup; deleting it would invalidate the handle a planning GUI
still has open.

Still read-only. There are no write endpoints, no reference image on the wire,
and no ROI editing in the interface — the tab polls state and renders it, and
`legal_actions` is displayed rather than acted on.

## 2026-09-16 — The Luminos React dev harness belongs here, the tab's home is still open

The fake-MATLAB development server, the AO state fixtures, the fixture
generator and their tests now live in `dev/luminos-react/`. They were first
written inside `luminos-private`, which was the wrong repository: Luminos is
shared by the whole lab, and a TCP stub that serves Adaptive Optopatch fixtures
is neither shared nor generic. It costs nothing to keep it here — the stub
speaks the relay's existing wire protocol from the outside, so Luminos needs no
knowledge of it, and moving it required only rebasing the fixture generator on
this repository's root instead of walking up to a sibling checkout.

The harness exists because the frontend cannot be developed against nothing:
without MATLAB answering the relay the interface never receives its tab list and
nothing renders, and the full Luminos Simulator does not run on Linux, where
React, the relay and the AO controller all do. Only the MATLAB endpoint is
faked; the React code, the relay and the protocol are the production ones.

The AO React tab itself is a separate question and is deliberately unresolved.
It currently sits uncommitted in `luminos-private`
(`frontend/src/tabs/AdaptiveOptopatch/`, `matlabComms/adaptiveOptopatchComms.tsx`,
one line in `useTabs.tsx`). An audit of the Luminos tab system found no
extension seam at all: the rig JSON chooses which tabs appear by name, but the
name-to-component map in `useTabs.tsx` is a closed compile-time list, and there
is no registry, dynamic import, lazy boundary, workspace or package export
anywhere in the frontend. The tab also depends on Luminos internals that are not
published — `SectionHeader`, `GrayBox`, `VerticalStack`, `Utils`,
`GlobalAppVariablesContext` and `matlabHelpers` — all reached by relative path.

The recommendation from that audit is to keep the tab's source in
`luminos-private` alongside every other tab, rather than build an extension
mechanism to host one tab from outside. The seam that matters — the one that
keeps AO logic out of JavaScript — is the state contract, not the file location:
React reads `AdaptiveOptopatchController.getState()` and displays it, and every
decision stays in MATLAB. An external-tab mechanism would buy file-location
purity at the cost of a second React build, a published component API that
Luminos does not have today, and a deployment story for VU. This is a
recommendation, not yet a decision.

## 2026-09-03 — Persistent FOV and pulse-resolved EPSP acquisition

The acquisition model now joins two explicit sources of truth: a persistent
FOV containing canonical ROIs/stable cell identities/calibration decisions,
and protocol schema 2 containing one row per physical pulse. Orange recording
illumination and Blue stimulation masks are deterministic derivations of the
canonical ROI. Recording and stimulation eligibility are independent so an
excluded presynaptic candidate remains illuminated and recorded.

Single-cell ramp protocols use explicit physical voltage blocks; the small
ramp-review helper aggregates operator-reviewed spike outcomes without adding
an EPSP detector. Calibrated round-robin protocols copy each eligible cell's
stored voltage into every pulse and resolve all target IDs before freezing.

Continuous 1P targeting uses the existing ALP `Write_Stack('slave')` path and
the Virtual Upright `DMD Trigger` line (`Dev1/port0/line4`). The deterministic
DAQ waveform advances the stack at optical pulse offsets, so the next mask is
present throughout the existing dark interval. The earlier assumption that the
ALP begins by displaying stack entry 1 was removed by the explicit initialization
edge documented below.

## 2026-09-02 — Local Luminos simulation boundary

Adaptive Optopatch now supports local runner development through a deliberately
small, duck-typed Luminos test backend. The simulator implements only the API
surface used by the 1P/2P resolvers and manifest runners. Numerical planning,
validation, target preparation, waveform construction, checkpointing, and GUI
code remain shared with real operation.

The global `Waveform_Camera_Sync_Acquisition` call was placed behind
`adaptive_optopatch.execute_waveform_camera_sync`. Dispatch to synthetic
completion requires the explicit class identity
`adaptive_optopatch.testing.SimulatedLuminosApp`; a similarly named property on
an arbitrary object is insufficient. This is the safety boundary that prevents
simulation from reaching hardware acquisition code while preserving the
unchanged real-Luminos default.

The simulated app owns an in-memory synthetic Camera 1/galvo calibration. The
2P resolver and settings snapshot use that artifact only for the explicit
simulator class, avoiding reads or writes to the persistent active-calibration
store. Simulated 2P feedback copies commanded X/Y samples so integration and
metadata paths can be tested without claiming to model galvo dynamics.

For parity with the normal operator workflow, `simulatedLuminosApp()` is a
top-level constructor-style facade over the package factory. It still returns
the explicitly recognized `adaptive_optopatch.testing.SimulatedLuminosApp`
class, preserving the acquisition safety boundary.

## 2026-09-02 — Unified editable-plan and frozen-run workflow

`AdaptiveOptopatchApp` now extends the established reference/ROI planner and is
the primary operator interface. The base planner exposes its implementation to
subclasses and calls a small `planChanged` hook; the ROI drawing, renumbering,
QC, restoration, contrast, target generation, and artifact schemas therefore
remain single implementations rather than being copied into another GUI.

The unified app maintains three explicit states: `DIRTY`, `VALIDATED`, and
`RUNNING`. Validation stores a value snapshot containing reference, targets,
manifest, and planning session. A run first writes that snapshot through the
existing bundle serializer with an `adaptive_optopatch_run` prefix, then passes
the frozen manifest and targets to the existing modality-specific runner.
Planning controls and ROI interaction are locked during execution. Safety
confirmations remain current operator actions, while waveform, power, release,
and motion parameters come from the frozen planning session during execution
and resume.

Resume loads the frozen provenance artifacts directly. It does not rebuild
the manifest from the editable GUI. The 2P manifest runner was updated to reload
its existing checkpoint, matching the already-resumable 1P behavior.

## 2026-09-02 — Pulse protocols become independent design artifacts

Pulse timing was removed from the unified acquisition GUI and made a canonical,
versioned input artifact. This original schema was superseded on 2026-09-03 by
the pulse-level schema 2 described above; nested `pulse_times_s` train rows are
intentionally rejected rather than migrated silently.

Every frozen run now includes `pulse_protocol.mat` alongside the spatial target,
manifest, session, and checkpoint artifacts. Resume requires this archived copy,
so an unavailable original design-script output cannot silently change what is
run. The GUI stores the source path for editable-session restoration but reports
a missing path and requires an explicit replacement selection.

## 2026-09-02 — Unified GUI height allocation

The unified app reserves fixed heights for the pulse-protocol controls and trial
table. Planning rows are compacted after obsolete pulse-design controls are
hidden, and surplus window height is assigned to the camera/planning region.
This keeps both operator control sets visible while allowing the camera image to
benefit from a larger window.

## 2026-09-03 — Legacy Luminos snapshot compatibility

Luminos snapshots written before `CL_RefImage` gained `bin` and `timestamp`
remain valid reference images. The reader infers missing binning from the saved
world limits and image dimensions, uses the MAT file modification time when the
capture time is absent, and accepts the earlier direct DMD-transform layout in
addition to the current named transform array. Camera identity checks remain in
place but are case-insensitive. Because MATLAB otherwise materializes a saved
`CL_RefImage` as an empty object when the class is unavailable, the reader adds
only Luminos's `src/utils/Data_Structures` directory from a sibling
`luminos-private` checkout when needed; it does not recursively add Luminos.

## 2026-09-03 — Pulse protocol script collection

Pulse-design scripts now live in the first-class `pulse-protocols` directory.
They cover randomized connectivity, fixed-rate pulses, mixed-frequency STF,
paired-pulse recovery, and explicit custom events while sharing the canonical
validation and serialization API. Generated MAT artifacts are written beneath
an ignored `generated` directory so source and experiment inputs remain
separate.

## 2026-09-03 — Calibration is advisory provenance and Blue stacks initialize explicitly

Adaptive Optopatch treats experimental calibration state as advisory provenance
rather than a rigid configuration lock. Safety- and execution-critical
mismatches remain hard errors, while scientifically plausible changes to ROI
geometry, mask padding, stimulation amplitude, or calibration conditions
generate visible warnings but remain under operator control. Each new Blue
calibration decision stores the chosen voltage together with the pulse duration,
Blue-mask adjustment and area, canonical ROI polygon, OBIS setpoint when known,
source acquisition, timestamp, and notes. Older FOV files remain loadable when
some or all of these fields are absent. Round-robin generation still defaults to
cells the operator marked `good`, but after a protocol is frozen its explicit
per-pulse voltage is the source of truth as long as it remains within physical
hardware limits.

An externally triggered Blue ALP stack is now armed with
`Write_Stack('slave')` and advanced by exactly one DAQ trigger per physical
pulse. The first edge occurs at acquisition time zero while mod488 is dark,
selecting pattern 1 during the protocol pre-delay. Each later edge occurs at the
previous optical pulse's offset and uses the existing dark interval for target
switching. No configurable DMD settle interval was introduced. Frozen waveform
metadata records every trigger time together with its associated pulse ID,
target cell ID, and DMD pattern index.

The Orange recording mask has an explicit deployment action. It always rebuilds
the union of current `recording_enabled` canonical ROIs at the current Orange
expansion, requires the specifically named and calibrated `DMD_Orange`, and
programs it through Luminos without modifying canonical ROI geometry.

## 2026-09-03 — Blue spatial QC is advisory

For Blue-DMD stimulation, ROI overlap and edge proximity are spatial QC
advisories rather than execution gates. They remain visible and archived so the
operator can judge targeting specificity, while explicit stimulation exclusion,
invalid target identity, unusable DMD geometry, and physical hardware limits
remain hard errors. The diagnostic `blue_qc_pass`, `dmd_overlap_pixels`, and
`edge_flag` fields remain part of every target bundle; only their role in 1P
eligibility changed. Two-photon spiral and parking QC remains an execution gate.

## 2026-09-04 — Persistent FOV and automatic run freezing are the primary workflow

The unified GUI no longer presents a manual planning-bundle save action and no
longer restores a hidden “latest plan” when a Luminos snapshot is loaded. A
saved FOV is the explicit persistent home for canonical ROIs, cell state, and
the six spatial/setup controls. Exact runnable state is still frozen
automatically before acquisition, including the resolved protocol, manifest,
planning session, hardware controls, derived targets, and FOV snapshot. Legacy
planning-bundle serialization and restoration remain available to the standalone
reference planner for compatibility.

## 2026-09-09 — Current editable state replaces plan invalidation

The unified app no longer has a `DIRTY`/`VALIDATED` cache or operator
acknowledgement controls for OBIS override, output arming, staged release, and
trajectory review. Preview and diagnostic checks build from current controls;
run actions rebuild, perform mandatory modality-specific preflight, and freeze
that exact state before acquisition. Resume remains distinct and loads only the
archived plan and checkpoint. Luminos/React owns the OBIS setpoint, whose active
value is captured for provenance without being changed by Adaptive Optopatch.

Recording and stimulation eligibility are independent persistent cell fields.
The QC table checkboxes update those fields directly without creating or
replacing a Blue calibration record. The staged standalone 2P modes remain
available, while the unified path uses a standard mode that preserves motion,
calibration, waveform, camera, routing, and device preflight without the removed
acknowledgement steps.

## 2026-09-09 — Schema 3 separates intent from frozen acquisitions

Pulse protocols now contain explicit acquisition definitions, a target policy,
and an explicit ordered/randomized rule. Reusable definitions never name ROI
IDs. A single generic resolver combines event and acquisition overrides with
the current FOV cells and GUI defaults, validates parameter scope, realizes all
target ordering and timing jitter, and emits literal per-acquisition schedules
with value provenance. Acquisition count is never inferred from parameter
vectors. `each_stimulation_enabled_cell` expands each explicit definition once
per selected cell; `multi_target_continuous` resolves a multi-cell event stream
inside each explicit definition.

This is an intentional pre-production schema break: protocol schema 3 and FOV
schema 2 reject obsolete artifacts rather than migrating them. Categorical
Blue calibration status and the coupling between Stim eligibility and selected
voltage were removed. Record, Stim, and Blue voltage are independent; voltage
is required only when generic parameter resolution still needs it. Frozen runs
archive both the source definition and resolved acquisition schedules, and
runners execute only the latter.

## 2026-09-09 — 1P Blue executability follows the resolved event, and overlap is no longer a concept

`build_target_bundle` computes a bundle-level Blue mask from a single
default/GUI adjustment, but schema 3 lets a resolved event override that
adjustment per pulse. Gating 1P executability on the bundle-level mask (via the
former `is_blue_target_executable`) was therefore architecturally wrong: an
invalid default could silently exclude a target whose actual resolved event
was executable, and a valid default could mask an actual resolved event that
was not. Resolution and preflight now determine executability from the
resolved `(target, blue_mask_adjustment_pixels)` pair applied to the canonical
ROI through the same `apply_blue_mask_adjustment` primitive used at DMD
execution time (`resolve_protocol`'s `validate_blue_mask_executability` and
`preflight_trial`'s per-event mask check). `build_target_bundle` no longer
errors when its own default adjustment would empty a ROI; that bundle-level
mask is now only a convenience/default value for display, never authoritative
for execution.

Blue-mask overlap with other ROIs was removed as a spatial QC/advisory concept
entirely (`dmd_overlap_pixels`, `blue_qc_pass`, and the `blue_mask_overlap`
advisory). It was advisory-only prior to this change (see 2026-09-03) and is
no longer computed, displayed, or archived; edge-proximity QC/advisories are
unaffected and remain separate from mask emptiness.

## 2026-09-09 — Editable edits never mutate or discard an active frozen run

`planChanged()` previously cleared `ActiveRunPlan`/`ActiveRunFolder` on every
editable GUI change, including ordinary per-cell calibration edits made
between acquisitions of an already-frozen multi-cell run. Because
`executeCurrentPlan` treats a missing active plan/folder as "nothing frozen
yet," this silently orphaned the partially completed frozen run: the next
"Run next" click froze a brand-new run in a new folder rather than continuing
the original one.

`planChanged()` now only clears the active plan/folder and reverts
`PlanState` to `EDITABLE` when no frozen run is currently active. Once a run
is frozen (or resumed via `resumeRun`), later editable changes set
`EditableStateChanged` for display purposes only; the frozen plan and folder
remain authoritative until explicitly replaced. `executeCurrentPlan` no
longer treats `EditableStateChanged` as a reason to re-freeze — it freezes
only when no active frozen run exists. Starting a genuinely new run over an
active one still requires an explicit call to `freezeCurrentPlan` (there is
no separate GUI action or confirmation gate for this); resume is likewise
unaffected by editable GUI state.

## 2026-09-09 — Audit fixes use a conservative local task orchestrator

The remaining audit findings are represented as small committed JSON tasks with
separate handoffs, while mutable state and logs stay ignored. Each worker starts
from the then-current authoritative `main` in a sibling worktree, produces one
commit, and is tested and pushed only as a review branch. Explicit approval is
the boundary for cherry-picking into `main`; passing tests alone never triggers
integration. Conflicts and post-pick test failures deliberately stop for human
judgment. This keeps the successful isolated-worker workflow reproducible while
avoiding an autonomous layer that could make experimental policy decisions.

## 2026-09-09 — Staged 2P execution is execution state, not a rewritten manifest

`run_2p_manifest` previously implemented staged and pilot release levels by
rewriting the frozen manifest in place: it reduced the trial table to the single
selected trial, truncated that trial's resolved event table, renamed the
protocol and output tag, and reset the acquisition status. The frozen manifest
is archived acquisition truth, so a commissioning mode must not turn it into a
different experiment, and the rewritten table was what reached the run record
and the checkpoint.

The staged selection is now computed by `plan_staged_2p_execution` as pure
metadata (`run.staging`): release level, selected trial index/id, executed event
count, output-tag suffix, and command-voltage policy. The runner iterates the
unchanged frozen trial table, executes only the selected row, and derives that
row's execution schedule from a working copy. Both survive in provenance —
`executed_pulse_schedule` beside `pulse_schedule`, and `frozen_pulse_schedule`
beside `pulse_schedule` in `adaptive_optopatch_record`. Staged levels checkpoint
to `run_2p_checkpoint_<level>.mat` so a commissioning acquisition cannot mark an
experimental trial complete.

`attenuated_test` and the pilot levels already required an explicitly confirmed
positive Pockels voltage, and the README already documented it as the voltage to
run at, but the runner discarded it and executed the frozen experimental
command. Software semantics and physical execution therefore disagreed on the
one axis where that is most dangerous. The confirmed voltage is now applied
verbatim to the executed schedule and reaches the Pockels waveform unchanged; no
attenuation factor is inferred from the label. Conversely, `blocked_test`
(0 V by definition) and `experimental`/`standard` (frozen resolved command) now
reject a positive override rather than accepting and ignoring it.

## 2026-09-09 — The standalone 2P runner consumes schema 3 instead of reimplementing it

`TwoPhotonTestRunnerApp` had drifted to schema 2: it read `pulse_duration_ms`,
`dark_interval_range_ms`, `pre_delay_ms`, `post_delay_ms`, and `pulse_count`
off a resolved acquisition that no longer has them; it truncated the event
table itself; it called `generate_screen_protocol`/`generate_stf_protocol` at
run time and put the resulting *experiment definitions* into a manifest row
that must hold *resolved acquisitions*; and it attached an inert
`hardware_command_voltage` field. It also passed `default_stf_conditions` an
option that does not exist. The simulated launcher still dispatches to it for
every `2p_spiral` bundle, so it remains a supported commissioning interface and
was rebuilt rather than removed.

It now loads a frozen bundle and drives the canonical staged path:
`plan_staged_2p_execution` chooses the subset, `stage_2p_execution_protocol`
derives the executed schedule, and `run_2p_manifest` executes it. Preview and
acquisition therefore come from one implementation. The GUI no longer
synthesizes an STF protocol; `pilot_mixed_trains` runs a bundle frozen from an
`stf_mixed_conditions` protocol designed in `pulse-protocols/`, keeping the
protocol artifact canonical. When the bundle archives a scanner calibration,
both preview and execution use that frozen targeting transform.

## 2026-09-09 — The DMD's own minimum picture time bounds pattern advance

Nothing protected the externally triggered Blue pattern-advance interval. A
frozen schedule whose end-to-start dark interval is shorter than the ALP can
display would drop advance triggers, so a pulse would be delivered through the
previous pulse's mask — light on the wrong cell, with no error.

No constant was invented for this. The ALP exposes `ALP_MIN_PICTURE_TIME`,
documented as the minimum time between the start of consecutive pictures, and
Luminos's `Write_Stack` already programs exactly that value into the allocated
sequence, so it is authoritative for the stack that is loaded.
`dmd_pattern_advance_capability` reads it (preferring an explicitly declared
`minimum_picture_time_us` when a profile or test backend states one), and
`prepare_luminos_dmd_sequence` checks the frozen advance schedule against it
immediately after the stack is written — before the DAQ waveform is built and
before the shutter opens. The frozen schedule is never stretched to fit; a
violation is reported with the offending interval and its two pulses. When the
device reports no capability, the configuration records that the interval was
not validated rather than substituting a guess.

## 2026-09-09 — What the live waveform sample rate is allowed to change

1P timing is frozen in seconds, not samples: the mod488 waveform is described
to Luminos as pulse onsets/offsets and Luminos samples it at whatever rate the
active protocol uses. The rate therefore decides whether the frozen pattern
physically exists at all. Two failures are unambiguous and now block before
output: a light pulse whose window contains no sample emits nothing, and a
dark interval between two light pulses that contains no sample fuses them into
one longer pulse. The same rate sets the DMD advance-trigger width
(`max(3/rate, 20 us)`), so a low rate can also push a pattern-advance edge into
the pulse it selects; that is checked against all light windows rather than
only the initialization trigger.

Everything else the rate changes is bounded by one sample period. The frozen
schedule is not adjusted to fit the rate; the realized per-pulse sample counts,
durations, and the maximum duration error are recorded in the waveform
summary's `pulse_realization` so the quantization actually used travels with
the acquisition. What tolerance, if any, should turn that quantization error
into a hard failure is an experimenter decision and was not invented here.

2P timing is frozen in samples instead: `build_2p_trial_waveforms` emits literal
X/Y/Pockels vectors that Luminos replays at its active rate. That invariant was
already enforced (`resolve_luminos_2p_hardware` requires the profile rate and
`build_luminos_2p_waveform_config` rejects a mismatch), so no check was added;
the waveform builder is now simply given the resolved rate instead of keeping
its own copy of the constant.

## 2026-09-09 — The frozen camera grid is part of the frozen geometry

Canonical ROIs, Blue and Orange masks, and every camera-pixel target
coordinate live on the reference snapshot's pixel grid, but nothing compared
that grid with the camera actually acquiring. Rebinning Camera 1 or moving its
sub-ROI after freezing changes what a frozen camera pixel means, so the
recorded traces could no longer be attributed to the canonical cells.
`extract_roi_traces` already refused such a movie, but only after the
acquisition had been spent.

`build_target_bundle` now freezes that grid as `targets.reference_camera`
(frame size, sensor origin, binning, world limits), and
`validate_camera_geometry` compares it with the live voltage camera in both
runners and in the unified preflight, before any output. The check is not
cosmetic: only sensor origin, frame size, and binning matter, because those
are what make pixel (r,c) of an acquired frame the same sensor region as pixel
(r,c) of the reference. A bundle that predates the frozen grid is rejected
with a regenerate message rather than silently skipping the invariant.

A simulated rig has no sensor, so `make_simulated_luminos` accepts explicit
`CameraRoi`/`CameraBin` options for headless tests. During normal interactive
use, loading a Snap or saved FOV updates only the packaged simulator's Camera 1
to the reference ROI and binning. Simulation therefore exercises the same
invariant as hardware instead of being exempted from it.

## 2026-09-09 — Removing the inert 1P pulse-voltage override

`OnePhotonRunnerApp` exposed an "Override pulse voltage" checkbox and field
and passed the value to `run_1p_manifest` as `ModulatorVoltageOverride`. The
runner immediately replaced it with `NaN`, and the option it forwarded,
`flatten_pulse_schedule`'s `ConfiguredVoltage`, had no body reference at all:
the whole chain had been dead since schema 3 made every resolved event carry a
concrete command voltage. An operator control that looks like it changes the
delivered light and does not is worse than no control, and the fix is not to
revive it — a frozen run must execute its frozen voltages.

The control, the runner option, the waveform-builder option, and the inert
`ConfiguredVoltage`/`ModulatorVoltage` parameters on `flatten_pulse_schedule`
and `build_2p_trial_waveforms` are gone; the 1P runner GUI now states that the
pulse voltage is the frozen per-pulse command. `run_manifest` keeps
`ModulatorVoltageOverride` only for the staged 2P path, where it is the
commissioning command that is genuinely executed. OBIS power override remains,
because it does reach the hardware.

## 2026-09-09 — Preview draws the resolved run, not the bundle defaults

`previewTargets` drew `blue_camera_masks` and `orange_camera_masks` straight
from the target bundle and reported the spiral radius, density, and pulse
duration from the GUI controls. Those are the bundle's *default* values.
Schema 3 lets a resolved event override the Blue-mask adjustment per pulse and
lets an acquisition override the Orange expansion and the 2P spiral geometry,
so the operator could be shown a mask no pulse uses and a spiral whose radius
and density the run does not have. Two of the values it printed came from
`PulseDuration` and `SpiralDensity`, controls the unified GUI hides.

`build_target_preview` is the one place preview geometry is derived. Given
resolved acquisitions it produces, through the same primitives execution uses,
the distinct per-event Blue masks (`apply_blue_mask_adjustment`), the resolved
Orange masks and 2P spiral geometry (`apply_acquisition_parameters`), and the
resolved pulse duration for the spiral-cycle metrics. It is not a second
resolver: it consumes the resolved acquisitions the plan already contains.
Without them - the standalone planner, which has no protocol artifact - it
returns the bundle defaults and says so in the status text.

The 2P waveform preview also now draws the targeting transform the plan will
be executed with (`reference.scanner.tform`, passed as
`build_2p_plan_preview`'s `TargetingTransform`) instead of whatever
calibration happens to be active.

## 2026-09-09 — "Freeze new run" is the operator's explicit run boundary

Editable edits deliberately no longer replace an active frozen run, but the
only way to start a new one was to call `freezeCurrentPlan` from the command
line: from the GUI, a session's first frozen run stayed active forever.
`Freeze new run` closes that gap. It is not a confirmation gate - nothing
irreversible or physical happens - so it is a plain action whose label and
result message make the consequence obvious: the new run becomes active, and
the replaced run is named so the operator can see it is still on disk and
still resumable.

## 2026-09-09 — Command-voltage precedence is intentional; one tier is an open question

`parameter_sources` narrows `command_voltage_v` to
`event > acquisition > protocol > fov_cell` for round-robin and Blue-mask
titration, excluding the GUI default. That is deliberate and matches those
designs: both exist to run at each cell's calibrated voltage, so a single GUI
value would defeat them, and a cell without a calibration fails explicitly.
Connectivity screen and STF declare no `parameter_sources`, so they use the
full precedence and can fall back to the GUI default. Nothing here is
inconsistent with the precedence architecture, and no generator was changed.

Two policy questions remain open and were deliberately not decided here:

1. Should `connectivity_screen` and `stf_mixed_conditions` also require a
   per-cell calibrated voltage instead of accepting the GUI default?
2. `protocol_parameter_metadata` maps the `fov_cell` tier of
   `command_voltage_v` to `selected_blue_voltage_v` for both modalities, so a
   2P acquisition on a cell with a stored Blue calibration silently executes
   that 488 nm calibration value as the Chameleon Pockels command, in
   preference to the GUI value. The provenance is recorded
   (`command_voltage_source = "fov_cell"`), and the resolved command and its
   source are now shown in the trial table before the run, but whether 2P
   should inherit that tier at all is an experimenter decision.

## 2026-09-09 — The Blue camera-to-DMD transform is live state, recorded not gated

A 1P run projects frozen camera-space masks through whatever transform
DMD_Blue currently holds: the transform lives on the device and is applied
inside Luminos's `setPatterningROI`, so Adaptive Optopatch cannot execute an
archived one without either warping masks itself or overwriting live scanner
state - the second of which the frozen-2P-calibration work deliberately
avoided. Recalibrating DMD_Blue between planning and execution therefore moves
where a frozen mask lands, and nothing recorded that.

The bundle now archives the transform the plan was built with
(`targets.stimulation_dmd_transform`) and each 1P run records the comparison
with the live one in `run.stimulation_dmd_calibration` and in the saved
per-acquisition record. Consistent with the accepted 2P policy, a difference
is provenance rather than an execution gate: recalibrating between runs is a
legitimate operator action, and what reproducibility needs is for the run to
say which calibration it actually used.

## 2026-09-10 — Luminos owns 1P camera-to-DMD calibration

Decided: the `DMD_Blue` and `DMD_Orange` camera-to-DMD transforms belong to
Luminos. Adaptive Optopatch owns camera-space biological ROIs, Blue and Orange
masks, resolved parameters, eligibility, mask adjustment, and timing; Luminos
owns the conversion into each DMD's coordinates and applies it.

The consequence is that a recalibration after a run was frozen is *used*. If
the frozen intent is "illuminate camera coordinate X" and Luminos's estimate of
where X lands on the DMD has improved, the new estimate realizes the same
intent better than the old one. So there is no drift gate, no replay of an
archived transform, and no mask warping inside Adaptive Optopatch.

Yesterday's provenance helper was framed as frozen-vs-live and named
accordingly, which implied the planning transform had standing it does not
have. It is replaced by `capture_1p_dmd_calibration`, which archives what
Luminos actually applied for both DMDs — transform, DMD dimensions, reference
image geometry — and, only where a planning snapshot exists
(`targets.planning_blue_dmd_transform`), whether the projection changed since
planning. `run.dmd_calibration.authority` names the owner explicitly.
`resolve_luminos_1p_hardware` resolves `DMD_Orange` non-fatally so its
calibration can be archived too; `prepare_luminos_orange_mask` remains the
place that requires and validates it. No Orange calibration subsystem was
added.

2P is deliberately different and unchanged: Adaptive Optopatch owns the
camera-to-galvo calibration and a frozen run executes the transform archived
with it.

## 2026-09-10 — The 2P Pockels command is protocol-only

Decided: for `2p_spiral`, the stimulation voltage must come from the protocol
artifact. Generic precedence let it fall through to the `fov_cell` tier, which
`protocol_parameter_metadata` maps to `selected_blue_voltage_v` — a per-cell
488 nm calibration — and then to the GUI default. A 2P acquisition could
therefore execute a Blue calibration value as a Chameleon command, in
preference to the GUI value, with only `command_voltage_source="fov_cell"` to
show for it.

`resolve_protocol` now narrows the allowed tiers for `command_voltage_v` to
`event > acquisition > protocol` whenever the mode is `2p_spiral`. The
narrowing is applied after a definition's own `parameter_sources`, so a
protocol cannot widen it back. An unresolved 2P command raises
`MissingTwoPhotonPockelsVoltage`, whose message names the missing explicit
voltage rather than reporting a generic fall-through, and
`validate_protocol_for_mode` reports the same incompatibility at protocol load
so the operator does not discover it at freeze time.

No `pockels_voltage_v` field was introduced. The resolved schedule must keep
`command_voltage_v` — the waveform builders, validators, runners, record, and
GUI all read it — so a second input spelling would be a competing name for the
same value rather than a separate concept. The five required invariants are
enforced by the source rule, not by the field name, so `command_voltage_v` is
retained and documented as the explicit, protocol-only Pockels command for
`2p_spiral`. No per-cell 2P voltage tier was added.

The unified GUI's command-voltage field is now labelled `mod488 (V)` and is
disabled in 2P mode, because nothing typed there can reach a Pockels command.

## 2026-09-10 — One production acquisition interface

`AdaptiveOptopatchApp` is now the only production acquisition GUI for both 1P
and 2P. The standalone 1P, staged-2P, settings-review, and reference launchers
duplicated slices of the unified workflow and were removed with their GUI-only
classes. Their reusable execution behavior was already implemented by the
canonical `run_1p_manifest`, `run_2p_manifest`, staged-execution, preview, and
validation functions, so no acquisition logic moved or changed.

The root contains experiment-day entry points plus the small
`simulatedLuminosApp` compatibility factory. The guarded galvo-dynamics wrapper
lives under `tools/commissioning`; that specialized directory is added to the
MATLAB path explicitly when needed. The canonical simulator remains packaged
under `adaptive_optopatch.testing`.

## 2026-09-10 — Simulation mirrors the real GUI launch workflow

`simulatedLuminosApp()` is again the one-line no-hardware stand-in for the
Luminos object passed to `launch_adaptive_optopatch_gui`. It delegates to the
packaged simulator rather than defining a second backend. When the GUI loads a
Snap or persistent FOV, `ReferencePreparationApp` asks that packaged simulator
to adopt the reference Camera 1 ROI and binning. The type check prevents this
path from mutating a real Luminos camera, and ordinary camera-geometry
validation remains active after the match.

The separate simulated-GUI launcher was removed because composing a simulated
Luminos object with the canonical GUI launcher is now both simpler and closer
to the experiment workflow. Camera-geometry mismatch diagnostics also retain
their column-vector shape when several issues are reported together.

## 2026-09-10 — Rig commissioning inputs are interpreted literally

Luminos terminal names are trimmed before multi-DAQ comparison, so harmless
leading or trailing whitespace cannot make a configured bridge appear
different. Terminal identity itself remains exact.

For a camera in DAQ-triggered `Trigger each Frame` mode,
`daqtrig_period_ms` is the configured cadence and directly determines both
frame rate and requested frame count. Luminos's `calculate_framerate()` value
is retained as diagnostic metadata but no longer acts as a second hard limit,
and the former 0.85 gate does not apply. Invalid DAQ periods still fail before
acquisition. FOV and protocol dialogs now use character-vector filter cells for
compatibility with the VU MATLAB release.

## 2026-09-10 — The operator panels show decisions, not ownership

The pulse-protocol panel had grown a row of ownership captions -- `OBIS power
is owned by Luminos/React`, and a `Pockels: from protocol` note beside the
command-voltage field -- and a sixth grid row. The root grid gives the panel
250 px; six rows asked for 273. MATLAB does not report the overflow, it simply
clips, and the bottom row went with it: `Review completed Blue ramp…` and
`Freeze new run` sat at y = -20, effectively unreachable.

Removing the captions is the fix and also the right call on its own terms. The
ownership rules they stated are real and unchanged -- Luminos/React owns the
OBIS setpoint, and the 2P Pockels command is protocol-only -- but they are
facts an experimenter needs once, not every time they look at the panel, and
here they were paying for that in the height of a button. The rules now live in
the field's tooltip, and the enforcement is where it always was: the control is
disabled in 2P, which `commandVoltageEnabled` still reports and the 2P Pockels
tests still assert. No GUI Pockels input was introduced; `command_voltage_v`
for `2p_spiral` remains protocol-only.

Reworking the panel exposed a control that had been present, editable, and
invisible. `ModulatorVoltage` is created in the planning grid and reparented
into the protocol panel, and reparenting carries a component's grid coordinates
with it -- so its one-cell wrapper silently grew to the planning grid's 18x2
shape and laid the field out with zero height. The GUI has been showing a
`mod488 (V)` caption with nothing beside it. The wrapper is now pinned to one
cell and the field placed explicitly, and a test asserts that shape, because
the failure mode is silent: nothing errors, the value still resolves, and only
a rendered figure reveals it.

The cell table now leads with `Cell ID | Record | Stim | Blue V (1P)`. Those
are the three per-cell decisions an experimenter actually makes, and the table
is narrow enough that they previously sat behind a horizontal scroll while area
and centroid held the front. `Blue V` was renamed to `Blue V (1P)` because the
bare name reads as a generic stimulation voltage; it is the per-cell 488 nm
calibration and there is deliberately no 2P column beside it, since a 2P
acquisition takes its Pockels command from the protocol rather than per cell.
The reorder is presentation only -- the edit callback still writes Record and
Stim through `setCellEligibility`, and Blue V stays read-only.

## 2026-09-10 — Acquisition quick-look follows explicit frozen-run linkage

`inspect_acquisition` is deliberately a viewer, not a preprocessing pipeline.
Each new runner record points explicitly to its frozen run and
`reference_model.mat`; the viewer refuses to guess when that linkage is absent
or inconsistent. It passes the linked `reference.roi_masks` directly to
`extract_roi_traces` with background, motion, and photobleach correction all
disabled, so the displayed cells are exactly the canonical biological ROIs
used for planning.

The stimulation panel is built from
`adaptive_optopatch_record.pulse_schedule`, which is the schedule that actually
executed. This distinction matters for staged 2P: its separate
`frozen_pulse_schedule` remains immutable acquisition intent, while the saved
executed schedule contains the subset and attenuation physically commanded.

## 2026-09-11 — Acquisition reference links are portable across data mounts

Acquisition records now store `reference_model_path` from the `Snaps` path
component downward, using `/` as the serialized separator. The recording root
is the current directory immediately above `Snaps`, not a root inferred from a
possibly stale saved path. This keeps new links stable when a date folder moves
between Windows and Linux.

The inspector remains read-only and accepts legacy absolute links. An existing
absolute path wins on its original machine; otherwise the resolver parses both
slash styles, recovers the case-insensitive `Snaps/...` suffix, and attaches it
to the current recording root. Missing-link diagnostics report the saved link,
current root, and reconstructed candidate.

## 2026-09-10 — Stimulation modality is an exclusive hardware owner

Preserving a loaded Luminos waveform is correct for imaging and acquisition
outputs, but unsafe for stimulation outputs owned by the inactive modality. A
1P configuration now replaces both 2P galvo commands with stationary constants
and the Pockels command with dark. A 2P configuration replaces mod488 with dark,
holds the Blue-DMD trigger low, and closes shutter488; the runner also writes a
blank static Blue-DMD target before acquisition. Orange DMD/illumination,
camera triggers, and all other waveform records remain untouched. The neutral
values and channel identities live in the Virtual Upright rig profiles rather
than in merge logic, making the safety decision explicit and testable.

The table is now the single manual editor for per-cell `Blue V (1P)`. Valid
values update `selected_blue_voltage_v` in the canonical FOV cell record without
changing its calibration notes or acquisition provenance; refresh and FOV
round-trips read the same field. Invalid values restore the stored value. The
former selected-cell dialog and button were removed, while voltage resolution
continues to use `event > acquisition > protocol > fov_cell > gui > error`.

## 2026-09-10 — Luminos owns the 488 OBIS operating mode

Rig commissioning showed that the Virtual Upright normally drives the 488 OBIS
successfully in `CWP` while Luminos independently executes the `mod488` AO
waveform. Forcing the laser into `ANALOG` suppressed the expected blue output,
so OBIS mode is not an Adaptive Optopatch execution prerequisite. The 1P
hardware resolver now observes `laser.Mode` for provenance but accepts it
without an allowlist and never writes it. Interlock, power range, mod488 port,
waveform timing, and all other live checks remain unchanged. Each acquisition
record still reads the actual live mode into `adaptive_optopatch_record.obis_mode`.

## 2026-09-10 — Quick-look timing follows the archived trigger authority

For a voltage camera archived as DAQ-triggered, `daqtrig_period_ms` is the
authoritative frame cadence just as it is during acquisition setup. Quick-look
extraction now uses `1000 / daqtrig_period_ms` ahead of camera-reported rate or
exposure metadata and rejects a missing or invalid DAQ period rather than
inventing a time base. The movie file size remains the authority for the number
of acquired frames. Non-DAQ cameras retain the existing reported-rate and
exposure fallbacks.

The quick-look figure now has a nested left plotting grid for traces and the
executed stimulation command, with the canonical ROI image in a separate right
column. Both time axes therefore receive the same horizontal geometry as well
as linked x limits, so an event is physically aligned beneath its trace time.

## 2026-09-10 — Frozen definitions can produce multiple execution batches

A completed run folder represents one execution batch, not exhaustion of its
frozen experimental definition. `Start new batch` now writes a distinct sibling
run folder from the active completed plan, resets only trial execution fields,
and copies the already-resolved protocols rather than resolving or randomizing
again. The prior checkpoint and acquisition directories are never changed.
`Resume run` remains different: it selects the same folder and continues from
that folder's existing checkpoint.

Each frozen manifest, planning session, and trial row carries execution-batch
metadata: `batch_id`, `batch_number`, `frozen_definition_id`, and rerun-parent
identity/directory. This makes the initial frozen definition, batch chain, and
per-acquisition provenance explicit while leaving protocol and runner schemas
otherwise unchanged. Timestamped run-folder allocation with collision suffixes
continues to provide unique batch output roots.

## 2026-09-13 — Inspection FOV uses the acquisition mean

The inspection ROI panel now displays the mean of the acquired voltage-camera
frames rather than the planning snapshot. The mean is accumulated during the
existing trace-extraction pass and cached, avoiding a second movie read. ROI
outlines and identities remain sourced from the frozen canonical reference.

## 2026-09-11 — Repeated batches re-resolve randomized schedules

An execution batch remains the resumable unit: resuming an incomplete folder
continues its exact archived pulse schedule. After a batch completes, however,
`Start new batch` now sends the same archived experiment definition through the
canonical protocol resolver again. Randomized protocols therefore receive a
fresh realized event order while deterministic definitions retain their order;
the new resolved schedule is archived in the new batch. The user-facing
round-robin creation script now defaults to 100 stimulations per target, keeping
each acquisition and its DMD event stack manageable.

The GUI can chain a requested number of these batches through the existing
single-batch executor and `Start new batch` transition. Each block therefore
retains its own folder and checkpoint, and chaining stops before allocating the
next block after a failure or stop request. `Return to editing` only detaches
the active frozen plan; the loaded FOV, cell decisions, calibrations, protocol,
and GUI values stay in memory while completed run artifacts remain on disk.

## 2026-09-11 — DMD reference grids must match frozen camera masks

Both 1P paths give Luminos ROI-local camera masks and rely on each DMD's active
`refimage` to place those pixels in sensor coordinates before transformation.
Archived data demonstrated that a stale full-sensor Blue reference caused a
current 180-by-400 target mask to be resized to 2304-by-2304; an exact replay
fully clipped one target and displaced another. The live camera still matched
the frozen planning reference, so camera-only validation could not detect this.

AO now embeds each ROI-local Blue and Orange mask into the active DMD
reference-image grid using the two grids' sensor origins before asking Luminos
to transform it. A smaller current ROI is valid when it is fully contained and
integer-aligned within the DMD reference at the same binning. Missing geometry,
incompatible binning, misalignment, or any required clipping stops execution
before either mask is programmed. Luminos continues to own and apply the
camera-to-DMD calibration itself.
## 2026-09-14 — Protocol-owned round robin and FLUT-backed DMD execution

Constrained round-robin scheduling belongs to the pulse-protocol layer: it
materializes exact target order, timing, balancing, recovery gaps, and voltage
before AO freezes a run. AO treats those events as authoritative and rejects
only concrete execution incompatibilities. For 1P DMD sequences, final
camera-space masks are deduplicated by pixel content, uploaded once to Luminos
slots, and referenced by an event-sized FLUT playlist. Non-FLUT devices retain
an explicit physical-event-stack fallback; FLUT capacity overflow is an error
rather than an automatic protocol split.

## 2026-09-15 — Isolated FLUT wrap diagnostic

FLUT wrap behavior in continuous slave mode is a controller property, not
something software tests can establish. A narrowly tagged hardware diagnostic
therefore programs only slots `[1 2 3]` while emitting eight ordinary event
triggers, with expected observations `[1 2 3 1 2 3 1 2]`. The tag is validated
strictly, requires three distinct masks and FLUT capability, and cannot change
production playlist semantics. Both the three-entry programmed playlist and
the eight-event expectation are archived for interpreting the acquisition.

## 2026-09-15 — Persistent soma drawing and protocol-owned Blue voltage

Soma annotation is a persistent-until-empty interaction: one button activation
commits each valid polygon immediately and begins the next, while an empty,
degenerate, or cancelled polygon exits without changing earlier cells. The AO
GUI no longer owns a mod488 voltage field or serializes a hidden replacement.
New plans resolve 1P voltage from event, acquisition, protocol, or explicit
per-cell FOV calibration; the physical mod488 waveform path is unchanged.

## 2026-09-15 — Session state belongs to a controller, not to the widgets

Adaptive Optopatch is heading for two frontends: the MATLAB GUI it has now,
and a Luminos React panel later. Nothing about acquisition or transport
blocked that. What blocked it was ownership: soma geometry lived in
`drawpolygon` handles, plan values lived in `uieditfield` values, protocol
identity and the frozen run lived in app properties, and the run lifecycle was
readable only as which buttons happened to be enabled. A second frontend would
have had to reimplement all of it.

`AdaptiveOptopatchController` now owns that state and can be constructed
without a figure. It holds the reference FOV, canonical soma polygons and
stable cell IDs, per-cell decisions, editable plan parameters, the loaded
protocol, the frozen run, the active run folder, status, and an explicit
lifecycle. It orchestrates the existing package functions rather than
duplicating them: `resolve_protocol`, `build_manifest`, DMD/FLUT planning,
waveform generation, and both runners are unchanged and still own their
domains.

The decisive change is ROI ownership. A polygon's vertices are canonical data
held in a plain struct, rasterized by `soma_polygon_masks` and summarized by
`summarize_soma_geometry`; the `drawpolygon` object is a view that renders
those vertices and reports edits back through `updateSomaPolygon`. Geometry
itself was moved, not rewritten: vertices stay in snapshot intrinsic pixel
coordinates, `poly2mask` still rasterizes them, and `create_reference_model`
and `create_fov_state` still produce the schema-2 artifacts, so cropped FOVs,
binning, and full-sensor centroids behave exactly as before. Zero-area and
out-of-bounds polygons remain reachable and remain QC `CHECK` rather than
errors, because rejecting them would abort an interactive drag.

Guards moved with the state. Disabled widgets used to be the only thing
stopping a soma edit or a plan change during acquisition; the controller now
refuses them itself with `adaptive_optopatch:AcquisitionActive`, and the GUI
derives its enabled state from the lifecycle instead of defining it. These are
data-integrity guards only — no biological or scheduling restriction was
added, and an editable change made while a run is frozen still applies to the
next run rather than mutating the archived one.

`getState()` returns a plain struct that `jsonencode` accepts: revision,
lifecycle, status, FOV metadata, canonical polygons, per-cell rows, protocol
summary, plan parameters, active-run summary, and which actions are currently
legal. Reference images, mask stacks, targets, and manifests stay outside it
and are fetched through their own accessors. A monotonic `Revision` advances
on every canonical mutation; the MATLAB GUI does not need it, but it is what
makes stale-state detection possible once a second frontend exists.

One latent bug fell out of the extraction: restoring polygons used to renumber
cells to `cell_001…N` without moving `next_cell_index`, so the next drawn soma
could reuse an existing ID in memory. Setting the polygon list now derives the
next index from the IDs themselves.

Deliberately left in the GUI: the in-progress `drawpolygon` interaction, list
selection, overlay visibility toggles, file dialogs, planning-bundle discovery
on snapshot load, and all axes rendering. Those are view concerns, and a React
frontend will implement its own.

## 2026-09-16 — One chooser for references, and previews that compute nothing

The React tab could start a session from a camera snapshot but not from a
saved FOV, so the step that carries the experiment's actual decisions —
somata, stable identities, eligibility, Blue calibration — still needed the
MATLAB window. The obstacle was never transport; it was that `load_fov` took a
path, and a browser must not send one. `snapshotChoices()` had already solved
that shape, so the fix was to widen it rather than to invent a second one.

`referenceChoices()` lists both in one typed listing. A `snapshot` entry loads
through `loadSnapshot` and yields a fresh FOV with no cells; an `ao_fov` entry
loads through `loadFov` and restores everything the bundle holds. They are one
list because to an operator they are one question — which field am I working
on — and typed rather than blended because an Adaptive Optopatch FOV must
never be read as a camera snap. `list_snapshot_choices` now excludes bundles,
which it had been listing as unreadable snapshots.

Saving allocates and never replaces. A bundle is written beside the snapshot
it descends from as `<snapshot>_FOV###`, at one past the highest number
present, re-checked against the filesystem. The name comes from
`reference.source_snapshot`, which survives a round trip, so a FOV saved from
`_FOV001` becomes `_FOV002` rather than `_FOV001_FOV001` and the whole chain
stays grouped with the one snapshot it views. `save_fov` therefore needs no
path and no name from the caller, exactly as `freeze_run` needs no output
root. The artifact is the existing schema-2 state through the existing
`save_fov_state`; there is deliberately no second persistence format for "a
FOV a browser saved". `fov.source_kind` and `fov.source_path` were added so a
frontend can say which entry is loaded and whether its cells were restored or
drawn — the summary's `snapshot_path` names the ancestor snapshot either way
and cannot answer that.

`set_cell_blue_voltage` was added to the allowlist. It had been absent on the
grounds that per-cell Blue voltage is provenance rather than an editable
control, which was the wrong reading of it: the MATLAB cell table has always
edited exactly this value through exactly this controller method, and calling
the same edit unsafe in one frontend and routine in the other was the
inconsistency. What makes it safe is not where it is typed but
`resolve_protocol`, which is unchanged: `event > acquisition > protocol >
fov_cell` means a protocol naming a voltage is unaffected, and the narrowing
to `event > acquisition > protocol` for `2p_spiral` means a 488 nm calibration
cannot reach a Pockels command. Both directions are asserted now, including
that the `fov_cell` tier still resolves when nothing else defines one —
without which the first assertion would pass for a value that never resolves
at all.

The two previews are read-only accessors over the code the planning window's
Preview button already calls: `build_target_preview` and
`generate_spiral_preview` for geometry, `build_2p_trial_waveforms` and
`flatten_pulse_schedule` for commands. What crosses the wire is `bwboundaries`
rings and spiral points in snapshot-intrinsic pixels, and decimated sample
vectors — coordinates and numbers, not masks and not a description a frontend
would have to interpret. Nothing is rasterised, eroded or spiralled in a
browser, and nothing new computes geometry.

Making them honestly read-only took one deliberate choice.
`buildSpatialArtifacts` refreshes `ScannerWarning`, so asking for a preview
would have changed `getState()` without bumping the revision — a state poll
altered by somebody looking at something. The warning is now saved and
restored around the call and reported in the preview's own payload instead.
Both previews carry the revision they describe, which is what lets a frontend
drop a stale overlay instead of deciding for itself which edits moved
geometry; every canonical mutation bumps the revision, so the rule needs no
list of which ones matter.

The waveform preview reports only the channels the canonical preview produces.
Orange illumination and the camera trigger are built by the Luminos waveform
configurators at execution setup, against live devices, and a preview that
manufactured stand-ins for them would be showing an experiment nobody
configured. A long 1P schedule is windowed at a whole pulse rather than
thinned, because a thinned step trace draws a schedule that was never
scheduled.

Two presentation faults were fixed on the same pass. The tab had been
displaying the seven legacy timing defaults — pulses per neuron, pulse
duration, dark-gap bounds, pre and post delays — whether or not a protocol was
loaded. `buildPlan` strips those from the saved session and every onset comes
from the protocol script, so they described nothing; where experiment timing
belongs the tab now says to load a protocol, and once one is loaded shows only
what `summarize_protocol` reports about it. And wheel-zoom over the canvas
scrolled the page as well as zooming, because React attaches `wheel` at the
root as a passive listener and `preventDefault()` on a passive listener does
nothing. The canvas now attaches its own listener with `{ passive: false }`
and removes it on unmount. Nothing is disabled document-wide: the listener is
on the element, so scrolling anywhere else is untouched.

## 2026-09-16 — The run lifecycle stops being an experimenter's problem

The tab exposed the controller's internal lifecycle as its vocabulary: Freeze
run, Freeze new run, Return to editing, Run next, Run all, Start new batch,
and a row of raw `legal_actions` names underneath. An experimenter does not
freeze anything. They configure a field of view, decide what to stimulate,
and run it. The workflow is now three words — configure, **Update plan**,
**Run** — and the machinery those six buttons named is still there, reached
by the MATLAB planning window and by no endpoint.

The gating was worse than the vocabulary. `legal_actions.run` was `editing`,
which is to say "not currently running", and both `runNext` and `runAll`
called `freezeRun()` when no plan existed. Pressing Run with nothing prepared
therefore froze whatever the editable state happened to be at that instant
and ran it, and pressing Run after an edit ran the OLD frozen plan without
saying so. Both are the same bug seen from two sides: there was no answer to
"is what I am about to run the thing I configured".

`planStatus()` is that answer — `not_ready`, `update_required`, `ready`,
`running` — and it is the controller's, not a frontend's. `assertRunnable`
consults it before anything executes, `legalActions` reports it, and the
endpoint inherits both. `run_next` and `run_all` were removed from the
allowlist rather than merely hidden, because an endpoint that still offered
them would still have the hole.

The substance is `executionInputs()`. Revision cannot be the test of plan
validity: it advances for a status line, for a poll that re-reads a run
checkpoint, and for saving a FOV, none of which changes what would be
acquired. So the inputs a plan is built from are enumerated explicitly, in
named groups — reference, somata, cell_decisions, protocol, spatial,
run_controls — and a prepared plan carries a copy. Staleness is `isequaln`
against that copy, which needs no hash and can say WHICH group moved, so the
message is "the plan is out of date (cell Record/Stim/Blue V)" rather than
"something changed".

Choosing what to leave out took the most care. A cell contributes its Record,
Stim and Blue V and not its calibration history, notes or acquisition
provenance — `saveFov` rebuilds the whole cell-state struct, and comparing it
wholesale would have made saving a FOV invalidate the plan. The reference
contributes the snapshot it descends from and not the file it was last loaded
or saved from, for the same reason. The seven legacy timing defaults
contribute nothing, because `buildPlan` strips them and every onset comes
from the protocol. The live scanner calibration and the OBIS power contribute
nothing either: they are hardware readings rather than operator decisions,
and the transform a frozen run executes is archived with it.

`repeat_batch_count` was the one input that was execution-affecting and not
captured. It was read live from `PlanParameters` at `executeRepeatedBatches`,
so changing Repeats silently changed how many acquisitions a prepared plan
would perform. It now travels in `session.run_controls` like the scanner
limits, the loop reads it from the plan, and changing it stales the plan like
anything else. Within one prepare-then-run cycle the two values are
necessarily identical, so no run behaves differently; what changes is that
the summary and the progress total now describe the plan rather than a field.

Batch semantics were audited before anything was renamed, because the task
would have been a runner change if they had not already matched. They did: a
manifest row is one resolved acquisition (`one_acquisition_per_row`), one
batch is one complete pass over them, and `runAll` already looped
`repeat_batch_count` complete passes. So **Repeats** is a relabelling of
`repeat_batch_count` and nothing else. The one nuance worth recording is that
repeats after the first are fresh realizations rather than replays: the
between-repeat transition is `startNewBatch`, which re-resolves the archived
definition, so a randomized protocol draws a new order each repeat and a
deterministic one does not. That is the 2026-09-11 decision, unchanged.

Two smaller things fell out. Run after a completed run used to do nothing —
the batch was complete, so the runner found no trials left — while
`startNewBatch` sat behind its own button. `runPreparedPlan` now performs
that transition itself when the active batch is complete, so an unchanged
plan is genuinely reusable and Run means run it again. And progress is now
the controller's: `RunProgress` records which repeat is in flight and the
checkpoint supplies the acquisitions completed within it, so
`Acquisition 7 / 48` counts across repeats instead of being inferred from a
batch number that also advances for other reasons. It is cleared when a plan
is prepared rather than when a run ends, so a finished run keeps reporting
the count it reached.

Deliberately not done: no mid-acquisition abort. Stop after current
acquisition is the only stop, as it has always been.

## 2026-09-16 — One rule for what "the same terminal" means

AO built waveforms on top of whatever was already in Luminos's `wfm_data`,
removed the records it was about to replace, and installed its own. The
removal compared strings. Luminos does not: `DAQ.remove_al` resolves rig
aliases case-insensitively, and `Same_Terminal` then strips whitespace,
drops every slash and lowercases what is left. So a waveform the operator
had drawn on `DMD Trigger` — which is the rig file's alias for
`Dev1/port0/line4`, and the spelling the Waveforms tab actually stores —
survived AO's filter untouched, and `Build_Waveforms` then de-aliased it
onto the same terminal as AO's advance train and handed both to
`Combine_Output_Waveforms`. The default operation is Multiplication, so a
stale constant of 0 annihilates the train and every pulse in the trial
illuminates cell 1; a stale pulse train adds advances nobody asked for.
Either way the light lands on the wrong cell and the data looks fine.

`canonical_terminal` is now the only place in the package that decides
whether two names denote one physical output, and it is `Same_Terminal`'s
rule rather than a second one. The alias list it resolves through is
transcribed into the rig manifest rather than read from a DAQ object,
because the waveform builders are pure functions over structs and have no
device to ask — and because an explicit transcription is the thing a
commissioning survey can check the live rig against, which
`report_vu_stimulation_outputs` now does.

Three removal helpers had grown up beside each other — one matching a name
and a port, one a list of identifiers, one the same with whitespace
stripped — and all three compared raw strings, so every one of them had
the same hole. They are one function, `remove_output_records`, matching on
both a record's name and its port because Luminos resolves by port and
matching the name as well only ever removes more than Luminos would
combine.

Two other holes closed with it. The DMD advance line was only cleared when
the trial had a sequence plan, so a single-target trial left whatever was
on it in place; it is now cleared unconditionally and carries the rig's
declared low state when AO commands no advances. And `shutter488` was
never cleared at all while the 1P runner also opened and closed it through
`hardware.shutter.State`, which is two runtime owners of one line. The
invariant is that exactly one thing drives a line while a task holds it,
and which one differs by modality: a 1P run must open the shutter, so the
imperative writes own it and no buffered record may exist; a 2P run holds
it closed for the whole acquisition, so the buffered constant owns it and
the single imperative close happens before anything is armed. The manifest
states that per modality and accounting checks it, rather than either
being a rule of thumb in a builder.

### Neutral values stay rig declarations

`virtual_upright_stimulation_manifest` consolidates what had been split
across `virtual_upright_1p_profile.inactive_two_photon` and
`virtual_upright_2p_profile.inactive_one_photon`, and it *reads* those
profiles rather than restating them — a copy would drift, and the existing
principle is that a neutral value is a rig safety declaration and never an
inference by waveform-builder code. Six outputs are AO's: mod488, the 488
shutter, the Blue DMD advance trigger, the Pockels cell and both galvos.
`mod594` and `shutter594` are declared `inherited_non_stimulation`, with
the reason, because AO deliberately runs inside the operator's own imaging
configuration and "AO does not own it" is not a classification. The two
camera trigger lines are declared as infrastructure Luminos adds itself,
after AO has installed `wfm_data`, through `Setup_Camera_Trigger_Waveforms`.

Four rig outputs are declared `unresolved` rather than guessed. `PMT
Shutter` is a `Voltage_Shutter` on `Dev2/ao2` — an analog output on the
galvo card whose neutral AO has never declared. `Shutter sensory` on
`Dev1/port0/line2` is named like a stimulation shutter. And
`Dev1/port0/line5` is the one the audit asked about: the rig file calls it
`General Shutter`, AO's own test fixtures have called it an Orange DMD
trigger since they were written, and the rig file gives `DMD_Orange` no
trigger terminal at all. One of those two readings is wrong, and AO cannot
tell which from here. Inventing a classification would have made the tests
green and the rig no safer.

### Measuring rather than believing

`account_stimulation_outputs` compiles the candidate configuration and
classifies each physical terminal as commanded, neutral, inherited,
expected Luminos infrastructure, or unaccounted — and for AO-owned
terminals it decides between commanded and neutral by evaluating every
sample against the declared neutral, not by looking at the record. A
record that looks like a zero constant is not evidence; what would reach
the wire is. A single stray sample on a Pockels line is a photon burst, so
the comparison is over every sample rather than a min/max pair that could
bracket the neutral and hide one.

The split between what blocks and what merely reports is the split between
what the code can prove and what it has simply never been told. A record
driving an AO-owned stimulation terminal without AO's ownership tag, two
records resolving to one AO-owned terminal, a buffered record on a line
this modality drives imperatively, a camera-triggered record on a
stimulation line: those are unsafe on the evidence available and fail
under either policy. A terminal nothing in the manifest describes is not
proof of anything, and Pass 3A's real-rig default is `report_only` for
exactly that reason — the VU's ambient configuration has not been surveyed,
and blocking a rig on AO's own ignorance would be the wrong kind of
caution. `fail_closed` is implemented and tested and is not the default
until `Dev1/port0/line5`, `PMT Shutter` and `Shutter sensory` have been
classified from the rig.

Unaccounted is not the same as ignored. It appears in the terminal table
with its records named and its samples measured, in a warning, in the
preflight advisories the operator reads, and in `run.stimulation_accounting`
beside the acquisition it describes. What is archived is the measurement,
not a copy of the declaration: after a run it answers which
stimulation-capable terminals existed, which were commanded, which were
neutral, what neutral value was expected, and whether that value was
actually verified in the compiled samples.

### Two compilers, deliberately

`compile_output_samples` is in the package because accounting needs to
measure at run time. `tests/compile_wfm_data_to_samples.m` is a separate
transcription of the same Luminos code, kept independent so the tests
proving AO's waveforms correct do not share an implementation with the
runtime check that also has to be correct. A test asserts the two agree on
every fixture it compiles; if either drifts from
`DAQ.Build_Waveforms_DevicePartitioned`, that is where it shows.

Both reproduce one thing that looks like a bug and is not. Luminos groups
records by the de-aliased port string *exactly*, so `/Dev2/AO0` and
`Dev2/ao0` do not combine — it resolves two channels and hands DAQmx the
same physical terminal twice. Merging them in the oracle would have
described an outcome the hardware does not produce, so both compilers
report the collision through `canonical_terminal` instead, and accounting
raises it as a violation.

### Symmetry, ordering, and the paths that neutralised nothing

Cleanup used to unwind only the modality it had been running, so a 1P run
ended with the Pockels cell and the galvos exactly as the last 2P run had
left them, and a 2P run left `mod488` untouched. The rig has one
preparation under it and both beams reach it, so
`neutralize_all_stimulation` drives every AO-owned system to its declared
value whichever modality ran, attempting each step independently and
reporting what failed — it runs during cleanup, often while an exception is
already propagating, and one absent device must neither stop the rest being
made safe nor replace the original error.

Ordering was wrong in a way an end-state assertion cannot see: the 1P
runner set the OBIS power before `mod488` was known to be dark, so for the
length of two statements the laser sat at experiment power behind a
modulator holding whatever the previous run had left on it. Neutral state
now comes first, then source power, then the waveform, then the shutter,
then arming. The simulated devices' `level`, `State` and `SetPower` became
`SetObservable` so a test can assert the order rather than the outcome.

Three paths needed their own fix. Safe state is reasserted per trial rather
than once at the top of a run, because minutes and other trials pass in
between. The 1P loop's catch darkens the modulator and closes the shutter
immediately, as the 2P loop always had. And a pre-arm failure —
one that happens before `app.acquisition_active` is ever set — reached the
one exit from the runner that neutralised nothing, because the cleanup it
called keys off that flag; it now neutralises explicitly.

`run_galvo_calibration` and `run_galvo_dynamics_characterization` called
`Waveform_Camera_Sync_Acquisition` directly, bypassing the
`execute_waveform_camera_sync` seam that makes simulation possible. They go
through it now and share the unified neutralization on cleanup. Their
scientific waveform content is untouched and they remain separate from the
production runner.

### The one change in Luminos

AO tags the records it adds with `script_owner = "adaptive_optopatch"`,
reusing `Append_Script_Waveform`'s convention rather than inventing a
parallel one, and `drop_ao_script_waveforms` takes them back out before
each build — which matters after a crash that skipped the unwind, since
`wfm_data` belongs to the DAQ and the DAQ outlives the experiment.

`Drop_Script_Waveforms` only looked at `wfm_data.do`, because every script
using the convention when it was written added digital pulse trains. AO
installs analog stimulation commands, so a `cam_acquisition_js` run calling
`Drop_Script_Waveforms(dq_session,'all')` would have left AO's Pockels and
galvo records in place — and what is left behind on an analog output is a
voltage rather than an idle line. It now covers `ao` as well, which is a
no-op for every existing caller since nothing else tags an analog entry.

### Deliberately not done

No protocol schema 4, no `events.stimulation_source`, no mixed 1P+2P
compiler or runner, no removal of the global modality selector, and the
opposite-modality guard stays exactly where it is — the new accounting
coexists with it rather than replacing it. Pass 2's configure → Update plan
→ Run lifecycle is untouched: accounting reaches the experimenter through
`preflightPlan`, which the existing validation already runs, rather than
through a status of its own.
