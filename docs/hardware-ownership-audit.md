# Hardware ownership audit — normal 1P voltage imaging on the Virtual Upright

Audit only. No behaviour changed. Written against AO
`vdtang3/blanket-depolarization` @ `81f8310` and Luminos
`vdtang3/blanket-depolarization` @ `a803fdbd6`.

This traces what a normal 1P Adaptive Optopatch acquisition actually depends on
today, before the ownership model is changed. Section 11 lists the places where
the change request's stated premises do not match the code; those are the ones
worth reading first.

---

## 1. The live path

`AdaptiveOptopatchController.applyPlanDraft` → `updatePlan` → `freezeRun` →
`preflightPlan` → `run_manifest` → `run_1p_manifest`.

```
run_1p_manifest
  resolve_luminos_1p_hardware(app, profile)         <- HARD GATE on Waveforms
  capture_original_state(hardware)                   <- global_props, wfm_data,
                                                        camera frames, OBIS W
  claim_dmd_pattern_ownership([DMD_Blue, DMD_Orange])
  neutralize_all_stimulation("1p run start")
  per trial:
    preflight_trial
    prepare_luminos_dmd_sequence | prepare_luminos_target
    prepare_luminos_orange_mask                      <- DMD_Orange spatial only
    build_luminos_mixed_waveform_config(original.global_props, original.wfm_data, ...)
    account_stimulation_outputs                      <- candidate, pre-install
    neutralize_all_stimulation("pre-arm")
    hardware.daq.global_props = globalProps           <- MUTATES the live DAQ
    hardware.daq.wfm_data     = wfmData
    set_camera_frames_for_duration(hardware.cameras, total_time)
    hardware.shutter.State = open                     <- imperative, 488 only
    execute_waveform_camera_sync -> Waveform_Camera_Sync_Acquisition
  onCleanup: restore_1p_hardware
```

### 1.1 `build_luminos_1p_waveform_config` is not on the live path

It is called **only from tests** (`TestLuminosWaveformConfiguration`,
`TestWaveformOwnershipRegressions`, `TestFrozenExecutionInvariants`,
`TestOnePhotonOutputSuppression`, `TestDmdFlutExecution`,
`TestStimulationAccounting`, `TestConstrainedRoundRobinProtocol`,
`TestStpScreenProtocol`, `TestMixedStimulationTimeline`,
`TestBlanketDepolarization`). It refuses blanket plans outright
(`build_luminos_1p_waveform_config.m:14-20`).

`run_1p_manifest.m:299`, `run_2p_manifest.m:207`,
`AdaptiveOptopatchController.m:1858` and `tools/benchmark_connectivity_preflight.m`
all call **`build_luminos_mixed_waveform_config`**. It is the only builder that
reaches hardware.

Consequence: the error message quoted in the change request —

> "Load a Luminos waveform protocol containing rate, clock, trigger, and
> DAQ-master settings."

is `build_luminos_1p_waveform_config.m:23-24`, which an experimenter can never
hit. The one they do hit is in §1.2.

### 1.2 The real Waveforms gate

`resolve_luminos_1p_hardware.m:99-103`:

```matlab
if ~isstruct(hardware.daq.global_props) || isempty(fieldnames(hardware.daq.global_props)) || ...
        ~isstruct(hardware.daq.wfm_data)
    error("adaptive_optopatch:NoActiveLuminosWaveform", ...
        "Load an active Luminos waveform protocol before starting the runner.");
end
```

`DAQ.global_props` is an unset `SetObservable` property (`DAQ.m:86`). The DAQ
constructor (`DAQ.m:152-176`) never initialises it — it sets `alias_list`,
`DAQ_Master = true` and `rate = Default_Rate_Or(...)` and nothing else. It is
first populated by `load_waveform_from_json` (`DAQ.m:2864-2913`), i.e. by the
Waveforms tab. So on a fresh Luminos, `global_props` is `[]`, `fieldnames` is
empty, and AO stops here — before any device is touched.

This single check is the whole "open Waveforms first" dependency. Everything
downstream that reads `global_props` is reading a struct AO itself just copied
and overwrote.

There are then four further gates, all also fed from `global_props`:

| Check | Where | Reads |
| --- | --- | --- |
| rate positive and finite | `resolve_luminos_1p_hardware.m:105-110` | `global_props.rate` |
| start triggers match profile | `:111-116` | `daq.default_trigger` |
| clock bridge matches profile | `:117-122` | `daq.clock_bridge` |
| self-trigger selected | `:123-126` | `global_props.daq_master` |
| clock master supported | `:127-132` | `global_props.clock_source` |

The last three come through `capture_luminos_daq_sync`, which is **read-only by
design** (`capture_luminos_daq_sync.m:1-5`) and derives
`selected_master_device` by regex from `clock_source` (`:136-144`).

### 1.3 What AO already overwrites in `global_props`

`build_luminos_mixed_waveform_config.m:59-60`:

```matlab
globalProps = activeGlobalProps;
globalProps.total_time = duration;
if ~isfield(globalProps,"completion_trigger"), globalProps.completion_trigger="None"; end
```

So AO already owns `total_time` and `completion_trigger`, and **inherits
verbatim** `rate`, `clock_source`, `trigger_source`, `daq_master` and anything
else the tab left there. `:26-30` requires those four fields to exist.

This is the whole DAQ inheritance. There is nothing else.

### 1.4 Camera dependency

`set_camera_frames_for_duration.m:31-54`, for every camera:

```matlab
source  = camera.frametrigger_source;
isDaq   = contains(upper(source),"DAQ");
periodMs = camera.daqtrig_period_ms;         % errors if absent/non-positive
frameRate = 1000/periodMs;
camera.frames_requested = ceil(durationS*frameRate);
```

and if the camera is **not** DAQ-triggered it falls back to `camera.AutoN(duration)`
(`:55-70`) — a free-running acquisition, silently, with `frame_rate_hz = NaN`.

`daq_camera_frame_period_s.m` returns `NaN` for anything not DAQ-triggered, and
that `NaN` feeds `build_dmd_sequence_plan`'s `CameraFramePeriodS` at
`run_1p_manifest.m:269-270` and `AdaptiveOptopatchController.m:1839-1840` — the
blanket path's camera-frame lock.

So today AO reads, and never writes:

- `frametrigger_source` — must already be `"DAQ"`
- `daqtrig_period_ms` — must already be `1.0`
- `bin` (`run_1p_manifest.m:370`, passed to `Waveform_Camera_Sync_Acquisition`)
- `getROIForAcquisition()` — read by Luminos, never by AO
- `acquisition_exposuretime` — read by Luminos, never by AO

It writes exactly one camera property: `frames_requested`, restored at
`restore_1p_hardware` `:761-766`.

**Nothing anywhere in AO sets a camera trigger mode, period, exposure or readout
mode.** If the Camera tab is left free-running, AO runs an untriggered
acquisition and the frame map in `make_frame_map` (`run_1p_manifest.m:549-566`)
is computed from `calculate_framerate()`, which for Hamamatsu readout mode 1
warns that it "may not be the actual rate" (`Camera.m:2963`).

### 1.5 Camera trigger/readout mechanics in Luminos

`Camera.frametrigger_source` is the **only** control. Its setter
(`Camera.m:341-348`) calls `applyReadoutModeInCpp`:

```matlab
if strcmp(val,"Off") || strcmp(val,"Standalone")
    this.Set_Readout_Mode(0);   % external edge start-trigger, free-run after
else
    this.Set_Readout_Mode(1);   % synchronous readout, one frame per trigger
end
```

`Set_Readout_Mode` (`:2421-2424`) pushes `Set_Read_Mode` into C++. Mode 1 is
documented at `:2414-2419` as "External Synchronous-triggered mode (camera
acquires one frame for each external trigger pulse. On Hamamatsu, each frame
ends when the next trigger arrives)."

**There is no separate MATLAB-side property for trigger polarity, trigger
source, exposure mode, trigger overlap, readout speed or acquisition mode.**
Setting `frametrigger_source = "DAQ"` sets all of it. The only other relevant
property is the exposure pair — `stream_exposuretime` (applied immediately,
follows the live view) and `acquisition_exposuretime`, which
`Prepare_Sync_Aq` applies at
`Waveform_Camera_Sync_Acquisition.m:227` and which is restored afterwards
(`Camera.m:33-45`). In synchronous readout mode the exposure is what
`calculate_framerate` assumes equals the trigger period, so for a 1 ms cadence
`acquisition_exposuretime` should be `0.001`.

The frame triggers themselves are generated by
`Setup_Camera_Trigger_Waveforms.m:238-283`: the VU camera trigger is
`Dev1/port0/line3`, a DO line, so the `"DAQ"` branch appends a `dwfm_pulse`
record at `daqtrig_period_ms/1000` seconds with ~1% duty (widened to three
samples if 1% rounds away, `pulse_duty_fraction`). It is tagged
`script_owner='camera_trigger'` and dropped at the top of every run
(`:46-51`). This runs **after** AO has installed `wfm_data`, which is why
`account_stimulation_outputs` never sees it (the manifest declares it as
expected infrastructure anyway, `virtual_upright_stimulation_manifest.m:145-151`).

### 1.6 Clock resolution — and a discrepancy

`Setup_Camera_Trigger_Waveforms.m:53-120` compares `dq_session.clock` against
each camera's `clock`. If they match, the DAQ is told the real sample clock is
the camera's `hsync_rate` via `external_clock_rate`, and every waveform is
rebuilt at that rate instead of the typed one.

The VU rig file declares `default_clock = "Dev1/PFI0"` — the Orca Fusion's own
clock terminal, `hsync_rate = 200000`. But `default_clock` is only used to
populate the Waveforms dropdown (`get_wfm_startup_info_js.m:53`); it is not a
default the DAQ applies.

AO's profile declares `default_clock = "Internal Dev1"`
(`virtual_upright_1p_profile.m:11`), and `README.md:721`, `:1365`, `:1479` tell
the operator to select `Internal Dev1` and self-trigger.
`DESIGN.md:65` contradicts both, describing the voltage timing clock as
"Camera 1 HSYNC, Dev1/PFI0, 200 kHz".

For a **DAQ-triggered** camera, `Internal Dev1` is the only coherent choice —
clocking the DAQ from the camera's own hsync while the DAQ generates that
camera's frame triggers is circular. Both are 200 kHz, so the sample arithmetic
is identical either way and nothing has visibly broken. `DESIGN.md:65` describes
the Spinning Upright arrangement (`spinning_upright_1p_profile.m:10` does
declare `Dev1/PFI0`) and is stale for the VU.

Nothing in AO currently validates `clock_source` against
`profile.daq.default_clock` — `resolve_luminos_1p_hardware.m:127-132` only
checks the master device is in `supported_internal_masters`, which is
`["Dev1","Dev2"]`.

### 1.7 Orange recording illumination — mod594 / shutter594

Both are declared **inherited, operator-owned** in
`virtual_upright_stimulation_manifest.m:128-134`:

```matlab
inherited("orange_modulator","mod594","Dev1/ao1","mod594","ao", ...
    "594 nm recording illumination. AO records voltage with the operator's
     own orange imaging configuration and never commands it; its waveform is
     part of the acquisition AO was asked to run.");
inherited("orange_shutter","shutter594","Dev1/port0/line1","shutter594","do", ...
    "Mechanical 594 nm shutter, gated with mod594 by the operator.")
```

`inherited(...)` sets `classification="inherited_non_stimulation"`,
`stimulation_capable=false`, `neutral_value=[]`, `owner=operator/operator`
(`:219-226`). `account_stimulation_outputs` therefore accepts any record it
finds on `Dev1/ao1` without comment, and `neutralize_all_stimulation` never
touches it.

`build_luminos_mixed_waveform_config` removes ambient records only from the six
AO-owned terminals (`:67-77`). `Dev1/ao1` and `Dev1/port0/line1` are not among
them, so **whatever the operator's Waveforms protocol put on mod594 is carried
into the AO acquisition verbatim**. That is the current source of orange
illumination during a recording, and it is the second real dependency on an
open Waveforms tab: without one, `wfm_data.ao` has no mod594 record and the
recording is dark.

Device mechanics:

- `NI_DAQ_Modulator` (`Modulators/NI_DAQ_Modulator/NI_DAQ_Modulator.m`) holds a
  `DQ_AO_On_Demand` on its port. `obj.level = v` → `setmodulatorlevel` →
  `AO_OD.data = v` → `DAQmxWriteAnalogScalarF64`. This is the live-view path.
- `NI_DAQ_Shutter` (`Shutter_Device/NI_DAQ_Shutter/NI_DAQ_Shutter.m`) holds a
  `DQ_DO_On_Demand`; `obj.State = v` → `OD_Write`.
- `DQ_On_Demand_Task` creates the DAQmx task at device construction and never
  starts it explicitly — the scalar write auto-starts and auto-stops it. That is
  why a buffered record can coexist on the same terminal, which is exactly how
  mod488 (`Dev1/ao2`, also an `NI_DAQ_Modulator`) already works: AO installs a
  buffered record there every run. The only constraint is that no on-demand
  write may happen while the buffered task is running.

So an AO-owned buffered mod594 record is mechanically identical to the mod488
record AO already installs, and an imperative shutter594 open/close is
mechanically identical to the shutter488 writes at
`run_1p_manifest.m:363` and `:379`.

**Nothing in Luminos or AO generates a frame-synchronous or readout-blanked
orange pattern.** `Setup_Camera_Trigger_Waveforms` touches only camera trigger
lines; the DAQ builds records as written. Any orange timing more nuanced than a
constant exists only as hand-drawn samples in the operator's saved Waveforms
protocol, which is not in either repository. See §11.4.

### 1.8 DMD_Orange

`prepare_luminos_orange_mask.m` resolves `DMD_Orange` by name directly through
`app.getDevice` (`:23`), requires `refimage` (`:32-35`), validates calibration
identity against `targets.reference_camera` (`:48-50`), remaps via
`remap_camera_mask_to_dmd_reference` (`:51-53`), writes with
`setPatterningROI(..., "write_when_complete", true)` (`:54`), then reads back
`dmd.Target>.5` and records `record_owned_dmd_pattern` (`:76-81`).

It is a **static pattern**: no trigger terminal is declared for DMD_Orange
anywhere in the rig file, and the manifest lists
`orange_dmd_advance_trigger` as unresolved (`:185-190`). Ownership is claimed
for both DMDs together at `run_1p_manifest.m:163-164` and released in
`restore_1p_hardware:780`. `Verify_Owned_Dmd_Patterns(DMD)` runs inside
`Waveform_Camera_Sync_Acquisition.m:271` as the last check before any trigger.

This is the exact machinery a preview control would reuse.

### 1.9 What `restore_1p_hardware` currently restores

`run_1p_manifest.m:713-781`, each step in its own `try`:

1. `neutralize_all_stimulation("1p cleanup")`
2. shutter488 closed, mod488 dark
3. if `acquisition_active`: stop every camera, `Disconnect_Clock_Bridge`,
   `daq.reset()`, clear `acquisition_active`
4. blank DMD_Blue
5. `daq.global_props` and `daq.wfm_data` ← captured originals
6. `camera.frames_requested` ← captured originals
7. OBIS setpoint, OBIS stop
8. `release_dmd_pattern_ownership`

Registered as `onCleanup` at `:194`, so it covers error, abort and Ctrl-C; the
pre-arm failure path calls it explicitly at `:189`. **No camera trigger state is
captured or restored, because none is ever set.**

---

## 2. Current blockers, and which ones the change makes obsolete

| Blocker | Where | After the change |
| --- | --- | --- |
| no `global_props` at all | `resolve_luminos_1p_hardware.m:99` | **gone** — AO builds it |
| rate not positive | `:105` | **gone** — AO sets the rate |
| `daq_master` not self-trigger | `:123` | **gone** — AO sets it |
| clock master unsupported | `:127` | **gone** — AO sets the clock |
| camera not DAQ-triggered | implicit, `set_camera_frames_for_duration.m:55` | **gone** — AO sets it |
| `daqtrig_period_ms` ≠ 1 ms | implicit, `daq_camera_frame_period_s` → NaN | **gone** — AO sets it |
| start triggers ≠ profile | `:111` | **stays** — physical wiring |
| clock bridge ≠ profile | `:117` | **stays** — physical wiring |
| `acquisition_active` already true | `:12-15` | **stays** |
| device missing | `require_device:178` | **stays** |
| mod488/shutter/DMD-trigger on wrong port | `:34-48` | **stays** |
| DMD uncalibrated / no refimage | `:69-78` | **stays** |
| wrong DMD calibration identity | `validate_dmd_calibration_identity` | **stays** |
| two records on one AO-owned terminal | `account_stimulation_outputs` | **stays** |
| AO-owned terminal driven from a camera-triggered subsystem | same | **stays** |
| buffered record on an imperative/suppressed line | same | **stays** |
| OBIS interlock open / power out of range | `:89-97` | **stays** |

---

## 3. Dependency summary

**Hard dependencies on an open and configured Waveforms tab, today:**

1. `global_props` must exist at all — `resolve_luminos_1p_hardware.m:99`.
2. `global_props.rate` must be the rate AO wants, because every pulse boundary,
   the blanket state table and the 2P waveforms are all sampled at it
   (`build_luminos_mixed_waveform_config.m:40`, `:222-225`).
3. `global_props.clock_source` must name a supported master — `:127`.
4. `global_props.daq_master` must be self-trigger — `:123`.
5. `wfm_data.ao` must carry the operator's mod594 record, or the recording has
   no orange illumination (§1.7).

**Hard dependencies on Camera-tab state, today:**

6. `frametrigger_source` must already be `"DAQ"`.
7. `daqtrig_period_ms` must already be `1.0`.
8. ROI/FOV and `bin` — genuinely inherited, and should remain so.

Items 1–4 and 6–7 are what the change request removes. Item 5 is what §6 of the
request moves to AO. Item 8 stays.

---

## 4. Proposed canonical AO acquisition state (for review before implementation)

Derived from the profile, the rig file and the README checklist — not invented.

| Quantity | Value | Source |
| --- | --- | --- |
| DAQ sample rate | 200000 Hz | `Virtual_Upright.json` `default_rate`; `README.md:1365` |
| clock source | `Internal Dev1` | `profile.daq.default_clock`; `README.md:721` — see §1.6 |
| `daq_master` | true (self-trigger) | `profile.daq.requires_self_trigger` |
| start triggers | `Dev1/PFI9`, `Dev2/PFI1` | `profile.daq.default_trigger` |
| clock bridge | `Dev1/PFI12`, `Dev2/PFI0` | `profile.daq.clock_bridge` |
| `total_time` | protocol `acquisition_duration_s` | already AO-owned |
| camera | `Orca Fusion`, S/N 001125 | `profile.camera.serial` |
| `frametrigger_source` | `"DAQ"` | → readout mode 1, `Camera.m:341-359` |
| `daqtrig_period_ms` | 1.000 | request §2 |
| `acquisition_exposuretime` | 0.001 s | synchronous readout: exposure = trigger period |
| `frames_requested` | `ceil(duration / 1 ms)` | existing `set_camera_frames_for_duration` semantics |
| ROI / `bin` | **inherited** | Camera tab |
| mod594 during acquisition | constant at AO orange level | §11.4 — needs confirmation |
| shutter594 during acquisition | imperative open/close | mirrors shutter488 |

200 kHz ÷ 1 kHz = exactly 200 samples per frame, which is what the blanket
state table already assumes.

---

## 5. Helpers that would be worth reconciling with the Hadamard Luminos branch

Flagged per request §12. Not coordinated — these would be implemented
package-locally on the AO side first.

1. **Camera acquisition-state journal** — capture/apply/restore of
   `frametrigger_source`, `daqtrig_period_ms`, `acquisition_exposuretime`,
   `frames_requested`. Strong candidate: the restore-on-error semantics are
   identical for both packages and easy to get subtly wrong.
2. **`global_props` construction without the Waveforms tab** — a canonical
   builder taking rate, duration, clock, trigger and master. Strong candidate.
3. **Explicit per-frame camera trigger setup** — probably *not* worth sharing:
   on the VU this is entirely `frametrigger_source = "DAQ"` plus
   `daqtrig_period_ms`, and `Setup_Camera_Trigger_Waveforms` already does the
   rest. A shared helper here would wrap two property writes.
4. **Temporary acquisition ownership** — AO already has
   `claim_dmd_pattern_ownership` / `release_dmd_pattern_ownership` /
   `record_owned_dmd_pattern` / `Verify_Owned_Dmd_Patterns`, which is more
   developed than anything a camera-state journal needs. Worth Hadamard adopting
   rather than AO changing.

---

## 6. Things that should stay inherited (request §17)

- **Camera ROI / FOV and `bin`.** The reference model, the canonical polygons
  and both DMD transforms are all expressed in the reference camera's pixel
  frame; `validate_camera_geometry` and `validate_dmd_reference_geometry`
  already enforce that the live camera matches the reference. AO owning the ROI
  would mean AO owning FOV selection, which is the Camera tab's job and is where
  the operator is already looking when they pick a field.
- **DMD calibrations.** Measured on the rig through Luminos's own calibration
  UI, stored per camera in `additionalConfigData`. AO validates identity and
  must never write them.
- **OBIS 488 setpoint as a *default*.** AO already manages it explicitly when
  `LaserPowerW` is finite and otherwise leaves the operator's setpoint alone
  (`run_1p_manifest.m:177-179`, restored at `:767-772`). That is the right
  split and should not change.
- **Live-view orange power.** Explicitly per request §5.

---

## 7. Open point that needs Vincent

See §11.4 below — the shape of the orange waveform during a recording is the one
thing the code cannot answer.

---

## 11. Where the change request's premises differ from the code

### 11.1 The quoted error is unreachable

Request §3 quotes `build_luminos_1p_waveform_config`'s message. That function is
test-only (§1.1). The gate experimenters hit is
`resolve_luminos_1p_hardware.m:99-103`. Both should be fixed, but only the
second one changes anything on the rig.

### 11.2 `frametrigger_source` *is* enough

Request §2 says "Do NOT merely assume `frametrigger_source` is enough" and lists
synchronous-readout mode, trigger source/mode, polarity, exposure mode, trigger
overlap, readout speed and acquisition mode.

On this camera stack, `frametrigger_source` is the only MATLAB-side control, and
its setter *is* the readout-mode switch (`Camera.m:341-359`). Of the listed
properties, the only one that exists separately and matters is the **exposure**
pair, because in synchronous readout mode `acquisition_exposuretime` is what
`calculate_framerate` treats as the trigger period. Polarity, trigger overlap,
readout speed and acquisition mode are not exposed to MATLAB at all; setting
them would mean new `CAMERA_WRAPPER_MEX` entry points and a rig-side rebuild,
which is out of proportion to the problem and would be unverifiable from here.

So the camera properties AO should own are three, not eight:
`frametrigger_source`, `daqtrig_period_ms`, `acquisition_exposuretime` — plus
`frames_requested`, which it already owns.

### 11.3 `Internal Dev1` vs camera HSYNC

Request §3 says to use the profile as the source of truth "if correct". The
profile and the rig file disagree (§1.6), and `DESIGN.md:65` agrees with the rig
file. `Internal Dev1` is the only coherent choice for a DAQ-triggered camera and
both are 200 kHz, so nothing changes numerically — but `DESIGN.md:65` is stale
for the VU and should be corrected rather than left to mislead the next reader.

### 11.4 The orange waveform shape cannot be audited from the repositories

Request §6 says "Do not invent a simple constant AO waveform if the existing rig
uses a more nuanced orange timing pattern. Audit first."

Audited. **Nothing in Luminos or AO generates orange timing of any kind.**
`Setup_Camera_Trigger_Waveforms` only touches camera trigger lines; the DAQ
plays back whatever records `wfm_data` carries; mod594 is an on-demand
modulator with no timing logic. Any structure in the orange command during a
recording exists solely as samples in the saved Waveforms protocol on the rig
machine, which is in neither repository.

So: a constant at the AO recording level for the recording window is correct
*unless* your saved VU protocol draws something else on mod594. **Please check
your protocol's mod594 record before I build on the constant assumption** — if
it is a constant, there is nothing further to preserve; if it is blanked,
ramped or gated, I need the shape.

shutter594 is unambiguous: an `NI_DAQ_Shutter` with an on-demand DO write, so
imperative open-before-arm / close-after is the only mechanism that matches how
shutter488 is already driven, and it is what the manifest's own 1P precedent
declares.

### 11.5 Preflight does not block on the things §10 lists

Request §10 asks whether preflight blocks on camera trigger mode, trigger
period, or Waveforms rate. It does not — `preflightPlan`
(`AdaptiveOptopatchController.m:1771-1896`) never inspects any of them. It
resolves hardware (which fails earlier, in `resolve_luminos_1p_hardware`), and
runs `preflight_camera_frames`, which only calls
`set_camera_frames_for_duration` and restores the counts. The blockers to remove
are all in `resolve_luminos_1p_hardware`, as tabulated in §2.

---

# Implementation corrections (2026-10-28)

Written after the change was made. The audit above stands except where
noted here.

### §11.2 understated one thing

The audit said the exposure was the only extra camera property that
mattered. True, but it did not say WHY it has to equal the frame period:
in synchronous readout `Camera.calculate_framerate` reads the exposure *as*
the period between triggers, so an exposure that disagrees with
`daqtrig_period_ms` makes the archived frame rate a different number from
the real one. `camera_cadence_for_profile` now refuses a profile whose
exposure exceeds its frame period.

### Ownership had to become opt-in per rig

The audit treated this as a Virtual Upright change and did not say what
happens to the Spinning Upright. It cannot take the same path: its DAQ is
genuinely clocked from the Orange camera's line sync, so its sample rate is
not a number a profile can state, and its camera is counter-triggered
through `Dev1/Ctr0` rather than a DO line. Both halves of ownership are now
gated on profile fields — `daq.sample_rate_hz` and the `camera.frame_*`
trio — and the Spinning Upright declares neither, so it keeps inheriting,
including the `NoActiveLuminosWaveform` gate.

### A latent accounting bug the change exposed

`classify_terminal` grew its finding lists with a bare `(end+1)`. From
`strings(0,1)` that gives a 1x1, and the *second* such assignment then
grows it along the ROW — so a terminal with two findings returned a 1xN
that would not `vertcat` with the caller's column. No terminal could raise
two findings until the orange modulator could be both untagged and
commanded. Fixed with an explicit row subscript.

### A real bug in `require_device`

`81f8310` added a "the sole device of a type is the one meant" fallback so
the VU's one DAQ could be found under the rig file's own name. It applied
to every device type. The VU has TWO DMDs, so on a rig where `DMD_Blue` is
absent or renamed the sole surviving DMD is `DMD_Orange` — and AO would
have programmed stimulation patterns onto the recording DMD while
reporting, in DMD_Blue's name, that it was uncalibrated.
`TestFovWorkflowCleanup/failedMandatoryPreflightDoesNotFreezeRun` caught
it. The fallback is now restricted to the DAQ, where
`Waveform_Camera_Sync_Acquisition` already refuses more than one.

### Two preview-invalidation paths `markEditableChanged` does not cover

`setCellEligibility` and `setCellEligibilityBatch` deliberately do not call
it — they touch decisions, not geometry, and invalidating the cell-summary
cache on a checkbox was expensive. But record eligibility IS which cells
the Orange mask contains, so both now clear a projected preview explicitly.

### `wfm_data` arrives empty in two different shapes

A live Luminos DAQ carries `[]` until the Waveforms tab runs. Any object
whose property is declared `struct` — the simulated device, and anything
else written that way — carries an EMPTY STRUCT ARRAY instead, which passes
`isstruct` while failing every `(1,1) struct` argument downstream. The
resolver now requires scalar as well.
