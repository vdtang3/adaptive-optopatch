# Engineering notebook

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
