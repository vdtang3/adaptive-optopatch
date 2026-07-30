# Adaptive Optopatch

First-pass MATLAB package for planning one-neuron-per-acquisition Optopatch
screens alongside Luminos. It keeps neuron definitions in voltage-camera
coordinates and supports two interchangeable stimulation backends:

- `1p_dmd`: logical soma masks transformed by Luminos through `DMD_Blue`.
- `2p_spiral`: soma centers and radii passed to the Luminos scanning device.

The planning GUI is read-only with respect to hardware. Separate guarded
calibration, staged 2P, and automated 1P runners can start Luminos acquisitions
only after their explicit confirmation controls are satisfied.

## First installation on the VU

### Requirements

- Windows VU computer with MATLAB R2023b.
- MATLAB Image Processing Toolbox.
- Luminos with the synchronized combined Dev1/Dev2 implementation.
- Dev1 and Dev2 clock/trigger cabling installed and tested.
- This complete `adaptive_optopatch` folder, including the
  `+adaptive_optopatch` and `tests` subfolders.

Clone or copy the repository to a location visible to the VU, for example:

```text
Z:\Lab\code\adaptive_optopatch
```

In the same MATLAB process that will run Luminos:

```matlab
packageRoot = "Z:\Lab\code\adaptive_optopatch";
addpath(packageRoot)

which launch_reference_gui
which launch_galvo_calibration_gui
which launch_2p_test_runner_gui
```

Each `which` command should resolve to the copied repository. Do not add a
different or older Adaptive Optopatch checkout earlier on the MATLAB path.

Choose a persistent calibration/configuration location:

```matlab
setenv("ADAPTIVE_OPTOPATCH_CONFIG_ROOT", ...
    "Z:\Lab\Virtual_Upright\AdaptiveOptopatchConfig")

adaptive_optopatch.galvo_calibration_store_root()
```

The displayed path should end in `Virtual_Upright`. Put the `addpath` and
`setenv` commands in the VU MATLAB `startup.m` after the first successful test,
or configure the environment variable permanently in Windows.

### Test 1: offline package tests

This test does not require Luminos or connected hardware:

```matlab
cd(packageRoot)
results = run_tests()
```

The returned test table must contain no failed or incomplete tests, and
`run_tests` must return without an `assertSuccess` error. Do not proceed
otherwise. Save the complete test report or screenshot with the Git commit
identifier being tested:

```matlab
system("git rev-parse HEAD")
```

If the VU copy is not a Git checkout, record the commit identifier manually.

### Test 2: start Luminos and inspect synchronization

Start Luminos normally. Before any light-producing test:

- confirm both DAQs are present as the combined DAQ;
- select `Internal Dev1`;
- select self-trigger;
- confirm the DAQ is idle;
- load a waveform protocol that contains the Camera 1 acquisition settings;
- use `Dev2/ai1` and `Dev2/ai2` in the active protocol when galvo feedback
  recording is desired.

Run the read-only checker:

```matlab
report = verify_vu_setup(luminosApp)
```

Save or screenshot `report`. Before galvo calibration, a warning or failure
about a missing active galvo calibration is expected. Errors involving missing
Camera 1, combined DAQ, Chameleon scanner, `2P mod`, clock bridge, or trigger
configuration must be resolved before continuing.

### Test 3: blocked Camera 1/galvo calibration

```matlab
calibrationGui = launch_galvo_calibration_gui(luminosApp);
```

Use the defaults and:

1. Mechanically block the 2P beam.
2. Keep the Pockels command at `0 V`.
3. Preview the 3-by-3, +/-0.1 V grid.
4. Check **Blocked trajectory reviewed**.
5. Acquire the grid.

Spot detection is expected to fail with the beam blocked. Confirm instead that:

- Camera 1 acquired;
- the DAQs started together;
- no abrupt terminal galvo jump occurred;
- `2P mod` returned to `0 V`;
- Camera 1 ROI/binning/trigger settings were restored;
- the previous Luminos waveform was restored;
- the acquisition folder contains `galvo_calibration_plan.mat`.

Do not proceed to light if any restoration or motion check fails.

### Test 4: attenuated calibration and persistence

Use a uniform fluorescent sample, strong attenuation, and a low independently
tested Pockels voltage. Run the grid again with
**ARM attenuated calibration light** checked. Review every detected point,
reject or correct bad centroids, and refit.

Apply only a calibration for which both direct and leave-one-point-out RMSE
pass. Click **Apply accepted calibration**, then verify:

```matlab
[artifact,activeStatus] = ...
    adaptive_optopatch.get_active_galvo_calibration()
```

`activeStatus.found` should be true. Restart MATLAB and Luminos, restore the
package path and environment variable, then run:

```matlab
reloadStatus = ...
    adaptive_optopatch.load_active_galvo_calibration(luminosApp)
```

Both `reloadStatus.found` and `reloadStatus.applied` should be true, and the
calibration identifier should match the one that was accepted.

### Test 5: Camera 1 Snap and target planning

Take a Camera 1 Snap in Luminos and launch:

```matlab
targetGui = launch_reference_gui(luminosApp);
```

Load the Snap MAT file, draw one test soma, choose `2p_spiral`, preview the
spiral and parking point, and save the planning bundle. Confirm that exact
calibrated spiral metrics are shown rather than “pending calibration.”

### Test 6: blocked target acquisition

```matlab
runner = launch_2p_test_runner_gui( ...
    luminosApp, ...
    "Z:\path\to\the_saved_planning_bundle");
```

With the beam mechanically blocked:

1. Select `blocked_test`.
2. Use one test pulse.
3. Keep Pockels at `0 V`.
4. Click **Validate + preview**.
5. Inspect the complete X, Y, and Pockels traces.
6. Arrange oscilloscope monitoring or record `Dev2/ai1` and `Dev2/ai2`.
7. Check **Blocked trajectory reviewed**.
8. Run one acquisition.

Confirm synchronization, frame timing, bounded tracking, terminal return,
parking behavior, `2P mod = 0 V`, and settings restoration. Preserve
`adaptive_optopatch_2p_waveforms.mat` and `output_data.mat`.

### Test 7: attenuated target acquisition

Only after Test 6 passes, use a strongly attenuated fluorescent sample:

1. Select `attenuated_test`.
2. Use one pulse.
3. Enter a low tested Pockels voltage.
4. Preview again.
5. Check both confirmation boxes.
6. Run one acquisition.

Verify that the illuminated spiral lands on the selected Camera 1 target and
that no light is commanded during movement or parking. Increase to at most ten
test pulses only after the single-pulse run passes.

The unrestricted `experimental` runner is intentionally unavailable until a
structured hardware-validation record documents feedback, phase alignment, and
terminal-return validation.

## Workflow

### Interactive GUI

```matlab
cd('/path/to/adaptive_optopatch')
app = launch_reference_gui;
```

When running in the MATLAB process that owns Luminos, pass the live app object:

```matlab
app = launch_reference_gui(luminosApp);
```

The GUI then reads the active scanner `tform` and `sample_rate` during preview
and save, and calculates exact double-spiral cycles per optical pulse. If the
live app or a valid scanner calibration cannot be found, target design remains
available and the status panel displays a warning.

In the Luminos React camera panel, click **Snap** for Camera 1 (`Orca Fusion`).
Luminos writes a timestamped TIFF and MAT pair into its `Snaps` folder. In the
Adaptive Optopatch GUI, select the MAT file; it contains the image together
with camera coordinates, binning, timestamp, and the current DMD transforms.
No reference acquisition, `output_data.mat`, or `frames1.bin` is required. Draw movable polygonal soma
ROIs, inspect edge/overlap QC, preview either 2P spiral footprints or eroded 1P
DMD masks, and save the reference model, target bundle, and randomized trial
manifest. Defaults produce one acquisition per neuron: one repeat and no null
trials. The GUI designs files only; it does not control hardware.

After a preview is generated, **Hide target preview** and **Hide ROI polygons**
independently reveal the raw reference image. These controls only change what is
shown; they do not delete ROIs or alter the target and planning-bundle data.

The DMD erosion value is signed: positive values shrink the soma mask, zero
leaves it unchanged, and negative values expand it by the absolute pixel value.
GUI-generated screens contain no null acquisitions; null rows remain available
through the programmatic manifest API when needed for specialized controls.

When saving, the GUI automatically creates a timestamped subfolder directly
beside the selected snapshot in the Luminos `Snaps` folder, such as
`adaptive_optopatch_pilotFov_20260715_143000`. There is no alternate save
destination. This keeps each plan with its source FOV while leaving the
`Snaps` folder root uncluttered.

Every new bundle also contains `planning_session.mat`, which stores the exact
polygon vertices and all editable GUI parameters. When a snapshot is loaded,
the GUI searches its `Snaps` folder for the newest compatible
bundle and restores its ROIs and parameters automatically. Only bundles using
this current planning-session format are considered.

For 2P targets, the dashed cyan circle is the requested footprint and the solid
cyan curve is a normalized preview generated with Luminos's own Fermat-spiral
equation. The exact number of turns depends on the radius after conversion to
scanner volts, so it is finalized by the calibrated live Luminos scanner.

The magenta point is the darkest valid cell-free parking region found outside
the target clearance zone but within two spiral diameters by default. A small
spatial average prevents isolated camera pixels from winning the search. The
dashed magenta segment shows the dark transition. After
previewing, the status panel reports double-spiral cycles per optical pulse when
the reference acquisition contains a nonidentity scanner calibration. Otherwise
it reports that exact cycle timing is pending calibration.

### Programmatic API

```matlab
addpath('/path/to/adaptive_optopatch')

[referenceImage, info] = adaptive_optopatch.read_reference_snapshot( ...
    '/path/to/Snaps/143212pilot_fov.mat');
metadata = info.metadata;

% roiMasks is height x width x N logical, in frames1/camera-1 coordinates.
reference = adaptive_optopatch.create_reference_model( ...
    referenceImage, roiMasks, metadata, ...
    "MicronsPerPixel", 0.35, "FovId", "pilot_fov_01");

targets = adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm", 6, "SpiralDensityPointsPerVolt", 10, ...
    "DmdErosionPixels", 1);

manifest = adaptive_optopatch.build_screen_manifest(reference, targets, ...
    "Mode", "2p_spiral", "Repeats", 5, "NullFraction", 0.1, ...
    "RandomSeed", 1);

adaptive_optopatch.save_bundle('/path/to/planning_output', ...
    reference, targets, manifest);
```

Each screen-manifest row now contains its complete realized 200-pulse schedule:
5 ms pulses by default, 45–55 ms end-to-start dark intervals, 100 ms pre/post
delays, and an automatically calculated acquisition duration.

Validate the complete screen without hardware:

```matlab
run = adaptive_optopatch.run_manifest(manifest, targets, ...
    "OutputDirectory", "/path/to/run_folder");
```

This writes a resumable `run_checkpoint.mat`. Staged blocked and attenuated 2P
tests are available after a valid camera/galvo calibration; unrestricted
experimental manifests remain locked pending commanded-versus-feedback
validation.

Inspect the first synchronized VU 2P acquisition without modifying it:

```matlab
report = adaptive_optopatch.inspect_vu_2p_acquisition( ...
    "D:\data\virtual_upright\20260728\1454092P_test");
```

The first-pass 2P module now generates its own camera-calibrated X/Y trajectories,
automatically retimes them to explicit velocity and acceleration ceilings,
creates minimum-jerk parking transitions, and produces a synchronized
`Dev1/ao3` Pockels waveform. It can inject these precomputed sample vectors into
the active Luminos configuration with
`adaptive_optopatch.build_luminos_2p_waveform_config`. The archived VU scanner
transform is rejected as out of range, so a new calibration must be fitted
before those vectors can be used on the rig.

## Rapid screen analysis

Once completed acquisition directories are entered in the run manifest:

```matlab
analysis = adaptive_optopatch.analyze_screen_run(run, reference, ...
    "BackgroundMode", "local_annulus", ...
    "MotionCorrection", "integer_translation", ...
    "PhotobleachCorrection", "none", ...
    "Direction", 1);
save("connectivity_analysis.mat","analysis","-v7.3")
```

Use an experimenter-defined background ROI instead:

```matlab
nullMask = adaptive_optopatch.draw_null_roi(reference.reference_image);
analysis = adaptive_optopatch.analyze_screen_run(run, reference, ...
    "BackgroundMode", "null_roi", "NullRoiMask", nullMask);
```

Review directed candidates manually:

```matlab
app = launch_pair_review_gui( ...
    "connectivity_analysis.mat", ...
    "/path/to/reference_model.mat");
```

## STF design

Create the initial single-pulse, 50 Hz, and 100 Hz conditions:

```matlab
conditions = adaptive_optopatch.default_stf_conditions( ...
    "RepeatsPerCondition", 100, ...
    "PulsesPerTrain", 5, ...
    "PulseDurationMs", 5, ...
    "ModulatorVoltage", 0);
```

After saving accepted pairs from the review GUI:

```matlab
s = load("accepted_pairs.mat");
stfManifest = adaptive_optopatch.build_stf_manifest( ...
    s.accepted_pairs, targets, conditions, ...
    "Mode", "2p_spiral", ...
    "EventDarkIntervalMs", [450 550]);
```

Each presynaptic source receives one acquisition containing the randomized,
intermixed conditions. Frequencies above 100 Hz and overlapping pulses are
rejected.

## Active Luminos settings

From the MATLAB process containing the live Luminos app:

```matlab
app = launch_live_settings_gui(luminosApp);
```

This captures active nontransient device settings and lets the experimenter
record requested overrides. It does not apply overrides to hardware while the
live runner is locked.

## Coordinate convention

Camera points are `[x y]`, with `x` indexing columns and `y` indexing rows of
`frames1.bin`. ROI masks are exactly the acquired camera ROI size. Do not
pre-warp masks into DMD or galvo coordinates. The live Luminos device applies
its current calibration, camera ROI offset, and binning.

## Safety checks

- Metadata must identify `Virtual_Upright`, voltage camera serial `001125`,
  and `DMD_Blue` unless overrides are explicitly supplied.
- Targets touching image edges are flagged.
- 1P masks that overlap other somata are flagged.
- Live adapter calls are dry-run by default.
- A nonidentity scanner transform is required for 2P live configuration,
  unless `AllowIdentityScannerTransform=true` is explicitly supplied.
- Spiral density is expressed using Luminos's native `Points_Per_Volt` value.
  Fixed-repetition-rate mode must be disabled because it overrides density.

## Current scope

This version provides reference/target GUIs, exact screen and STF schedules,
resumable dry runs, an automated guarded `1p_dmd` runner, Luminos settings
snapshots, streamed raw-movie ROI extraction, optional integer rigid correction,
background subtraction, connectivity ranking, and manual pair review.

## Automated 1P DMD runner

The Virtual Upright 488-nm path is defined by
`adaptive_optopatch.virtual_upright_1p_profile`:

- spatial pattern: `DMD_Blue`;
- laser: OBIS `488` on `COM9`, declared maximum `0.055 W`;
- pulse modulation: `mod488` on `Dev1/ao2`, `0-5 V`;
- acquisition shutter: `shutter488` on `Dev1/port0/line0`;
- synchronized DAQs: clock bridge `Dev1/PFI12` to `Dev2/PFI0`, with
  device-local start triggers `Dev1/PFI9` and `Dev2/PFI1`;
- voltage camera: Camera 1 on Dev1 (its HSYNC remains available on `Dev1/PFI0`).

Use the Luminos `VU_MultiDAQ_Synchronization` branch (or its merged successor).
Start Luminos, load the desired waveform protocol in React, select either
`Internal Dev1` or `Internal Dev2` as the master clock, and select self-trigger.
The active protocol must contain a buffered channel on the selected master DAQ.
Set the OBIS to `ANALOG` or `MIXED` external-modulation mode. Then open a
planning bundle saved in `1p_dmd` mode:

```matlab
runner = launch_1p_runner_gui(luminosApp, ...
    "D:\path\to\adaptive_optopatch_fov_YYYYMMDD_HHMMSS");
```

The runner inherits the active Luminos waveform rate, clock, trigger, DAQ-master
state, completion trigger, camera exposure/ROI/binning, and all waveform outputs
other than `mod488`. For each trial it:

1. validates the live devices, nonidentity DMD calibration, selected DAQ master,
   clock bridge, device-local triggers, OBIS external-modulation mode,
   interlock, power, and command limits;
2. transforms and writes the selected camera-coordinate mask through
   `DMD_Blue`;
3. replaces only the active `mod488` waveform with the manifest's exact pulse
   schedule and recalculates camera frame counts using Luminos `AutoN`;
4. opens `shutter488`, runs `Waveform_Camera_Sync_Acquisition`, and waits for
   Luminos completion;
5. appends `adaptive_optopatch_record` to `output_data.mat`, including pulse
   times, DAQ sample indices, the selected master/clock/trigger topology, the
   hardware profile, settings, target information, and expected frame mapping;
6. closes `shutter488`, writes `mod488 = 0 V`, blanks the DMD, checkpoints the
   manifest, and restores the original active Luminos waveform settings.

Live output requires checking **ARM live 488 output** for every run. OBIS power
and mod488 voltage inherit their active/manifest values unless their override
checkboxes are selected. **Stop after current** lets the current acquisition
finish and clean up normally; Luminos remains the emergency-abort interface.

Programmatic use is also available:

```matlab
run = adaptive_optopatch.run_manifest(manifest, targets, ...
    "App", luminosApp, ...
    "Live", true, ...
    "ConfirmLiveOutput", true, ...
    "OutputDirectory", planningBundleFolder);
```

The live path is implemented but has not yet been validated with light on the
VU. The first run should therefore use a low OBIS setpoint, a low mod488 command,
one trial (`Run next trial`), and a nonbiological fluorescent target. Staged 2P
tests use the separate guarded runner described below.

## Camera 1 / galvo calibration

Start Luminos, load a waveform protocol, select `Internal Dev1` and
self-trigger, and ensure the combined DAQ is idle. Then run:

```matlab
addpath("D:\path\to\adaptive_optopatch")
calibrationGui = launch_galvo_calibration_gui(luminosApp);
```

The tool finds Camera 1 by serial number `001125` and proposes a 768-by-768,
bin-1 ROI centered on its current ROI. First perform a no-light test:

1. Mechanically block the 2P beam.
2. Leave **Pockels (V)** at `0`.
3. Keep the initial 3-by-3, +/-0.1 V grid.
4. Click **Preview trajectory**.
5. Check **Blocked trajectory reviewed**.
6. Click **Acquire grid**.

This run is expected to fail spot detection; it tests synchronization, bounded
galvo motion, Camera 1 acquisition, cleanup, and setting restoration.

For illuminated calibration, use a uniform fluorescent sample and strong
attenuation. Enter a low tested Pockels voltage, check
**ARM attenuated calibration light**, and acquire again. The table contains
absolute Camera 1 sensor coordinates. Uncheck bad points or edit their
centroids, then click **Refit edited points**. Apply only a result that passes
both fit RMSE and leave-one-point-out RMSE; **Apply accepted calibration**
installs it in the live scanner object.

The acquisition folder contains `output_data.mat`, `frames1.bin`,
`galvo_calibration_plan.mat`, and `galvo_calibration_result.mat`.
`galvo_calibration_application.mat` is added after applying a transform. These
archive the exact commands, frame assignment, averaged spot images, detections,
transform, residuals, and held-out QC.

If the moving spot was visible but too few points passed detection, update the
package and reanalyze the existing acquisition without exposing the sample
again:

```matlab
calibrationFolder = "D:\path\to\the\galvo_calibration_acquisition";
savedPlan = load(fullfile(calibrationFolder,"galvo_calibration_plan.mat"));
calibration_result = ...
    adaptive_optopatch.analyze_galvo_calibration_acquisition( ...
    calibrationFolder,savedPlan.calibration_plan);
save(fullfile(calibrationFolder,"galvo_calibration_result.mat"), ...
    "calibration_result","-v7.3");
```

The detector subtracts the median stationary image across grid positions before
finding the moving spot. Inspect `calibration_result.points`, including
`detection_snr` and `use`, before applying the result.

Applying a passing calibration also creates a versioned rig-local artifact and
an `active_galvo_calibration.mat` pointer. By default these are stored under:

```matlab
fullfile(prefdir,"AdaptiveOptopatch","Virtual_Upright")
```

On the VU, set `ADAPTIVE_OPTOPATCH_CONFIG_ROOT` to a persistent local or server
configuration directory. The package appends `Virtual_Upright` automatically:

```matlab
setenv("ADAPTIVE_OPTOPATCH_CONFIG_ROOT", ...
    "Z:\Lab\Virtual_Upright\AdaptiveOptopatchConfig")
```

Put this command in the VU MATLAB `startup.m`, or define the environment
variable permanently in Windows, so it is present after restarting MATLAB.

`launch_reference_gui(luminosApp)` reads the active pointer, validates the rig,
Camera 1 serial, scanner name/ports, transform direction, inverse mapping, and
held-out QC, and only then applies the transform to the live Luminos scanner.
A rejected artifact produces a warning and is not applied. The artifact
identity and contents are included in subsequent Luminos settings snapshots
and acquisition records.

To inspect the active calibration without changing Luminos:

```matlab
[artifact,status] = ...
    adaptive_optopatch.get_active_galvo_calibration();
```

To validate and apply it explicitly:

```matlab
status = adaptive_optopatch.load_active_galvo_calibration(luminosApp)
```

Check `status.found`, `status.applied`, `status.calibration_id`, and
`status.artifact_path`.

Camera 1 ROI, binning, trigger interval, and DAQ waveform settings are restored
after acquisition. Cleanup also commands `2P mod = 0 V`. The first VU run is
still an integration test: if its Camera object uses an unrecognized ROI setter,
the tool stops with `CameraRoiApiUnavailable` before starting acquisition.
If that happens, collect the live API information with:

```matlab
camera1 = luminosApp.getDevice("Camera","name","Orca Fusion");
methods(camera1)
```

Do not enable light until the blocked acquisition completes, the saved X/Y
waveforms have been inspected, `2P mod` returns to `0 V`, and the original
Camera 1 settings are restored.

### First VU calibration checklist

- [ ] Package folder added to the MATLAB path.
- [ ] `ADAPTIVE_OPTOPATCH_CONFIG_ROOT` points to the intended persistent store.
- [ ] Luminos uses the updated synchronized Dev1/Dev2 code.
- [ ] `Internal Dev1` and self-trigger are selected.
- [ ] Combined DAQ is idle before opening the calibration GUI.
- [ ] Uniform fluorescent calibration sample installed.
- [ ] Beam mechanically blocked for the first run.
- [ ] Pockels command left at `0 V` for the first run.
- [ ] Default 3-by-3, +/-0.1 V trajectory previewed.
- [ ] Blocked run completed and settings restoration confirmed.
- [ ] Illuminated run uses strong attenuation and a low tested Pockels voltage.
- [ ] Automatic detections inspected and bad points rejected or corrected.
- [ ] Direct and leave-one-out RMSE both pass.
- [ ] Accepted calibration applied and versioned artifact path recorded.
- [ ] A fresh MATLAB/Luminos session successfully reloads the active artifact.

## Staged 2P acquisition runner

After saving a `2p_spiral` planning bundle and applying a passing Camera 1/galvo
calibration, open the staged runner:

```matlab
runner = launch_2p_test_runner_gui( ...
    luminosApp, ...
    "Z:\path\to\adaptive_optopatch_fov_YYYYMMDD_HHMMSS");
```

The runner uses the first non-null cell in the planning bundle and automatically
truncates its connectivity-screen schedule to the requested 1–10 test pulses.
It does not modify the saved planning bundle.

For the first target acquisition:

1. Mechanically block the 2P beam.
2. Select `blocked_test`.
3. Leave **Test pulses** at `1`.
4. Leave **Pockels (V)** at `0`.
5. Click **Validate + preview** and inspect X, Y, and Pockels traces.
6. Arrange an oscilloscope measurement or include `Dev2/ai1` and `Dev2/ai2`
   in the active Luminos protocol for feedback recording.
7. Check **Blocked trajectory reviewed**.
8. Click **Run one test acquisition**.

`blocked_test` forces every Pockels sample to `0 V`, regardless of the planning
bundle or voltage field. It runs exactly one target acquisition.

After inspecting the blocked run, use a strongly attenuated fluorescent sample:

1. Select `attenuated_test`.
2. Use one pulse initially.
3. Enter a low tested positive Pockels voltage.
4. Preview the exact waveforms.
5. Check both **Blocked trajectory reviewed** and
   **ARM attenuated 2P output**.
6. Run one acquisition and confirm that the illuminated spiral lands at the
   selected Camera 1 target.

Attenuated mode is limited to one target and at most ten pulses. Full
`experimental` manifests are not exposed in this GUI; they require a separate
galvo hardware-validation record.

Each successful test folder contains:

- the normal Luminos camera files and `output_data.mat`;
- `adaptive_optopatch_2p_waveforms.mat`, containing the exact X/Y/Pockels
  sample vectors actually sent to the waveform builder;
- `adaptive_optopatch_record` appended to `output_data.mat`, containing the
  release level, active calibration artifact, DAQ synchronization state,
  parking voltage, waveform summary, and expected Camera 1 frame mapping.

On completion or error, cleanup commands `2P mod = 0 V`, restores the previous
Luminos waveform and camera frame settings, and resets active DAQ tasks after an
abort. A normal waveform ends at the selected dark parking point. An emergency
abort may necessarily stop the DAQ immediately rather than completing the
planned smooth return.

### Windows/R2023b installation check

The package uses platform-independent `fullfile` paths and contains no compiled
code; Luminos continues to supply its locally installed Windows MEX files and
hardware drivers. The package requires MATLAB and Image Processing Toolbox.
The full automated test suite is compatible with releases older and newer than
R2023b.

After adding the server folder to the VU MATLAB path, run the read-only checker
before enabling light:

```matlab
addpath('Z:\path\to\adaptive_optopatch')

report = verify_vu_setup( ...
    luminosApp, ...
    'Z:\path\to\adaptive_optopatch_fov_YYYYMMDD_HHMMSS');
```

Every live-related row should report `PASS`. The checker does not write a DMD
pattern, open a shutter, start the laser, or launch an acquisition. It verifies
the MATLAB release, Windows platform, toolbox and package paths, Luminos API,
live devices, DMD calibration, OBIS mode/interlock, Camera 1 HSYNC timing, and
the selected planning bundle.
