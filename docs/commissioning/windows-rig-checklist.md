# Adaptive Optopatch — Windows rig commissioning checklist

Run this on the microscope PC after deploying the React/AO stabilization work.
**15–25 minutes.** Nothing below emits light except step 10, which is the one
deliberate acquisition and is explicitly marked.

Everything else in this list is read-only or in-memory: previews build masks in
memory, Update Plan writes files but drives no device, and editing cells touches
no hardware.

Before starting: `build("rebuild_c", false)` from the Luminos root, then launch
Luminos normally. If the console prints
`Starting the interface from source (Debug)`, the Release bundle was not used
and steps 1 and 11 do not apply.

---

### 1. Frontend and backend agree

**Do.** Open the Adaptive Optopatch tab. Read the MATLAB console from launch.

**Expect.** `Starting the interface from its Release build.` and **no**
`JS_Server:releaseBundleStale` warning. No red banner at the top of the AO tab.

**PASS** — no staleness warning and no version banner.
**FAIL** — either appears. Re-run `build("rebuild_c", false)` and relaunch. A
banner reading *"frontend and backend versions do not match"* means the bundle
is older than the backend it is talking to; everything below would be testing
the wrong frontend, so stop here.

---

### 2. New FOV and reference display

**Do.** Snap Camera 1 in Luminos. In AO, choose the snapshot from
**Select reference…**. Then press **New FOV** and confirm.

**Expect.** The image appears, cell count 0. After New FOV the canvas empties,
the selection clears and any overlay disappears. The loaded protocol survives.

**PASS** — image renders, New FOV empties the field, no error.
**FAIL** — a previous FOV's pixels or outlines persist after New FOV.

---

### 3. Spatial preview with a mixed Record/Stim selection

**Do.** Reload the snapshot and draw 3 somata. In the cell table set:
cell_001 Record ✓ Stim ✓ · cell_002 Record ✓ Stim ✗ · cell_003 Record ✗ Stim ✓.
Press **Preview 1P**.

**Expect.** Blue **and** Orange outlines on **all three** cells. Dashed = not
selected for that channel: cell_002's Blue dashed, cell_003's Orange dashed.
The caption reads *"1P masks for all 3 drawn somata"*.

**PASS** — no soma is missing geometry, and dashing follows Stim for Blue and
Record for Orange.
**FAIL** — a cell has no outline. That is the old execution-filtered preview;
report it rather than working around it.

---

### 4. Blue V editing is responsive

**Do.** Type a Blue V into cell_001, press Tab, type into cell_002, Tab,
cell_003, Tab. Do it at normal speed.

**Expect.** No pause. The typed value stays on screen — it must not flash back
to the old value. Tab moves to the next field without losing focus. The banner
shows *"Unapplied changes (3)"*.

**PASS** — no perceptible lag, no reverting, no focus loss.
**FAIL** — any freeze, revert or lost focus.

---

### 5. Update Plan commits everything at once

**Do.** Press **Update plan**.

**Expect.** One action. The banner changes to *"Plan up to date"*. The applied
plan summary shows the stimulating-cell count and acquisition count. The Blue V
values you typed are still there.

**PASS** — one press commits Record, Stim and all three voltages together.
**FAIL** — a voltage reverts, or the plan reports cells you did not select.

---

### 6. Live progress during a run — **SAFE SIMULATED RUN**

**Do.** Prepare a plan of at least 4 acquisitions. Press **Run**. Watch the
progress line.

**Expect.** The lifecycle shows **Running** within a second or two — *before*
Run returns. The counter advances `0 / N → 1 / N → 2 / N …`, one step per
acquisition, and reaches `N / N`.

**PASS** — intermediate values are visible.
**FAIL** — it sits at `0 / N` and jumps to `N / N` at the end, or the tab shows
"MATLAB is not answering". That is the pre-fix transport behaviour.

---

### 7. Stop After Current actually stops

**Do.** Start a run of ≥4 acquisitions. While acquisition 1 is running, press
**Stop after current acquisition**.

**Expect.** The label changes to *"Running — stopping after this acquisition"*
promptly. Acquisition 1 finishes. **Acquisition 2 does not start.** The run ends
with `1 / N` completed.

**PASS** — the next acquisition does not begin.
**FAIL** — the whole batch runs anyway. The stop request is not reaching MATLAB.

---

### 8. Connectivity uses the current Stim cells

**Do.** Run `create_connectivity_round_robin_protocol` once (it needs no FOV).
Load the saved protocol in AO. With cells 1–3 Stim-enabled, press Update plan.
Note the stimulating-cell list. Now untick cell_003, press **Update plan**
again.

**Expect.** First plan targets 3 cells; second targets 2. **No protocol
regeneration, no file edit.** The saved .mat is unchanged.

**PASS** — the target set follows the checkboxes.
**FAIL** — the plan still names three cells, or Update Plan asks for cell IDs.

---

### 9. Per-cell voltages reach the frozen schedule

**Do.** Set three distinct Blue V values (e.g. 1.2 / 1.5 / 1.8). Update plan.
In MATLAB:

```matlab
c = xx.getAdaptiveOptopatchController();
e = c.ActiveRunPlan.resolved_protocols{1}.events;
unique([e.target_cell_id, string(e.command_voltage_v), e.command_voltage_source], 'rows')
```

**Expect.** Each cell's events carry that cell's own voltage, source
`fov_cell`.

**PASS** — three distinct voltages, correctly paired.
**FAIL** — one voltage everywhere, or a `gui` source (there must be none).

*Also worth one deliberate failure:* clear one cell's Blue V and press Update
plan. It must refuse **and name that cell**.

---

### 10. One safe acquisition — **THIS ONE EMITS LIGHT**

**Do.** Confirm the sample is expendable or the shutter path is safe for your
setup. Prepare a single-acquisition plan on one cell. Run it.

**Expect.** The DMD pattern matches the intended cell. `output_data.mat` is
written and contains `adaptive_optopatch_record`. The DMD is blanked afterwards
and ownership released.

**PASS** — light lands on the intended cell only, and the DMD is dark after.
**FAIL** — anything else. Stop and report before running more.

---

### 11. Rerun and new batch

**Do.** With the completed plan unchanged, press **Run** again.

**Expect.** A **new** `adaptive_optopatch_run_NNN` folder (batch number +1).
The previous batch stays on disk. Progress runs `0 / N → N / N` again. For a
connectivity plan, the realized target order is **identical** to the first
batch — the schedule is frozen, not regenerated.

**PASS** — a new batch runs and the previous one survives.
**FAIL** — Run returns immediately having done nothing. That is the
checkpoint-routing defect; check whether the protocol contains a null/control
acquisition.

---

## If something fails

Capture, in this order: the MATLAB console from launch, the browser console,
`c.getState()`, and the run folder path. The first two are where the transport
and version problems show up; the last two are where the planning problems do.
