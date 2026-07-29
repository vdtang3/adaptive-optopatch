# Adaptive Optopatch

First-pass MATLAB package for planning one-neuron-per-acquisition Optopatch
screens alongside Luminos. It keeps neuron definitions in voltage-camera
coordinates and supports two interchangeable stimulation backends:

- `1p_dmd`: logical soma masks transformed by Luminos through `DMD_Blue`.
- `2p_spiral`: soma centers and radii passed to the Luminos scanning device.

The package does not start acquisitions or write to a rig unless an explicit
adapter call is made. Scanner and DMD calibration remain the responsibility of
the live Luminos instance.

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

This writes a resumable `run_checkpoint.mat`. Live 2P mode remains locked until
a valid camera/galvo calibration and a commanded-versus-feedback recording are
available.

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
one trial (`Run next trial`), and a nonbiological fluorescent target. Live 2P
execution remains locked pending its separate timing and calibration work.

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
