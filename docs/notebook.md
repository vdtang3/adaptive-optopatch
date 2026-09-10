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

A simulated rig has no sensor, so `make_simulated_luminos` gained explicit
`CameraRoi`/`CameraBin` options and the bundle-based simulated launchers adopt
the grid recorded in the bundle they replay. Simulation therefore exercises the
same invariant as hardware instead of being exempted from it.

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
