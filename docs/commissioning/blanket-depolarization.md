# Blanket depolarization — hardware commissioning

**Status: software-tested, NOT optically commissioned.**

Every number below is what the implementation currently does. None of it
has been checked against light on the Virtual Upright. Nothing in this
document is a measurement.

---

## 1. What the implementation currently does

Read from `blanket_depolarization_spec` (the defaults) and
`build_blanket_state_table` (the arithmetic). At the VU's 200 kHz DAQ rate,
one sample is 5 µs.

| Quantity | Value | Samples at 200 kHz |
| --- | --- | --- |
| `cycle_period_s` | **1.000 ms** | 200 |
| camera frame period | **1.000 ms** (must equal the cycle — refused otherwise) | 200 |
| `blanket_fraction` | **0.20** | — |
| blanket phase | **0.200 ms** | 40 |
| target phase | **0.800 ms** | 160 |
| `target_onset_guard_s` | **50 µs** | 10 |
| target lit per cycle | **0.750 ms = 75%** | 150 |
| `mod488_v` (blanket level) | **required, no default**, (0,5] V | — |
| DMD trigger width | `max(3 samples, 20 µs)` = **20 µs** | 4 |
| `dmd_trigger_lead_samples` | **0** — the edge and the new mod488 level are the same sample | 0 |

Per cycle:

```
  0 µs ─┬─ DMD trigger ↑ (20 µs wide), mod488 → blanket level
        │  blanket mask up, 200 µs
200 µs ─┼─ DMD trigger ↑, mod488 → 0 V  (the 50 µs guard)
        │  target mask coming up
250 µs ─┼─ mod488 → target Vstim
        │  target mask up, 550 µs
1000 µs ┴─ next cycle
```

Nothing is rounded. A cycle, phase, guard, camera period or unit start that
is not a whole number of DAQ samples is refused, as is a cycle that is not
exactly one camera frame.

The playlist holds **one programmed unit** and is declared to wrap; later
rounds are the ALP replaying it. `expected_trigger_count =
states_per_round × round_count`.

---

## 2. The trigger→optically-stable latency is NOT known

This is the open question, and the repository does not answer it.

**What 44 µs actually is.** `ALP_MIN_PICTURE_TIME`, which the ALP documents
as *the minimum time between the start of consecutive pictures* and which
Luminos's `Write_Stack` programs into the sequence. It is a scheduling
constraint on how fast pictures may be requested. It is **not** a measured
delay from a trigger edge to a settled micromirror pattern.

The notebook says so in as many words (2026-10-23, "Target-onset guard"):

> 50 us covers the 44 us ALP minimum picture time and is a placeholder for
> the photodiode measurement.

**So the 50 µs guard is a placeholder, not a margin derived from data.**

The only related VU observation on record is from the 2026-09-17/23 slave
FLUT diagnostics, also in the notebook: a slave picture *stays up ~95 ms
after its trigger despite the 44 µs programmed picture time*. That is
persistence, not onset latency, and it says nothing about how quickly a
newly requested pattern becomes optically stable.

**Why it matters, and only here.** Only the blanket→target transition is
hazardous. Until the DMD actually shows the target, the blanket union mask
is still up — so if Vstim arrived before the pattern settled, the target's
voltage would light the whole union once per cycle. The guard holds mod488
at 0 V across that window. The other transitions lose a little light and
nothing else.

**If the real latency exceeds 50 µs**, every cycle puts some targeted
Vstim on the blanket mask. The data would not obviously look wrong; it
would look like weaker, less specific stimulation.

### Measuring it (the outstanding item)

A photodiode on the sample plane, a DAQ input or scope on the DMD advance
line, and a pattern pair with no spatial overlap:

1. program two masks that share no pixels — e.g. left half and right half;
2. put the photodiode where only mask B is lit;
3. hold mod488 at a constant level (no guard, no gating) so the photodiode
   sees the pattern and nothing else;
4. trigger A→B and record both the trigger edge and the photodiode;
5. the latency is edge → photodiode reaching its steady level;
6. repeat B→A, and at several levels.

Then set `target_onset_guard_s` to that number plus margin, rounded up to a
whole DAQ sample. **Do not change the guard without this measurement.**

---

## 3. Commissioning checklist

Run on a **uniform fluorescent slide**, never on tissue.

Generate the short protocol with `pulse-protocols/create_blanket_commissioning_protocol.m`,
draw the two ROIs it describes (one large, one small, well separated), and
print the expected sequence:

```matlab
plan  = controller.ActiveRunPlan;
sheet = adaptive_optopatch.describe_blanket_commissioning( ...
            plan.manifest.trials.pulse_schedule{1}, "Targets", plan.targets);
```

| # | Question | How to answer | Pass |
| --- | --- | --- | --- |
| 1 | **Initial DMD state** — entry 1 up before the first trigger? | Camera, shutter open, before arming | mask = `sheet.unit.mask_key(1)` |
| 2 | **Blanket/target sequence** — do the two masks alternate? | Camera movie at 1 kHz; one cycle per frame | large/small ROI intensities alternate as the sheet says |
| 3 | **20/80 timing** | Photodiode on a blanket-only region | 200 µs on, 800 µs off, per 1 ms |
| 4 | **Trigger count** | `sheet.expected_trigger_count` vs the emitted DO train | equal |
| 5 | **Advance count** | `record.dmd_advance_verification` | `status == "matched"` |
| 6 | **Off-by-one** | which ROI is bright in each epoch | matches the sheet, not shifted by one |
| 7 | **mod488 vs DMD transitions** | photodiode + mod488 monitor on one scope | Vstim rises ≥ guard after the edge, pattern already settled |
| 8 | **Camera timing** | `camera_frame_plan` in the archived summary | 1.000 ms period, one cycle per frame |
| 9 | **Acquisition duration** | archived `total_time` vs `sheet.acquisition_duration_s` | equal |
| 10 | **Extra triggers** | counters at arming vs just before the shutter | unchanged (the runner already refuses otherwise) |
| 11 | **Final playlist entry** | counters after the run | `sheet.expected_final_playlist_entry` |
| 12 | **Cleanup** | after normal completion, after Stop, after an induced error | DMD blank, shutter closed, mod488 0 V, camera cadence restored |
| 13 | **Realized duty** | photodiode integral over a cycle | blanket 20%, target 75% (not 80% — the guard) |

---

## 4. The MEX rebuild is still required

Items 5, 10 and 11 read the ALP's own counters, which need
`DMD_MEX('Get_Projection_Progress')`. That command was added in Luminos
commit `a803fdbd6` and **has to be rebuilt on the rig** — the MEX binary
installed on the VU predates it.

| | |
| --- | --- |
| Binary | `DMD_MEX` |
| Sources changed | `src/lib/Luminos_MEX_VS/DMD/ALP_DMD.h`, `.cpp`; `src/lib/Luminos_MEX_VS/DMD_MEX/main_class.cpp` |
| MATLAB side | `src/Devices/Patterning/DMD/ALP/ALP_DMD.m` (no rebuild needed) |
| Build | open `src/lib/Luminos_MEX_VS/Luminos_MEX_VS.sln` in Visual Studio on the rig, Release x64, build the `DMD_MEX` project |

Check it is actually running the new build before trusting items 5/10/11:

```matlab
dmd = app.getDevice("DMD","name","DMD_Blue");
adaptive_optopatch.read_dmd_projection_progress(dmd)   % .available must be true
```

Without the rebuild the blanket path still **runs** — it archives
`blanket_validity = "unverified_dmd_advance_count"` rather than guessing —
but the phase-slip safeguard is inert, which is most of what commissioning
is for. Rebuild first.

---

## 5. What is still unknown after a green software suite

- the trigger→optically-stable latency (§2), and therefore whether 50 µs is
  enough;
- whether arming already counts as a displayed frame in the ALP's counters
  — the counter model is uncommissioned, and item 11 is what settles it;
- whether the playlist genuinely wraps in slave mode over tens of thousands
  of triggers, rather than over the eight the 2026-09 diagnostics covered.
