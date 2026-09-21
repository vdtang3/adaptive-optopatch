# Engineering notebook

## 2026-09-17 — The illuminated footprint is drawn, not thresholded

`measure_illumination_irradiance` now segments the footprint by asking the
operator to draw it — a rectangle by default, or a polygon — and the
half-contrast contour it used before is available behind
`SegmentationMode="auto-threshold"`.

The reason is what the number is for. Irradiance is power divided by the area
the light was *meant* to cover, and a real snap of a DMD patch does not show
that area cleanly: there is a halo, the fluorescent target is uneven, and the
edge is several pixels wide. A contrast contour faithfully tracks all three, so
the area it returns moves with the target and the exposure — which makes a
power calibration that is not reproducible between sessions. A drawn rectangle
is the operator stating the footprint they projected. It is less objective and
completely reproducible, and for this measurement that is the better trade.

A polygon is the default. A rectangle is quicker to draw and a DMD patch is
usually approximately one, which is why rectangle mode came first and why it is
still there — but it is the wrong shape whenever a bounding box would enclose
dark area, and the error is not small: on a synthetic L-shaped footprint the box
inflates the area by 33% and therefore understates the irradiance by 25%. Since
that area is the denominator of the entire measurement, the default should be
the mode that can always be right rather than the one that is usually right and
quietly wrong otherwise. Rectangle mode remains for the common box-shaped patch
and for speed.

Both manual modes share one interaction (`private/draw_manual_footprint`); only
the drawing call, the instruction line and the name the geometry is recorded
under differ.

The flip has one sharp edge: a caller that passed `RectanglePosition` and named
no mode used to get rectangle mode and now gets the polygon default. That warns
and then asks for a polygon, rather than inferring the mode from whichever
geometry happens to be present. Guessing would make the mode depend on an
argument documented as optional, and a segmentation that silently changes shape
is exactly what this utility should not do.

Auto-threshold was kept rather than replaced: it needs no operator, which is
what makes it useful for a scripted sweep, and it is the right tool when the
footprint genuinely is not a rectangle.

Everything downstream is unchanged and mode-agnostic. `get_footprint_mask` is
the single place that decides how a mask is obtained; the physical area is
still `nnz(mask) * abs(det(snap.pixel_to_sample_um))` and the AOTF grouping
never learns which mode ran. Adding polygon mode touched that one function and
nothing after it, which is what the split was for.

Two smaller decisions worth recording. Options belonging to another mode warn
rather than erroring, under one identifier
(`adaptive_optopatch:UnusedSegmentationOptions`), because carrying a setting
over from a previous call is harmless and failing on it would make switching
modes tedious — but a warning rather than a printed note, since whoever passed
it probably believes it is being used. And a cancelled selection is an error,
never an empty mask: an area of zero, or a fabricated one, would propagate
silently into a published mW/mm^2.

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
## 2026-09-16 — Mixed 1P and 2P events share one acquisition timeline

Protocol schema 4 makes `stimulation_source` mandatory on every event. Source
identity is experimental intent and is never inferred from the old FOV-level
mode, masks, voltage, or live hardware. Resolution preserves one flat event
table, applies 1P and 2P voltage precedence per row, assigns DMD pattern slots
only to 1P rows, and rejects cross-source overlap and more than one distinct 2P
target per acquisition.

`build_luminos_mixed_waveform_config` partitions that one flattened schedule
and owns all six stimulation outputs for the complete acquisition. Ambient
records on those physical terminals are removed before mod488/DMD and
Pockels/galvo commands or declared neutral values are installed. The 488
shutter remains imperatively owned whenever an acquisition contains 1P. Global
VU accounting remains `report_only`; proven AO-owned-terminal violations still
block. The controller now enters execution through `run_mixed_manifest`, while
the old builders remain available for parity and commissioning tests.

The saved-FOV schema remains version 2; `stimulation_mode` is retained only as
deprecated compatibility baggage. It no longer resolves events, chooses a
runner, or participates in plan staleness, and the React selector was removed.
Simultaneous 1P+2P and multiple 2P targets remain deliberately unsupported.

## 2026-09-17 — A 1P run suppresses the inactive 2P outputs instead of holding them

A 1P-only acquisition was appending constant records for galvo X, galvo Y and
the 2P modulator, on the reasoning that an output AO owns should carry its
declared neutral rather than somebody else's waveform. For the Pockels cell,
which shares Dev1 with everything else, that cost nothing. For the galvos it
was wrong in a way no end-state assertion could see: they live on Dev2, and a
buffered record on a second card is exactly what makes Luminos build a
hardware-timed AO task there. That task then needs its sample clock and start
trigger bridged from Dev1, and a 1P-only run — which has no other reason to
touch Dev2 — failed to route it.

The fix is not in the clock routing. `Dev2/PFI0`, the clock bridge, the DAQ
master and the trigger assignments are untouched. The unwanted task disappears
because the channels that caused it are no longer inserted: `remove` with no
matching `append`. There is now a third answer to "who owns this line during
this acquisition", beside `buffered` and `imperative`:

    suppressed   this modality commands the output not at all, so it is absent
                 from wfm_data entirely - the ambient record is removed and
                 none is installed in its place

That is a statement about the buffered waveform only. The declared stationary
and dark values are still asserted, by `neutralize_all_stimulation`, through
the devices' own explicit-update API, which writes no buffered task. Nothing
about the rig's safety declaration changed; what changed is that a 1P run no
longer restates it from the acquisition buffer. This is why the manifest still
carries a `neutral_value` for a suppressed output rather than an empty one.

`account_stimulation_outputs` reads the same declaration from the other side: a
buffered record on a suppressed output is now a violation, whatever its
samples measure. A constant sitting exactly on the declared neutral is still
an output nothing asked for, and on the galvo card it is still the Dev2 task a
1P run must not create. `owner` grew an explicit `mixed` field for the three 2P
outputs, because mixed used to be answered with the 1P value and those are now
the two cases that genuinely differ — a 1P-only run suppresses them, a mixed
run drives them from the planned 2P waveforms exactly as a 2P-only run does.

### Both 1P builders, because only one of them runs

`run_1p_manifest` calls `build_luminos_mixed_waveform_config`, not
`build_luminos_1p_waveform_config`; the older builder survives for parity and
commissioning tests. So the constants had to go from the mixed builder's
`has2p == false` branch as well, and that branch — not the mixed path — is
what the NI-DAQ error was actually coming out of. `TestMixedStimulationSchema4`
asserts the two builders compile to identical samples, which is what would
have caught a fix applied to only one of them. The `has1p && has2p` path is
untouched and still installs all three sampled records.

### What a 1P run inherits, and why that is a different thing

The distinction worth keeping is between two reasons AO does not command an
output. Inactive 2P hardware is AO's own terminal that AO has nothing to say on
this run: removed, not replaced. The orange imaging chain is not AO's terminal
at all. `mod594` is how the operator sets recording power — open a Luminos
waveform configuration, include mod594, type a voltage — and AO inherits that
record byte for byte, untagged, so its own cleanup cannot take it out along
with the records it added. The contrast that matters:

    mod488   AO owns it and replaces the ambient record
    mod594   the operator owns it and AO inherits it

`shutter488` is a third case again, unchanged: removed because the runner
drives it imperatively around the armed window, and a buffered record there
would be a second runtime owner of the line.

The summary field `inactive_two_photon_outputs` keeps its name, because
archives read it, but no longer reports `galvo_stationary_v` or
`pockels_dark_v`. Those said AO drove the outputs somewhere. It reports
`disposition = "suppressed_from_run"` and the ports, which is what happened.

Runtime restoration is unchanged: `capture_original_state` still snapshots
`global_props` and `wfm_data` before the run and `restore_1p_hardware` still
puts them back, so the suppression lasts exactly as long as the acquisition and
the operator's React-tab configuration is never permanently modified.

## 2026-09-17 — Neutralization is modality-aware, and "suppressed" means untouched

Suppressing the inactive 2P outputs from the 1P waveform set closed half of
the invariant. The other half was still open: `neutralize_all_stimulation`
commanded every declared output every time, so a pure 1P run issued an
explicit galvo update and a Pockels dark-write at run start, before every
trial, and again during cleanup — for hardware the acquisition never touched.
On a rig without a Chameleon it was worse than pointless: the absent device
turned into a reported neutralization failure and a warning on every single
1P run, which is how a real safety signal gets trained out of an operator.

The symmetric behaviour was itself a fix, and the entry above it in this
notebook defends it. It was right about the hazard — a 1P run once ended with
the Pockels cell and the galvos exactly as the last 2P run had left them —
and wrong about the remedy. Commanding everything is not the only way to stop
a modality leaving the other one's hardware live; commanding what this run
actually uses, and leaving the rest strictly alone, does the same job without
reaching across the rig.

So neutralization now takes a `Modality`, and an output whose manifest
declaration says

    owner.<modality> == "suppressed"

is not commanded: no setter, no `Update_Galvos_Explicit`, and no device
lookup. The lookup matters. "Suppressed" has to mean *not touched* rather
than *resolved, then skipped*, or a rig that does not physically have the
hardware still fails trying to find it — which is exactly the symptom this
removes. The check happens before anything reaches the app, and the report
records those outputs as `suppressed` rather than as failures, so a genuine
failure is still worth reading.

### One declaration, three readers

The modality-to-field mapping moved into `manifest_runtime_owner`, because
three places now ask the same question: the waveform builders decide what to
install, `account_stimulation_outputs` decides what is a violation, and
`neutralize_all_stimulation` decides what to command. If each kept its own
copy of the mapping, the run-time safety behaviour and the check that is
supposed to police it could quietly disagree about the same output. Nothing
in the package decides for itself that an output is inactive any more.

### Scope, and what deliberately did not change

`Modality` defaults to `"all"`, which is not a rig modality and under which
nothing suppresses. That is what the unmigrated callers keep:
`run_2p_manifest` (three call sites), `run_galvo_calibration` and
`run_galvo_dynamics_characterization`. The last two actively drive the galvos,
so parking them is the whole point and must not be skipped. Only
`run_1p_manifest` was migrated, and it derives the scope from the schedule
rather than from its own name — it accepts 2P and mixed trials under
`AllowMixedSources`, and a run that will drive the galvos must still be able
to park them. Run-level steps use the run's modality, the per-trial pre-arm
uses the trial's, so a pure 1P trial inside a mixed run still touches nothing
it does not use.

Cleanup gets the same scope, including on the two failure paths. An exception
already propagating is not a licence to start commanding hardware the run
never used, and the galvos are not restored to a saved value either — that
would be a command like any other.

### Testing the call, not the end state

`TestOnePhotonModalityIsolation` asserts the calls. It has to: parking the
galvos at the stationary value they already hold, or darkening a Pockels cell
that is already dark, leaves nothing for an end-state assertion to see, so the
old tests would have passed whether or not the command was issued. The
simulated scanner counts `Update_Galvos_Explicit` calls, a listener counts
Pockels `level` writes, and the simulated app logs every `getDevice` request
so "not even looked up" is checkable.

Four tests in `TestStimulationSafetyCleanup` now assert the opposite of what
they used to, which is the honest record of a decision reversed: a pure 1P run
leaves the Pockels cell and the galvos exactly as it found them. The
missing-2P-device test flipped from "warns loudly" to "is silent", and a new
one keeps the other half honest — a missing output that the modality *does*
drive is still a reported failure, so suppression cannot be hiding errors.

## 2026-09-17 — Three core 1P protocols, and the schedule that refuses to pair spikes

The protocol library was a collection of things that had each been needed
once. It is now three experiments that share one calibration: a Blue power
ramp, a connectivity screen, and a short-term plasticity screen, all using a
10 ms pulse. That last point is the whole reason for the consolidation. The
ramp stores `selected_blue_voltage_v` per cell, and until now the screens used
5 or 20 ms pulses, so the stored number was a calibration for a pulse nobody
ran. Ten milliseconds everywhere makes the per-cell voltage mean what its name
says. Generic helpers that happen to take a pulse duration were left alone, and
2P spiral timing was not touched.

The screen is STP rather than STF because it measures facilitation **or**
depression. Which one a connection shows is the result.

### Train granularity is a scientific constraint, not a scheduling detail

The obvious way to keep ten cells busy during a 1 s recovery window is to
interleave at the pulse level: ROI1-P1, ROI2-P1, ROI1-P2, ROI2-P2. That is
rejected. It would repeat a fixed millisecond-scale pairing between the same
two stimulated neurons 300 times, which is not an artifact of the schedule but
the standard induction protocol for spike-timing-dependent plasticity. A screen
for short-term dynamics that quietly runs an LTP protocol underneath measures
something it cannot name.

So the unit of scheduling is a whole train. One cell's P1..P5 completes before
another cell's train starts, and `TestStpScreenProtocol` asserts the stronger
property directly on the frozen table: sorted by onset, every train occupies an
uninterrupted block of rows. The code models no plasticity. It only keeps the
decision where it can be checked.

Throughput survives anyway, because trains are short relative to recovery. A
default train spans 210 ms and the next different cell may start 20 ms later,
so six cells cover the 1.21 s same-cell interval and the timeline is
continuously occupied. Ten cells: 3000 trains, 15 000 events, about 690 s.

### Same-cell recovery is stated after the pulse ends

Both schedulers express recovery as time after the previous stimulation
*ended*, because that is how the experimenter reasons about it — 100 ms of dark
after a connectivity pulse, 1 s after a train's last pulse. The onset interval
(110 ms, 1.210 s) is derived and recorded in metadata rather than being the
parameter. Idle time is inserted only when no target is eligible; the recovery
rule is never shortened to keep the cadence. Five cells at 20 ms therefore idle,
and six do not, which is asserted in both directions.

### Voltage stays where it was

The connectivity generator used to hardcode `command_voltage_v = 1.0` for every
target, which silently overrode the calibration the ramp had just measured.
Both screens now emit NaN, so schema-4 1P resolution falls through to
`fov_cell`. The schedulers accept an explicit per-target override and validate
it against (0,5] V, but NaN is never converted into a number and
`resolve_protocol` keeps owning precedence — the generator does not duplicate
it.

### Where the schedulers live

`generate_constrained_round_robin_schedule` sat in `pulse-protocols/` beside its
script. Both schedulers are now package functions, because `pulse-protocols/`
holds user-facing scripts the experimenter edits and these are pure functions
the tests call directly. `create_round_robin_protocol.m` became
`create_connectivity_round_robin_protocol.m` and `create_stf_frequency_mix_protocol.m`
became `create_stp_screen_protocol.m`, both as renames so the history follows.

### Left in place

`generate_screen_protocol`, `generate_stf_protocol`, `default_stf_conditions`
and `generate_round_robin_protocol` now have no callers outside the test suite.
They are not deleted here: they still exercise the unrealized-timeline and
`each_stimulation_enabled_cell` resolution paths, which the three explicit
protocols no longer cover. Removing them is a separate decision about whether
those paths are still wanted.

## 2026-09-17 — Large-connectivity DMD correctness and preparation cost

Luminos `Patterning_Device.Dimensions` is `[width height]`, while `Target` is a
MATLAB image in `[rows columns]`. AO had constructed safety blanks directly
from `Dimensions`, transposing the 1024×768 Blue DMD canvas. Full-device blanks
now go through one helper backed by Luminos's canonical
`Pattern_Canvas_Size()` API; neutralization, post-trial cleanup, null targets,
and the inactive Blue DMD path share it.

The dominant 3400-event startup cost was `luminos_event_waveform`: every event
allocated comparisons over the complete 68 s sample vector. It now binary
searches the actual time vector for the exact half-open `[onset, offset)`
sample boundaries, then writes only that interval. This preserves sample-edge
and last-event-wins overlap semantics. On this workstation, the former loop
took 41.93 s for a 34×100, 200 kHz waveform; the replacement took 0.096 s
(435×). A complete synthetic preflight measured 2.33 s, including 0.55 s for
full stimulation accounting, so accounting remains active and uncached.

FLUT execution still uploads each unique transformed bitmap once and programs
one playlist entry per event. Capacity validation now runs in dry-run
preflight through the same calculation used by live programming. The canonical
connectivity generator represents 1000 pulses per cell as ten explicit
100-pulse chunks. Chunk `k` is independently scheduled with `base_seed+k-1`;
AO Repeat remains unchanged and should normally be one.

A physically completed acquisition is no longer relabeled failed when its
post-run DMD blank throws. The checkpoint and `output_data.mat` record
`completed_cleanup_failed` plus the cleanup error, the batch stops, safety
cleanup still runs, and resume skips the already acquired data.

## 2026-09-17 — Blue DMD static-target execution state

A single-cell 1P ramp showed broad off-target activation at low mod488
voltages while every archived AO artifact was correct: camera-space mask,
cropped-FOV remapping, planning and execution transforms, and a small
localized Blue DMD `Target`. The run had also begun with
`Could not neutralize: blue_dmd_pattern`, the transposed-blank bug fixed
separately. The question was whether a failed blank could leave the device
in a stale FLUT/slave playback state that a later static write did not
override — MATLAB believing one thing and the mirrors doing another.

Traced through Luminos: `prepare_luminos_target` calls
`setPatterningROI(..., write_when_complete=true)`, which sets `Target` and
calls `Write_Static`. `ALP_DMD.Write_Static` clears its slot/playlist
bookkeeping and then `DMD_MEX('Project_Image')` reaches
`ALP_DMD::Project`, which halts the device, frees the loaded sequence
(dropping FLUT addressing with it, since look-up addressing is a sequence
property), allocates `SeqAlloc(1,1)`, restores master mode with stepping
disabled, and starts continuous projection. **A successful static write is
therefore self-sufficient: stale FLUT/slave state cannot survive it**, and
no caller-side stop or reset is needed. The failed blank does not explain
the broad illumination.

There is a real desync window, but only on a *failed* write:
`setPatterningROI` assigns `Target` before calling `Write_Static`, and
`Write_Static` clears its bookkeeping before `Pattern_Bytes` — which is
exactly where the transposed blank threw. So a failed static write leaves
`Target` updated and the bookkeeping reset while the hardware keeps playing
the previous sequence. That is a luminos-private ordering issue, noted and
not changed here; AO's own recovery is the next successful static write.

The better-supported explanation for the symptom is `invert_output`. It is
applied only in `DMD.Device_Pattern`, on the last step out to the mirrors,
and is deliberately invisible to `Target`, the previews and everything
calibration touches. A rig entry with it wrongly set makes the mirrors show
the complement of a localized mask — a field-wide stimulus — while every
artifact AO archives stays correct, including a same-day calibration. It is
already in `Build_Archive`, but AO's `settings_snapshot` is captured before
programming and nothing surfaced or checked it.

AO now archives, after each static write,
`dmd_state_after_programming` (`read_dmd_execution_state`: the projection
and sequence inquiries `ALP_DMD::Get_State` exposes, with -1 and absent
fields both read as unavailable) and `dmd_device_mask_summary`
(`summarize_dmd_device_pattern`: `Target` counts alongside
`mirrors_on_fraction`, obtained from the device's own `Device_Pattern`).
`mirrors_on_fraction` is the single number that separates a localized
stimulus from a field-wide one, and would have settled this in minutes.

`flut_enabled` is a private C++ member and is not exposed, so FLUT-active
cannot be read directly. Master mode plus a one-picture sequence is what
the API can prove, and it is sufficient: a single-picture master sequence
cannot be a multi-entry FLUT playlist. Programming a static target now
fails with `DmdNotInStaticMode` when the device *positively* reports slave
mode or a multi-picture sequence; unavailable readback is archived as
`unproven` and never treated as a fault. The FLUT execution path is
untouched and stays in slave mode with its picture pool, as it must.

## 2026-09-17 — Draft target selection, and the checks a checkbox used to run

Selecting cells in the React tab was slow enough to discourage using it. The
cause was not one thing but a chain, and each link is worth recording because
each was individually reasonable.

### What a checkbox actually cost

Every eligibility edit was a round trip. `set_cell_eligibility` reached
`setCellEligibility`, which called `invalidateCellSummary` — and the cell
summary is `summarize_soma_geometry`, which rasterises every soma over the
whole reference image and computes their pairwise overlap. Eligibility lives
in `CellState` and changes no polygon, so that cache never needed discarding;
the next `cellRows()` rebuilt the masks anyway, and the reply's own
`getState()` is that next read. `setCellBlueVoltage`, `setCellCalibration` and
`applyCellState` had the same mistake.

`getState()` then asked for the same derived answers repeatedly.
`planStatus`, `planReadiness` and `legalActions` each computed `planStatus`,
and each of those computed `stalePlanInputs` → `executionInputs`, which
rebuilds the execution-input struct — polygons, cell decisions, the whole
protocol definition — and deep-compares it with the prepared plan. That ran
three times per snapshot. `planSummary`, which walks every manifest trial's
pulse schedule, ran twice: once for itself and once inside `runProgress`.

In the browser, `useAdaptiveOptopatchSession`'s `waveformKey` included every
cell's `stimulation_enabled`, so a checkbox re-fetched the waveform preview —
a manifest rebuild and a sample-vector synthesis, and the most expensive read
the tab has. And `busy` disabled the whole cell table while any action was in
flight, so against a single-threaded MATLAB the clicks serialised behind all
of the above.

### The fix, and the design commitment it revises

The tab was written to hold no session state of its own, and that remains
right for drawing a soma or loading a protocol: one deliberate act whose
result the operator waits to see. It is wrong for picking targets, which is a
dozen clicks in a few seconds with nothing to wait for. `draftConfiguration.ts`
now holds the cell decisions and the editable plan parameters locally, and
`Update plan` sends them and then compiles.

The exception is bounded so the original guarantee survives. A draft holds
only values that DIFFER from the snapshot, so an empty draft means the browser
and the controller agree exactly, and toggling a box twice leaves nothing to
send. Nothing is ever run from a draft: `run` is still refused unless a
prepared plan matches the controller's own inputs, and a draft is not part of
those. Everything describing the applied plan — the summary, the readiness
message, the stale-input list — is still rendered from the snapshot and moves
only when Update plan is pressed.

The cost of the divergence is real and is the reason it is written down: while
a draft is unsent, the MATLAB planning window's cell table disagrees with the
browser. The tab says so, with an unapplied-edit count and a discard control,
rather than hiding it.

### set_cell_eligibility_batch

Flushing a draft one cell at a time would bump the revision once per cell and
make each request stale for the next, so the whole selection goes as one
action under one revision. It is applied all-or-nothing: a batch naming a cell
that does not exist changes nothing, because a half-applied selection is the
one state an operator can neither see nor undo. It can express nothing a
sequence of single edits could not, which is asserted directly.

### Counting rasterisations rather than comparing caches

`aDecisionEditDoesNotRerasteriseTheSomaMasks` counts, because it has to. A
rebuilt cache holds exactly the numbers the discarded one did, and the reply
to every action reads the state afterwards and so re-warms whatever was thrown
away — an equality check would have passed either way. `CellSummaryComputations`
makes "this edit did not rebuild the masks" a checkable property instead of a
probable one.

### The waveform preview follows the applied plan

Its fetch key is now the prepared run, the loaded protocol and the reference,
not the editable state. A preview that re-synthesised on every checkbox was
describing something nobody had asked for yet; it now holds still until the
draft is applied, and Refresh is there for the operator who wants it sooner.

### Frontend tests exist now

`luminos-private/src/User_Interface/frontend` had no JS test tooling. Vitest,
jsdom and Testing Library are devDependencies there, `npm test` runs them, and
the Vite build reads none of it. That is a deliberate exception to keeping AO
tooling out of shared Luminos: what these tests assert — that editing makes
zero backend calls and Update plan makes exactly one compile — cannot be
checked from this repository, because the components are there.

## 2026-09-17 — Two state owners, named: React drafts, MATLAB commits

The previous entry introduced draft target selection and explained it as a
performance fix. That was the honest reason it was written, but it is not the
right way to record it, because the shape it produced is an architectural
decision and needs to be defensible on its own terms. It is this:

> **React owns uncommitted user intent. MATLAB owns committed state and
> execution truth.**

Three things, and they are named apart in the code so they cannot be confused
for one another:

- **controllerState** — the authoritative snapshot MATLAB last sent. Committed
  configuration, prepared plan, audit results, cell identity, QC. React renders
  it and never writes to it.
- **draftOverrides** — what the experimenter has changed and not yet committed.
  Sparse, local, free to modify: no MATLAB call, no compile, no audit, no
  hardware check, no waveform synthesis.
- **appliedPlan** — the executable plan MATLAB compiled, archived and audited,
  derived only from committed state. The only plan Run may use, and it cannot
  see an override because no override has reached MATLAB.

What is on screen is `controllerState + draftOverrides`, computed by
`effectiveCells` and `effectivePlanParameters`. It is a view. Nothing stores
it, and that is what keeps React from becoming a second source of truth.

### Why sparse is load-bearing

An override that equals the committed value is removed rather than recorded.
That single rule gives everything else: an empty draft means the two agree
exactly; toggling a checkbox twice leaves nothing to commit; an edit made in
the MATLAB planning window that happens to agree with the draft silently stops
being a difference; and the work a commit does is bounded by what actually
changed rather than by how much clicking happened. A draft that stored absolute
values instead of differences would have none of those properties and would
need a conflict-resolution policy, which is the thing worth not having.

### Update plan is the commit boundary, and it is atomic

The previous pass left a real partial-commit window. Flushing a draft sent one
`set_plan_parameter` per value, then a batch of cell decisions, then
`update_plan`. Parameter A could commit, B could commit, C could be refused,
and no compile would ever happen — leaving the controller holding a
configuration the experimenter never asked for and never saw, and no prepared
plan describing it. The experimenter pressed one button; MATLAB kept part of
what it meant.

`apply_plan_draft` replaces that sequence with one action. The controller
validates the entire delta before mutating anything, applies it, compiles,
audits, and on any failure restores the commit point it started from —
`CellState`, `PlanParameters`, the prepared-plan fields, and the revision.

Restoring the **revision** is the part worth explaining. It looks like hiding a
change and is the opposite: `Revision` means "what `getState()` would return
has changed", and after a rollback it has not. Keeping it also makes retry
work, which is the behaviour the model needs — a refused draft is still a valid
delta against the revision it was built on, so the experimenter can fix it and
send it again rather than being told their correction is stale for a change the
controller never kept. `notifyStateChanged` exists so the MATLAB planning
window, which painted the intermediate state, still gets told to repaint
without the revision moving.

`set_cell_eligibility_batch`, added one pass ago for the flush, was removed as
an endpoint: `apply_plan_draft` subsumes its only caller, and two ways to
commit a selection is one too many. The controller method survives as
`applyPlanDraft`'s, which is where the all-or-nothing cell validation lives.

`draftConfiguration.ts`, named in the previous entry, is now `planDraft.ts`,
and its vocabulary changed with it - `DraftOverrides`, `effectiveCells`,
`planDraftPayload`, `committed*` - so that the three owners above are
distinguishable at every call site rather than all being called "the draft".

### The residual failure window, stated

Rollback cannot unwrite a file. `saveExecutionBatch` runs only after the audit
has passed, so a refused plan writes nothing; a write that fails part way
leaves a run folder that nothing points at, and the next successful Update plan
allocates the next number rather than reusing it. Closing that would mean
deleting run artifacts on an error path, which is a worse thing to get wrong
than leaving an orphaned folder. It is documented in `applyPlanDraft` and left
open deliberately.

A second, smaller one: another frontend that polls mid-commit can observe an
intermediate revision that the rollback then withdraws. Its next action is
refused as stale and it is handed the true state — a refusal, not corruption.

### What Run means, said out loud

The Run panel now has two named states — "Plan up to date" and "Unapplied
changes (n)" — and the second says explicitly that running would use the
applied plan, not the ticked checkboxes. Run is deliberately **not** disabled
by the presence of a draft: Run means "execute what is prepared", and what is
prepared has not changed. Disabling it would imply the draft had made the
prepared plan unsafe, which is exactly the confusion this is trying to remove.

The waveform preview is labelled "Applied waveform preview" for the same
reason. It is synthesised by MATLAB from committed state, so an uncommitted
checkbox is not in it and could not be. A preview of what an *uncommitted*
draft would command is deliberately absent: it would mean resolving a protocol
against state MATLAB does not hold, which is a second resolution path for the
one question this tab exists to answer honestly.

## 2026-09-18 — What reaches the mirrors, as distinct from what AO programmed

The state model of the previous entry is about intent: React holds
uncommitted intent, MATLAB holds committed state, Update plan is the commit
boundary, and Run executes only the prepared plan. None of it is touched
here. This entry is about the step after all of that — whether the DMD
pattern the acquisition actually runs on is the one the applied plan
describes.

It was not guaranteed, in three independent ways. Each of them leaves every
artifact AO archives correct, which is why they were invisible: the plan, the
manifest, the camera masks, the transform matrices, the read-back DMD state
and the camera-space preview were all right in each case.

### 1. The stale generic stack

AO programs `DMD_Blue` — a static target, or a bank of unique masks with a
FLUT playlist over it — and the `DMD_Orange` recording mask, verifies both,
and then calls `Waveform_Camera_Sync_Acquisition`. That script reloads each
DMD's retained `pattern_stack` for every DMD whose `auto_write_stack` is set.
That happens after AO has finished and before the first trigger.

This is the one that explains the shape of the symptom. A standalone DMD or
FLUT diagnostic passes, because it never goes through acquisition startup; a
real acquisition with the same code does not.

AO now takes exclusive ownership of the Blue and Orange DMDs for the length
of a run (`claim_dmd_pattern_ownership`, released in the runners' guaranteed
cleanup). Ownership is Luminos's own mechanism, added there rather than here:
the autoload is Luminos's and the DMD tab's stack is Luminos's, so the guard
belongs beside them. **Nothing is deleted.** The operator's `pattern_stack`
survives the run untouched and is written again the next time a generic
acquisition asks for it; what the claim suspends is the autoload, for this
run, and the `auto_write_stack` value is restored on success, on error and on
Ctrl-C.

The invariant AO now asserts is not "the write succeeded" — it already knew
that, and it was true in the failing case — but "the device is still
projecting what AO programmed at the moment the acquisition is triggered".
`record_owned_dmd_pattern` takes a fingerprint after programming and Luminos
checks it immediately before `Start_Tasks`, after every startup hook that
could have touched a DMD.

The regression tests run Luminos's own `Write_Pending_Dmd_Stacks` and
`Verify_Owned_Dmd_Patterns`, reached through the simulated backend, rather
than an AO-side reimplementation of the same sequence. That is the whole
point: a reimplementation would have kept agreeing with itself while the real
startup overwrote the target. `SimulatedLuminosApp.simulateAcquisition` calls
both, at the same two moments the real script does.

### 2. The wrong camera's calibration

Luminos holds one camera-to-DMD calibration per device/camera pair, but
projection goes through one active transform. `use_calibration_camera`
changes the selected camera and leaves that transform alone when the newly
selected pair has no stored entry. So the AO reference can belong to camera A
while the DMD projects through camera B's calibration.

None of the things that look like evidence are evidence. The transform is
nonidentity; its dimensions, the reference origin and the binning all still
match, so `validate_dmd_reference_geometry` passes; and the preview is drawn
in camera coordinates, before the transform is applied, so it looks correct.
The dropdown says what was selected, which is not the same as what is loaded.

`validate_dmd_calibration_identity` asks Luminos's new
`Patterning_Device.calibration_identity` for the only record that ties a
transform to a camera — the per-pair store — and requires that the transform
now loaded *is* that pair's, for the camera the plan's reference image was
taken with. It fails closed and names the calibration to run, because AO
cannot tell a missing calibration from a wrong one by looking at the
projection and the experimenter can. Blue and Orange are validated
independently; they are separate devices with separate stores, and a
recording mask through the wrong transform mislabels which cells were
recorded exactly as a stimulation mask through the wrong transform
mistargets them.

Deliberately not done: restoring the planning-time transform to make the
check pass. The live Luminos calibration stays authoritative, as
`capture_1p_dmd_calibration` has always said; the planning snapshot remains
provenance only.

The cost is that a reference bundle that does not record its camera's name is
now refused. That is the honest outcome — such a bundle cannot be attributed
to a calibration at all — and the message says to plan again from a current
Snap.

### 3. The projective crop-origin shortcut

Fixed in Luminos; see its notebook for the algebra. It matters here because
AO is the reason the cropped-FOV path exists: AO plans on a sub-ROI snap and
projects through a full-field DMD calibration, which is precisely the case
where the reference origin is nonzero. For an affine calibration the old code
was exactly right; for a projective one it was a different transform, by over
a hundred device pixels at a realistic crop offset.

### What is still unproven in software

Ownership and the fingerprint are statements about MATLAB-side state and the
programming calls that reach the controller. That the ALP then holds what it
was sent, that the mirrors follow the trigger line, and that the optical path
matches the calibration are hardware facts, and no test here can establish
them. `read_dmd_execution_state` remains the positive hardware readback, and
remains advisory.

## 2026-09-18 — The test suite, reorganised around owners and tiers

Nothing about the system changed here. What changed is that the tests now say
who owns what, and that running them after an ordinary edit costs eighty
seconds instead of four and a half minutes.

### The catch-all is gone

`TestAdaptiveOptopatch.m` was 2226 lines and 86 tests, and had been the place
a test went when the suite that should own it did not exist yet. It spanned
galvo calibration, spiral geometry, protocol generators, camera cadence,
snapshot ingest, connectivity inference, the Luminos waveform builders, the
frozen-run lifecycle and the manifest runners. Reading it told you nothing
about which of those a change might break.

It is now ten focused suites plus fourteen tests moved to suites that already
owned the behaviour. Exactly **one** test was deleted:
`onePhotonConfigSuppressesOnlyTwoPhotonStimulation`, because
`TestOnePhotonOutputSuppression` asserts the same thing per output, and does
it through **both** builders rather than one. One more was split, its unique
half kept.

The rule applied throughout, and worth restating because it is the one that
keeps this suite useful: **two tests that reach the same conclusion through
different layers are not duplicates.** Waveform construction, runtime
ownership, independent accounting and failure cleanup all end up saying "the
galvo card was not driven", and all four stay, because each fails for a
different reason. The same holds for camera-space mask construction, DMD
programming, acquisition-time DMD state and calibration identity.

### Suites named for behaviour, not for chronology or schema version

`TestProtocolSchema3` became `TestProtocolResolution`: the tests were never
about schema 3, they were about precedence and target policy, and schema 4
did not touch one of them. `TestMixedStimulationSchema4` became
`TestMixedStimulationTimeline` for the same reason. Explicit refusals of
retired schemas stay, and now say which schema they refuse.

`TestRigCommissioningFixes` was a bag of five unrelated regressions held
together by the week they were found in. Each moved to the suite that owns
the behaviour and the file is gone. The history is in git, where chronology
belongs; the test layout should describe the architecture, not the calendar.

### Two merges, and what was not merged

`TestAdaptiveOptopatchSnapshotChoices` folded into
`TestAdaptiveOptopatchReferenceChooser`. The chooser already listed both
camera snapshots and saved FOVs, so eight tests were genuinely the same
assertions against the narrower listing. Thirteen were not — crop and bin
metadata, the wrong-camera refusal, the unreadable-file listing, the
`reference_revision` bump, the empty-folder case — and those moved. The
`load_snapshot_choice` endpoint is still allowlisted, so the properties that
matter to it (opaque ids, only offered files reachable, stale revision
refuses, malformed entries fail without disturbing the FOV) are now asserted
against **both** endpoints in one place rather than against one each.

`TestPreviewMatchesExecution` folded into what is now
`TestAdaptiveOptopatchPreviews`. This one deserves care, because the two were
not redundant: the endpoint tests say the preview is inert, revisioned and
JSON-safe, and the execution-agreement tests say it is *true* — that the mask
drawn is the mask `build_dmd_sequence_plan` will project, and the spiral drawn
is the one `apply_acquisition_parameters` resolves. An endpoint can be
perfectly inert and perfectly wrong. Both groups survive, in one file, under
headings that say which is which.

The Blue-voltage tests came out of that file into
`TestBlueVoltageCalibration`. They were never previews; they are the claim
that a stored 488 nm calibration can never become a command, which is a
different thing to be sure of.

### Tiers

`run_tests` takes a tier. `core` is the gate for ordinary work and is
deliberately the tier that holds the safety suites — DMD ownership,
calibration identity, waveform ownership, suppression, isolation, accounting,
cleanup — because those are the failures that cost a rig. `extended` is
simulated acquisitions and the slower science. `legacy` is the MATLAB
planning window, which is still supported and still green, but which React
work should not wait on. `performance` is separate so that a slow machine
never reads as a broken waveform.

The manifest lives in one commented block in `run_tests.m` and
`run_tests` **errors** if a suite under `tests/` is in no tier. A tier scheme
that silently drops new suites is worse than no tier scheme.

### Where the time went

Two fixtures dominated, and neither needed to.

`TestAdaptiveOptopatchReferenceChooser` paused 1.1 s per test so two snapshot
files would have distinguishable modification times. Only one test reads the
listing by position; the rest select by `choice_id`. The pause now belongs to
that one test, and the suite went from 31 s to 3 s with the same assertions.

In the React tests, jsdom implements no layout, so `offsetParent` is always
null, so the session hook believed the tab was off screen and polled every
five seconds instead of every one. The re-base test waited three seconds for
a snapshot that could not arrive, swallowed the timeout with `.catch()`, and
accepted either revision. It was asserting nothing. Giving an attached
element its parent as `offsetParent` — which is what a browser does — makes
the rendered suite exercise the foreground poll, and that test now asserts
the commit carries revision 9 and takes one second.

Neither of those weakened an assertion. Both made one real that was not.

### The React split was already right

The stated worry was rendered tests that merely repeat a pure helper
assertion. There are none. Every one of the twenty-two rendered tests asserts
something only the component can answer — a disabled checkbox, a visible
message, a button's enabled state, or the number of calls that crossed the
backend boundary — and the twenty-four pure tests are all model-level. The
`fake_ao_session` tests stay as they are: their duplication of MATLAB
behaviour is the point, because the development backend has to obey the same
contract as the real one.

## 2026-09-18 — Which field of view the browser is looking at

The previous two entries are about what reaches the mirrors and about how the
tests are organised. This one is about a class of failure one level up, in
which every value crossing the wire is current and correct and the
experimenter's intent still ends up attached to the wrong neurons.

Three of them, sharing one cause: **a cell ID means nothing without a field of
view, and neither does a picture.**

### The stale object was the image

`legal_actions.edit_cells` says whether the controller will accept a geometry
edit. It stays true across a reference change, because editing cells in the
new FOV is perfectly legal. The React canvas gated drawing on it alone, and
the reference image was replaced only when a new one had been fetched and
decoded — so between the poll that adopted FOV B and the arrival of B's
picture, the tab displayed A's pixels, in B's state, with the tools live. A
polygon drawn there carried B's current revision, so nothing refused it.

Ordinary stale-revision checking cannot see this. The revision the action
carries *is* current. What is stale is the thing the operator was looking at,
and the browser had no way to say which reference that was, because a flat
list of uint8 does not say.

The fix has two halves and both are necessary.

**MATLAB attributes the pixels.** The request now names the
`fov.reference_revision` it is about and `referenceDisplayImageFor` answers
only if that is still the loaded one; otherwise it returns empty. Identity
travels on the request rather than the reply because `JS_Server` frames one
binary array and not a struct containing one — see Luminos's notebook. This is
what makes two same-sized fields of view distinguishable at all: nothing else
about the payload differs.

**React derives the displayed image rather than storing it.** `image` is the
decoded picture only while its stamped identity equals the controller's
current one, so a snapshot carrying a new `reference_revision` invalidates the
old picture in the same render that adopts it — not in an effect afterwards,
and not once a replacement has arrived. There is no frame in which A's pixels
are on screen under B's state. Geometry editing is then
`edit_cells && imageStatus === "ready"`, one predicate with one reader, so the
buttons and the pointer handlers cannot disagree.

A failed or mismatched load is the same state as a pending one as far as
editing goes: no picture of this reference, nothing editable, and the previous
FOV is *not* shown. Falling back to the last good image would recreate the bug
and look like success.

### A gesture belongs to the picture it was started on

A disabled button is not enough once a drag has begun. Both in-flight
interactions — a polygon being drawn and a vertex being dragged — are now
stamped with the reference they began under, cancelled by a lifecycle effect
when the identity changes, and refused at the commit if their stamp is not
current. Two layers on purpose: the effect handles the ordinary case, the
guard handles a `pointerup` whose handler runs against a render that has
already moved on.

### A draft belongs to a FOV, not just to a revision

The same mistake, in the sparse-draft model. React's uncommitted overrides are
keyed by `cell_id`, and `reconcileDraft` re-based them onto every new
snapshot. Within one FOV that is exactly right and is the reason editing is
free. Across FOVs it is not, because cell IDs are local:

    FOV A:  draft stimulation_enabled(cell_001) = true
    load FOV B, whose own cell_001 is committed false
    re-base: the override survives, now against B's revision
    Update plan: B's cell_001 is enabled

The backend does nothing wrong; the browser silently moved a decision between
two biological cells. So a draft now records `baseReferenceRevision` as well
as `baseRevision`, and reconciliation has two cases: same FOV and a newer
revision re-bases as before, a different FOV discards.

**It is driven by the controller's identity, not by the Load button.** The
reference can be replaced by the MATLAB planning window or by another browser,
and a poll noticing that has to have exactly the same effect. The clearing
therefore happens in the reconcile effect, which runs on every snapshot, and
the Load handler's own cleanup is now merely an earlier copy of it.

### What is *not* cleared, and why

Clearing every draft field on a FOV change would be the easy answer and the
wrong one. The proven bug is that FOV-dependent decisions transfer between
biological cells; a scanner velocity limit is not one of those, and throwing
away a deliberately set session parameter every time the experimenter changes
field is a second, quieter way of losing intent.

The line is drawn where MATLAB already draws it.
`applyFovPlanParameters` is the method a saved FOV's load runs, and the six
parameters it restates from the bundle — stimulation mode, microns per pixel,
spiral radius and density, Orange expansion, Blue mask adjustment — are
exactly the ones whose drafts cannot survive the load, because the new
reference has just stated its own values for them. The other five are
session-level and their drafts are carried across. The two lists are named in
both languages and each comment points at the other; nothing enforces the
correspondence across the boundary.

Per-cell Blue voltage is not in the draft model at all — it is a stored
calibration written through `set_cell_blue_voltage` immediately, because
MATLAB validates it and the table has to show the value it accepted. So there
is nothing for a FOV change to do about it, and a test says so rather than
leaving the absence to be rediscovered.

### The Orange programmed mask, which was a scalar

Unrelated to the above except in being about provenance rather than about what
executed. AO archived Orange's `device_mask` as the return value of

    dmd.setPatterningROI(mask, "write_when_complete", true)

and `Patterning_Device` returns the warped mask only when asked *not* to
write. Once it has written, the mask is in `Target` and the return value is
the scalar 1. So `device_mask` was `true`: the one field whose job is to say
what Orange received could say nothing at all.

Nothing about the illumination was affected and nothing reads the field, which
is why it stood. It is still worth fixing, because a provenance field that
silently holds a scalar is worse than a missing one — it looks answered. The
contract is preserved rather than replaced: `device_mask` is the real logical
device-space mask, read back from `dmd.Target > .5` after the write, which is
the same property and the same threshold Blue's
`summarize_dmd_device_pattern` uses. A `device_mask_summary` is recorded
beside it so the two devices' archives mean the same thing.

Blue never had the bug — `prepare_luminos_target` already discards the return
value and reads `Target` back — and the comment there says why, which is how
the Orange call was found.

**Why no test caught it.** `SimulatedLuminosDevice.setPatterningROI` returned
the mask whether or not it had written, so the simulator and the caller agreed
with each other and both disagreed with the rig. The simulator now reproduces
`Patterning_Device`'s actual return contract, and a test pins it. That is the
general lesson and not a local one: a test double that is more forgiving than
the device is a test that cannot fail.

### The primitive the Reset feature will reuse

`advanceReferenceIdentity` is now the single place `ReferenceRevision` moves,
reached from `adoptReference` and `setFovState`. It was two inline increments
before, which is the same behaviour and a worse statement: the invariant that
matters is that a reference identity changes exactly when the pixels under the
somata are replaced, and that is now written down in one place with the
reasoning next to it.

The planned New FOV / Reset AO Session operation is the third caller. It needs
"invalidate the current reference" to mean the same thing to every frontend
that a snapshot load already means, and after this pass it does: React clears
FOV-scoped drafts, cancels interactions, drops the selection and the overlay,
and refuses to edit against a picture it has not been given, all driven by
that one number. What Reset still has to decide is what happens to the applied
plan and to the committed cells — deliberately not touched here.

## 2026-09-18 — The boundary between one field of view and the next

The previous entry ends by naming `advanceReferenceIdentity` as the primitive
the Reset feature would reuse, and says what Reset still had to decide: what
happens to the applied plan and to the committed cells. This entry is that
decision, and one thing the entry did not anticipate.

### What the operation is for

With the MATLAB-only planning window an experimenter closed Adaptive Optopatch
and reopened it between fields of view. The useful property of that habit was
never that it restarted anything — nothing about the rig needed restarting. It
was that each new field began from a clean **experiment-specific** state. The
React integration keeps one controller alive for the length of a Luminos
session, so the habit stopped working and nothing replaced it.

So the operation is `startNewFov`, and its name is the whole of its scope. It
is not a reset, because a reset is a thing you do to a machine; this is a thing
you do to an experiment. The button says **New FOV** for the same reason.

### One primitive, three callers

The important part is not the new method. It is that there were already two
ways to replace a field of view — `adoptReference` for a camera snapshot,
`setFovState` for a restored bundle — and they were two inline sequences that
agreed about most things and not about all of them. In particular the prepared
plan survived a reference change, because `markEditableChanged` keeps a frozen
plan alive once one has been archived.

That rule is right for what it was written for. An edit made after freezing
applies to a future run, and the archived plan is still a true description of
something. Replacing the field of view is not that: the plan's targets are
somata that are gone, so it is not a description of anything the session can
still do. It stayed because nothing had ever asked the question in a form where
the answer mattered — `planStatus` already reported `update_required` once the
`reference` input group went stale, so Run was refused either way and the only
visible consequence was that `active_run` went on naming a run belonging to a
field of view the session no longer had.

`clearFovOwnedState` is now the one place FOV-owned state is dropped and the
three transitions all go through it. That is what makes "New FOV" and "load
another reference" impossible to drift apart, which was the real risk: a
separate React-only reset path would have been a second answer to the same
question, and the second answer is always the one that stops being maintained.

The list in that method is deliberately written out with a reason per entry
rather than expressed as "everything except a keep-list". Both forms are the
same set today; only one of them stays correct when somebody adds a property.

### What survives, and the two decisions that were not obvious

**The loaded protocol survives.** A pulse protocol is a reusable experimental
definition and names no cell — `validate_protocol` never sees a FOV, and
`summarize_protocol` is a pure function of the definition. What depends on the
cells is its *resolution* against them, and every resolved artifact
(`resolved_protocols`, the target bundle, the manifest, the schedule) lives
inside the prepared plan and goes with it. Preserving the definition is
therefore not preserving anything about the old field, and it makes "same
protocol, next field" one step rather than two. An experimenter running an STP
screen across eight fields would otherwise reselect the same file eight times,
which is the kind of friction that ends with the protocol being reselected
wrongly once.

**Every plan parameter survives**, including the six that
`applyFovPlanParameters` calls FOV-scoped. That sounds inconsistent with the
previous entry and is not, because the six are FOV-scoped in a precise sense:
they are the parameters a saved bundle *restates for itself*, so an uncommitted
override of one must not survive a load that has just said what its value is. A
new FOV states nothing — it is the absence of a field of view — so there is
nothing for a value to countermand, and discarding a deliberately set spiral
radius or mask adjustment would be the quieter way of losing intent that the
previous entry warned about. Loading a fresh camera snapshot already keeps all
eighteen; New FOV is the same transition with no picture at the end of it.

The React draft is a separate matter and is unchanged: `reconcileDraft`
discards the FOV-scoped half on any reference-identity change, and New FOV
moves that identity like any other replacement. Committed values persist,
uncommitted overrides of those six do not. Both halves of that are now tested
from both sides.

### No hardware is written

Adaptive Optopatch owns a DMD pattern only for the length of a run:
`run_1p_manifest` claims ownership, blanks Blue in its cleanup and releases the
claim on success, on error and on Ctrl-C. An idle session is therefore already
not emitting, and there is nothing for a lifecycle operation that happens
entirely in MATLAB memory to make safe. Adding a neutralisation write to Reset
would have been a device command issued for a state change no device
participated in — and, worse, would have made the idle-state guarantee look
conditional on somebody remembering to call it.

`TestNewFovLifecycle` asserts this by counting `getDevice` lookups rather than
by arguing it: after the reset the simulated app's lookup log is empty, so "did
not write" and "did not even look" are distinguishable. The operator's own
`pattern_stack`, `auto_write_stack` and both DMDs' `Target` are checked
unchanged beside it.

### The waveform trace was the second stale object

This one was not in the handoff's list and is the same bug as the stale
reference image, one panel over.

The reference image is *derived*: it is the decoded picture only while its
stamped identity equals the controller's current one, so a new
`reference_revision` invalidates it in the render that adopts it. The waveform
preview was *stored*. Its fetch is keyed on `fov.reference_revision`, so a
replacement was always on its way — but until it landed, the trace on screen
was the previous field of view's commands drawn under the new field's state,
which is exactly what an empty state must not show.

It is now derived on the same terms, and the request records which field of
view it was issued about so a reply that lands after the reference has moved is
dropped rather than attributed. Deliberately keyed on the reference identity
and **not** on `revision`: dropping the trace whenever anything at all changed
is what the previous pass removed, because re-synthesising sample vectors
behind a checkbox was the most expensive thing routine editing did.

The test for it holds the replacement fetch open, because a test that let the
refetch land would pass with or without the fix.

### Confirmation

Asked only when there is something to lose — a loaded reference or an
uncommitted draft — and never on an empty session. A confirmation in front of a
routine step stops being read, and changing field is routine. The second half
of the message does as much work as the first: an experimenter who believes New
FOV might cost them a calibration will avoid it and keep restarting Luminos,
which is the habit the whole operation exists to replace, so the dialog says in
as many words that the rig and everything already saved are untouched.
