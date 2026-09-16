/* DEVELOPMENT ONLY - an in-memory stand-in for AdaptiveOptopatchController.
 *
 * WHAT THIS IS
 * Enough of an Adaptive Optopatch session for the REAL React tab to be driven
 * through the REAL relay on a machine with no MATLAB: it holds one state
 * snapshot, answers the same actions adaptive_optopatch.apply_controller_action
 * answers, applies the same staleness rule, bumps a revision, and replies with
 * the same envelope.
 *
 * WHAT THIS IS EMPHATICALLY NOT
 * Adaptive Optopatch semantics. Nothing decided here is authoritative about
 * anything. Cell identity, QC, eligibility, protocol validity, plan legality,
 * freezing and execution are all MATLAB's, and what this file does with them is
 * a plausible-looking imitation chosen so that the frontend has something to
 * render and something to click. Where it is wrong, the frontend is still being
 * exercised correctly; where the frontend would be wrong, only MATLAB can say
 * so. That is what tests/TestAdaptiveOptopatchActions.m is for.
 *
 * This file is never imported by production React. The tab talks to whichever
 * endpoint answers; it does not know this exists.
 */

/* The allowlist, mirroring action_names() in
 * +adaptive_optopatch/apply_controller_action.m. Written out rather than
 * inferred, so that an action added there and not thought about here shows up
 * as an unknown_action in the browser instead of silently doing nothing. */
export const ACTIONS = [
  "load_reference_choice",
  "load_snapshot_choice",
  "save_fov",
  "set_cell_eligibility",
  "set_cell_blue_voltage",
  "add_soma",
  "update_soma",
  "delete_soma",
  "load_protocol_choice",
  "set_plan_parameter",
  "freeze_run",
  "start_new_run",
  "return_to_editing",
  "start_new_batch",
  "run_next",
  "run_all",
  "stop_after_current",
];

// Stop is the one action a running session accepts, and the one exempt from
// the revision check - for the reason the MATLAB dispatcher gives: a run bumps
// the revision continuously, so a caller's revision is stale exactly when
// stopping matters.
const STOP = "stop_after_current";

const clone = (value) => JSON.parse(JSON.stringify(value));

/* Polygon area by the shoelace formula, and the mean of the vertices as a
 * stand-in centroid. MATLAB rasterises the polygon and measures the mask; this
 * does not, and the numbers will differ slightly. They exist so the cell table
 * has something to show that changes when a polygon is redrawn. */
const polygonArea = (vertices) => {
  let sum = 0;
  for (let i = 0; i < vertices.length; i += 1) {
    const [x1, y1] = vertices[i];
    const [x2, y2] = vertices[(i + 1) % vertices.length];
    sum += x1 * y2 - x2 * y1;
  }
  return Math.round(Math.abs(sum) / 2);
};

const centroid = (vertices) => [
  vertices.reduce((total, v) => total + v[0], 0) / vertices.length,
  vertices.reduce((total, v) => total + v[1], 0) / vertices.length,
];

const edgeDistance = (vertices, imageSize) => {
  const [rows, columns] = imageSize;
  const xs = vertices.map((v) => v[0]);
  const ys = vertices.map((v) => v[1]);
  return Math.round(
    Math.min(
      Math.min(...xs) - 1,
      columns - Math.max(...xs),
      Math.min(...ys) - 1,
      rows - Math.max(...ys)
    )
  );
};

export class FakeAoSession {
  /**
   * @param {object|null} state a getState() snapshot fixture, or null for a
   *   session with no controller at all.
   * @param {object[]} protocolChoices a protocolChoices() fixture.
   */
  /**
   * @param {object|null} state a getState() snapshot fixture, or null for a
   *   session with no controller at all.
   * @param {object[]} protocolChoices a protocolChoices() fixture.
   * @param {object} snapshots a snapshotChoices() fixture plus, per choice,
   *   the FOV and reference image the real controller produced when it was
   *   loaded - so loading one here REPLAYS a real load rather than guessing
   *   what one does.
   */
  constructor(state, protocolChoices = [], snapshots = {}) {
    this.state = state ? clone(state) : null;
    this.protocolChoices = clone(protocolChoices);
    this.snapshotChoices = clone(snapshots.choices ?? []);
    this.snapshotLoads = clone(snapshots.loads ?? []);
    /* Saved FOV bundles, in memory only.
     *
     * Nothing is written to disk - this server never touches the
     * filesystem - so a "bundle" here is the slice of state a save would
     * have persisted, kept so that saving in the browser adds an entry to
     * the chooser and loading it back restores the cells. The NAMING is
     * real: <snapshot>_FOV###, next unused number, never replacing one, the
     * same rule next_fov_bundle_path applies. What a bundle CONTAINS is an
     * imitation; the schema is MATLAB's and is tested there. */
    this.savedFovs = [];
    this.markCurrentProtocol();
    this.markCurrentSnapshot();
  }

  /** The snapshot the state endpoint answers with. */
  current() {
    return this.state ? clone(this.state) : null;
  }

  /** The listing the protocol-choices endpoint answers with. */
  choices() {
    return clone(this.protocolChoices);
  }

  /** The listing the snapshot-choices endpoint answers with. */
  snapshots() {
    return clone(this.snapshotChoices);
  }

  /* The unified listing the reference-choices endpoint answers with.
   *
   * Built from the snapshot fixture plus whatever has been saved in this
   * session, grouped the way list_reference_choices groups it: each
   * snapshot followed by the FOVs saved from it. */
  references() {
    const entries = [];
    this.snapshotChoices.forEach((choice, index) => {
      entries.push({
        choice_id: choice.choice_id,
        kind: "snapshot",
        label: choice.name,
        name: choice.name,
        folder: choice.folder,
        path: choice.path,
        loadable: choice.loadable,
        issue: choice.issue,
        reference_id: choice.name,
        fov_number: null,
        fov_id: "",
        cell_count: null,
        recording_enabled_count: null,
        stimulation_enabled_count: null,
        calibrated_cell_count: null,
        camera_name: choice.camera_name,
        camera_bin: choice.camera_bin,
        image_size: choice.image_size,
        roi_origin_xy: choice.roi_origin_xy,
        roi_size_xy: choice.roi_size_xy,
        source_snapshot: "",
        timestamp: choice.timestamp,
        group_index: index + 1,
        is_current: false,
      });
      this.savedFovs
        .filter((saved) => saved.reference_id === choice.name)
        .forEach((saved) => entries.push({ ...clone(saved.choice), group_index: index + 1 }));
    });
    const currentPath = this.state?.fov?.source_path ?? "";
    for (const entry of entries) {
      entry.is_current = !!currentPath && entry.path === currentPath;
    }
    return entries;
  }

  /* The reference image for whatever FOV is currently loaded, or null.
   *
   * Keyed off the state's own fov_id rather than remembered separately, so
   * the pixels and the announced image_size cannot drift apart - which is
   * the one thing a frontend decoding this cannot recover from. */
  referenceImageFor(fovId) {
    const entry = this.snapshotLoads.find((load) => load.choice_id === fovId);
    return entry ? entry.pixels : null;
  }

  /* An imitation of controller.spatialPreview, for the overlay to draw.
   *
   * THE SHAPE IS REAL AND THE GEOMETRY IS NOT. The payload matches what the
   * endpoint returns - kinds, coordinate space, outline rings, spiral path
   * and parking point - so the canvas layer, the mode switching and the
   * staleness rule can all be exercised. What the numbers MEAN is invented:
   * the "Blue mask" outline here is the canonical polygon itself rather
   * than one apply_blue_mask_adjustment eroded, the "Orange" outline is
   * that polygon scaled about its centroid rather than one imdilate
   * expanded, and the spiral is an analytic curve rather than the Fermat
   * spiral Luminos scans. Do not read any of it as Adaptive Optopatch
   * geometry; the real thing is computed by MATLAB and tested there. */
  spatialPreview(mode) {
    const base = {
      schema_version: "1.0.0",
      mode,
      available: false,
      message: "",
      source: "",
      coordinate_space: "snapshot_intrinsic_pixels",
      image_size: this.state?.fov?.image_size ?? [0, 0],
      reference_revision: this.state?.fov?.reference_revision ?? 0,
      revision: this.state?.revision ?? 0,
      scanner_warning: "",
      blue: [],
      orange: [],
      spiral: [],
    };
    if (!this.state) return null;
    if (!this.state.fov.loaded) {
      return { ...base, message: "Load a reference FOV to preview targeting." };
    }
    if (this.state.cells.length === 0) {
      return { ...base, message: "Draw at least one soma to preview targeting." };
    }

    const preview = {
      ...base,
      available: true,
      source: this.state.protocol.loaded ? "resolved_plan" : "bundle_default",
    };
    const adjustment =
      Number(this.state.plan_parameters?.blue_mask_adjustment_pixels ?? -1);
    const expansion =
      Number(this.state.plan_parameters?.orange_expansion_pixels ?? 2);
    const radiusUm = Number(this.state.plan_parameters?.spiral_radius_um ?? 6);
    const perPixel = Number(this.state.plan_parameters?.microns_per_pixel ?? 0.35);
    const density =
      Number(this.state.plan_parameters?.spiral_density_points_per_volt ?? 10);

    this.state.cells.forEach((cell, index) => {
      const ring = this.state.soma_polygons[index] ?? [];
      if (ring.length < 3) return;
      const centre = centroid(ring);
      const scaled = (factor) =>
        ring.map(([x, y]) => [
          centre[0] + (x - centre[0]) * factor,
          centre[1] + (y - centre[1]) * factor,
        ]);
      preview.orange.push({
        cell_id: cell.cell_id,
        rings: [scaled(1 + expansion / 10)],
        pixel_count: cell.area_pixels,
        adjustment_pixels: null,
        expansion_pixels: expansion,
      });
      if (mode === "1p_dmd") {
        preview.blue.push({
          cell_id: cell.cell_id,
          rings: [scaled(1 + adjustment / 10)],
          pixel_count: cell.area_pixels,
          adjustment_pixels: adjustment,
          expansion_pixels: null,
        });
      } else {
        const radius = radiusUm / (perPixel || 0.35);
        const path = [];
        const turns = Math.max(2, Math.round(density));
        for (let k = 0; k <= 200; k += 1) {
          const t = k / 200;
          const theta = t * turns * 2 * Math.PI;
          path.push([
            centre[0] + radius * t * Math.cos(theta),
            centre[1] + radius * t * Math.sin(theta),
          ]);
        }
        preview.spiral.push({
          cell_id: cell.cell_id,
          center_xy: centre,
          radius_pixels: radius,
          density_points_per_volt: density,
          parking_xy: [centre[0] + 2.5 * radius, centre[1] + 2.5 * radius],
          pulse_duration_ms: 5,
          path_xy: path,
          cycle_metrics: { calibrated: false },
        });
      }
    });
    return preview;
  }

  /* An imitation of controller.waveformPreview, for the plot to draw.
   *
   * Again the SHAPE is real and the CONTENT is not. The channels, the event
   * list, the per-target counts and the decimation fields are what the
   * endpoint returns, so the panel, its empty states and its refresh
   * triggers can be exercised; the samples are a made-up train, not a
   * resolved pulse schedule. Nothing here resolves a protocol, and no
   * command voltage in it means anything. */
  waveformPreview() {
    if (!this.state) return null;
    const base = {
      schema_version: "1.0.0",
      available: false,
      message: "",
      mode: this.state.plan_parameters?.stimulation_mode ?? "2p_spiral",
      revision: this.state.revision,
      acquisition_id: "",
      protocol_id: "",
      duration_s: null,
      sample_rate_hz: null,
      decimation_step: 1,
      truncated: false,
      window_s: [0, 0],
      time_s: [],
      channels: [],
      events: [],
      targets: [],
    };
    if (!this.state.protocol.loaded) {
      return { ...base, message: "Load a pulse protocol to preview waveforms." };
    }
    if (!this.state.fov.loaded || this.state.cells.length === 0) {
      return {
        ...base,
        message:
          "A reference FOV with at least one soma is needed before a " +
          "waveform can be resolved.",
      };
    }

    const stimulated = this.state.cells.filter((c) => c.stimulation_enabled);
    const targets = stimulated.length > 0 ? stimulated : this.state.cells;
    const pulseCount = Math.max(1, Math.min(20, targets.length * 3));
    const pulseS = 0.005;
    const gapS = 0.05;
    const events = [];
    for (let k = 0; k < pulseCount; k += 1) {
      const onset = 0.1 + k * (pulseS + gapS);
      events.push({
        cell_id: targets[k % targets.length].cell_id,
        onset_s: onset,
        offset_s: onset + pulseS,
        command_voltage_v: 1.2,
        is_null: false,
      });
    }
    const duration = events[events.length - 1].offset_s + 0.1;

    const time = [];
    const command = [];
    for (const event of events) {
      time.push(event.onset_s, event.onset_s, event.offset_s, event.offset_s);
      command.push(0, event.command_voltage_v, event.command_voltage_v, 0);
    }

    const perTarget = new Map();
    for (const event of events) {
      perTarget.set(event.cell_id, (perTarget.get(event.cell_id) ?? 0) + 1);
    }

    return {
      ...base,
      available: true,
      acquisition_id: "dev_acquisition_001",
      protocol_id: String(this.state.protocol.summary?.protocol_id ?? ""),
      duration_s: duration,
      window_s: [0, duration],
      time_s: time,
      channels: [
        { name: "mod488", units: "V", kind: "analog", values: command },
      ],
      events,
      targets: [...perTarget].map(([cell_id, event_count]) => ({
        cell_id,
        event_count,
      })),
    };
  }

  /* One action, with the same outcomes the MATLAB dispatcher produces:
   * unknown_action, not_legal, stale_revision, validation_error, applied -
   * each carrying the state afterwards, unchanged when the action was
   * refused. */
  apply(action, payload = {}, expectedRevision = null) {
    if (!this.state) {
      return this.envelope(action, false, "no_controller", expectedRevision,
        "This development session has no Adaptive Optopatch controller.");
    }

    if (!ACTIONS.includes(action)) {
      return this.envelope(action, false, "unknown_action", expectedRevision,
        `Adaptive Optopatch does not offer an action called '${action}'.`);
    }

    if (action === STOP) {
      if (!this.state.legal_actions.stop_after_current) {
        return this.envelope(action, false, "not_legal", expectedRevision,
          "No acquisition is running, or a stop has already been requested.");
      }
    } else {
      if (this.state.plan_state === "RUNNING") {
        return this.envelope(action, false, "not_legal", expectedRevision,
          "An acquisition is active. Only stop_after_current is available " +
            "until it finishes.");
      }
      if (
        typeof expectedRevision !== "number" ||
        !Number.isFinite(expectedRevision) ||
        expectedRevision !== this.state.revision
      ) {
        return this.envelope(action, false, "stale_revision", expectedRevision,
          `The session has changed since this was requested (revision ` +
            `${expectedRevision}, now ${this.state.revision}). Nothing was ` +
            `changed; the current state is shown instead.`);
      }
    }

    try {
      this.run(action, payload ?? {});
    } catch (error) {
      return this.envelope(action, false, error.status ?? "validation_error",
        expectedRevision, error.message);
    }

    this.state.revision += 1;
    this.refreshDerivedState();
    return this.envelope(action, true, "applied", expectedRevision, "");
  }

  // -----------------------------------------------------------------------
  // The actions
  // -----------------------------------------------------------------------

  run(action, payload) {
    switch (action) {
      case "set_cell_eligibility":
        return this.setCellEligibility(payload);
      case "add_soma":
        return this.addSoma(payload);
      case "update_soma":
        return this.updateSoma(payload);
      case "delete_soma":
        return this.deleteSoma(payload);
      case "load_snapshot_choice":
        return this.loadSnapshotChoice(payload);
      case "load_reference_choice":
        return this.loadReferenceChoice(payload);
      case "save_fov":
        return this.saveFov();
      case "set_cell_blue_voltage":
        return this.setCellBlueVoltage(payload);
      case "load_protocol_choice":
        return this.loadProtocolChoice(payload);
      case "set_plan_parameter":
        return this.setPlanParameter(payload);
      case "freeze_run":
      case "start_new_run":
        return this.freeze();
      case "return_to_editing":
        return this.returnToEditing();
      case "start_new_batch":
        return this.startNewBatch();
      case "run_next":
        return this.advanceRun(1);
      case "run_all":
        return this.advanceRun(Infinity);
      case "stop_after_current":
        this.state.stop_after_current_requested = true;
        return undefined;
      default:
        throw this.refuse(`'${action}' is allowlisted but not implemented.`);
    }
  }

  setCellEligibility({ cell_id, recording_enabled, stimulation_enabled }) {
    const cell = this.cell(cell_id);
    if (recording_enabled != null) cell.recording_enabled = !!recording_enabled;
    if (stimulation_enabled != null) {
      cell.stimulation_enabled = !!stimulation_enabled;
    }
  }

  addSoma({ vertices_xy }) {
    const vertices = this.vertices(vertices_xy);
    const id = `cell_${String(this.state.fov.next_cell_index).padStart(3, "0")}`;
    this.state.soma_polygons.push(vertices);
    this.state.cells.push({
      cell_id: id,
      recording_enabled: true,
      stimulation_enabled: true,
      selected_blue_voltage_v: null,
      vertex_count: vertices.length,
      ...this.geometry(vertices),
    });
    this.state.fov.next_cell_index += 1;
    this.markEditableChanged();
  }

  updateSoma({ cell_id, vertices_xy }) {
    const vertices = this.vertices(vertices_xy);
    const index = this.cellIndex(cell_id);
    this.state.soma_polygons[index] = vertices;
    Object.assign(this.state.cells[index], {
      vertex_count: vertices.length,
      ...this.geometry(vertices),
    });
    this.markEditableChanged();
  }

  deleteSoma({ cell_id }) {
    const index = this.cellIndex(cell_id);
    this.state.cells.splice(index, 1);
    this.state.soma_polygons.splice(index, 1);
    // next_cell_index is deliberately NOT decremented: a deleted identity is
    // retired, never recycled, which is what MATLAB does.
    this.markEditableChanged();
  }

  /* Replay the load the real controller performed for this snapshot.
   *
   * The FOV comes from the fixture, not from anything computed here: camera
   * identity, crop origin, binning and image size are read out of the
   * snapshot file by MATLAB, and a stub that invented them would let a
   * frontend bug that mishandles a cropped frame pass unnoticed.
   *
   * Adopting a reference CLEARS cell geometry in the controller - vertices
   * are indices into a particular frame - so it clears it here too. */
  loadSnapshotChoice({ choice_id }) {
    const choice = this.snapshotChoices.find((c) => c.choice_id === choice_id);
    if (!choice) {
      throw this.refuse(
        `No camera snapshot is offered as '${choice_id}'. Refresh the ` +
          `snapshot list and choose again.`
      );
    }
    if (!choice.loadable) {
      throw this.refuse(choice.issue || `${choice_id} could not be loaded.`);
    }
    const load = this.snapshotLoads.find((l) => l.choice_id === choice_id);
    if (!load) {
      throw this.refuse(`No development image was captured for ${choice_id}.`);
    }

    const previousReference = this.state.fov.reference_revision ?? 0;
    this.state.fov = {
      ...clone(load.fov),
      reference_revision: previousReference + 1,
      source_kind: "snapshot",
      source_path: choice.path,
    };
    this.state.cells = [];
    this.state.soma_polygons = [];
    this.state.status = [
      `Loaded snapshot: ${load.fov.snapshot_path}`,
      `Camera: ${load.fov.camera_name}, ${load.fov.image_size[1]} × ` +
        `${load.fov.image_size[0]} pixels, binning ${load.fov.camera_bin}.`,
    ];
    this.markCurrentSnapshot();
    this.markEditableChanged();
  }

  /* Load one entry of the unified chooser, dispatching on its kind.
   *
   * The dispatch is the point: a snapshot starts a FRESH FOV, and a saved
   * FOV RESTORES cells. MATLAB decides which from the listing it produced,
   * and so does this - never from the shape of the id. */
  loadReferenceChoice({ choice_id }) {
    const entry = this.references().find((c) => c.choice_id === choice_id);
    if (!entry) {
      throw this.refuse(
        `No reference is offered as '${choice_id}'. Refresh the list and ` +
          `choose again.`
      );
    }
    if (!entry.loadable) {
      throw this.refuse(entry.issue || `${choice_id} could not be loaded.`);
    }
    if (entry.kind === "snapshot") {
      this.loadSnapshotChoice({ choice_id });
      return;
    }
    this.restoreFov(choice_id);
  }

  /* Restore a bundle saved earlier in this session.
   *
   * Cells, their identities, their decisions and their Blue calibration all
   * come back, which is the difference from loading the snapshot. */
  restoreFov(choiceId) {
    const saved = this.savedFovs.find((s) => s.choice.choice_id === choiceId);
    if (!saved) throw this.refuse(`No saved FOV called ${choiceId}.`);
    const previousReference = this.state.fov.reference_revision ?? 0;
    this.state.fov = {
      ...clone(saved.fov),
      reference_revision: previousReference + 1,
      source_kind: "ao_fov",
      source_path: saved.choice.path,
    };
    this.state.cells = clone(saved.cells);
    this.state.soma_polygons = clone(saved.soma_polygons);
    this.state.plan_parameters = clone(saved.plan_parameters);
    this.state.status = [
      `Loaded persistent FOV ${saved.choice.fov_id} with ` +
        `${saved.cells.length} stable cells.`,
    ];
    this.markEditableChanged();
  }

  /* Save the current FOV as the next unused numbered bundle.
   *
   * The NUMBERING rule is the real one: one past the highest already
   * present for this snapshot, never replacing an existing bundle and never
   * touching the snapshot itself. Nothing is written to disk. */
  saveFov() {
    if (!this.state.fov.loaded) {
      throw this.notLegal("Load a reference FOV before saving one.");
    }
    const referenceId = this.referenceIdOfLoadedFov();
    const highest = this.savedFovs
      .filter((saved) => saved.reference_id === referenceId)
      .reduce((best, saved) => Math.max(best, saved.choice.fov_number), 0);
    const number = highest + 1;
    const name = `${referenceId}_FOV${String(number).padStart(3, "0")}`;
    const folder = this.state.fov.snapshot_directory || "<dev fixture>";
    const stimulated = this.state.cells.filter((c) => c.stimulation_enabled);
    const recorded = this.state.cells.filter((c) => c.recording_enabled);
    const calibrated = this.state.cells.filter(
      (c) => typeof c.selected_blue_voltage_v === "number"
    );
    const choice = {
      choice_id: name,
      kind: "ao_fov",
      label: `${referenceId} — FOV ${String(number).padStart(3, "0")}`,
      name,
      folder,
      path: `${folder}/${name}.mat`,
      loadable: true,
      issue: "",
      reference_id: referenceId,
      fov_number: number,
      fov_id: this.state.fov.fov_id,
      cell_count: this.state.cells.length,
      recording_enabled_count: recorded.length,
      stimulation_enabled_count: stimulated.length,
      calibrated_cell_count: calibrated.length,
      camera_name: this.state.fov.camera_name,
      camera_bin: this.state.fov.camera_bin,
      image_size: this.state.fov.image_size,
      roi_origin_xy: this.state.fov.roi_origin_xy,
      roi_size_xy: this.state.fov.roi_origin_xy,
      source_snapshot: this.state.fov.snapshot_path,
      timestamp: new Date().toISOString().slice(0, 19).replace("T", " "),
      group_index: null,
      is_current: true,
    };
    this.savedFovs.push({
      reference_id: referenceId,
      choice,
      fov: clone(this.state.fov),
      cells: clone(this.state.cells),
      soma_polygons: clone(this.state.soma_polygons),
      plan_parameters: clone(this.state.plan_parameters),
    });
    this.state.fov.source_kind = "ao_fov";
    this.state.fov.source_path = choice.path;
    this.state.status = [
      `Saved FOV ${choice.fov_id} with ${this.state.cells.length} cells to`,
      choice.path,
    ];
  }

  /* Which snapshot the loaded FOV descends from.
   *
   * Taken from the snapshot the reference came from, not from whatever file
   * was last loaded, so a FOV saved from snap_FOV001 becomes snap_FOV002
   * rather than snap_FOV001_FOV001 - the same rule fovBundleIdentity
   * applies in MATLAB. */
  referenceIdOfLoadedFov() {
    const path = this.state.fov.snapshot_path ?? "";
    const stem = path.split(/[\\/]/).pop() ?? "";
    return stem.replace(/\.mat$/i, "") || this.state.fov.fov_id || "reference";
  }

  /* The stored per-cell 488 nm calibration, with the controller's own range.
   *
   * A CALIBRATION, not a command source: nothing here or in MATLAB lets
   * this override a protocol that names a command voltage. */
  setCellBlueVoltage({ cell_id, voltage_v }) {
    const cell = this.cell(cell_id);
    const voltage = Number(voltage_v);
    if (!Number.isFinite(voltage) || voltage <= 0 || voltage > 5) {
      throw this.refuse("Blue V (1P) must be a finite number in (0,5] V.");
    }
    cell.selected_blue_voltage_v = voltage;
  }

  loadProtocolChoice({ choice_id }) {
    const choice = this.protocolChoices.find((c) => c.choice_id === choice_id);
    if (!choice) {
      throw this.refuse(
        `No pulse protocol is offered as '${choice_id}'. Refresh the ` +
          `protocol list and choose again.`
      );
    }
    if (!choice.loadable) {
      throw this.refuse(choice.issue || `${choice_id} could not be loaded.`);
    }
    this.state.protocol = {
      loaded: true,
      path: choice.path,
      summary: {
        schema_version: "3.0.0",
        protocol_id: choice.protocol_id,
        protocol_type: choice.protocol_type,
        target_policy: choice.target_policy,
        event_order: choice.event_order,
        definition_acquisition_count: choice.acquisition_count,
        event_count: choice.event_count,
        light_event_count: choice.event_count,
        condition_count: 1,
        duration_range_s: [0.005, 0.005],
        random_seed: 1,
      },
    };
    this.markCurrentProtocol();
    this.markEditableChanged();
  }

  setPlanParameter({ name, value }) {
    if (!(name in (this.state.plan_parameters ?? {}))) {
      throw this.refuse(`Unknown editable plan parameter: ${name}`);
    }
    const current = this.state.plan_parameters[name];
    if (name === "stimulation_mode") {
      if (!["1p_dmd", "2p_spiral"].includes(value)) {
        throw this.refuse("Stimulation mode must be 1p_dmd or 2p_spiral.");
      }
      this.state.plan_parameters[name] = value;
    } else if (typeof current === "boolean") {
      this.state.plan_parameters[name] = !!value;
    } else {
      const number = Number(value);
      if (!Number.isFinite(number)) {
        throw this.refuse(`${name} must be a finite scalar.`);
      }
      this.state.plan_parameters[name] = number;
    }
    this.markEditableChanged();
  }

  freeze() {
    if (!this.state.fov.loaded || this.state.cells.length === 0) {
      throw this.notLegal("Load a reference FOV and draw a soma first.");
    }
    if (!this.state.protocol.loaded) {
      throw this.notLegal(
        "Load a validated pulse_protocol.mat before previewing or running."
      );
    }
    const batch = (this.state.active_run.batch_number ?? 0) + 1;
    this.state.plan_state = "FROZEN";
    this.state.editable_state_changed = false;
    this.state.active_run = {
      frozen: true,
      folder: `<dev fixture>/adaptive_optopatch_run_batch_${batch}`,
      batch_id: `dev_batch_${batch}`,
      batch_number: batch,
      trial_count: this.state.cells.filter((c) => c.stimulation_enabled).length,
      completed_trial_count: 0,
      batch_complete: false,
    };
    this.state.status = [
      "Frozen run plan created before acquisition:",
      this.state.active_run.folder,
    ];
  }

  returnToEditing() {
    if (!this.state.active_run.frozen) {
      throw this.notLegal("There is no frozen run to return from.");
    }
    this.state.plan_state = "EDITABLE";
    this.state.editable_state_changed = false;
    this.state.active_run = {
      frozen: false,
      folder: "",
      batch_id: "",
      batch_number: null,
      trial_count: 0,
      completed_trial_count: 0,
      batch_complete: false,
    };
    this.state.status = [
      "Returned to editing. Frozen run artifacts remain on disk.",
    ];
  }

  startNewBatch() {
    if (!this.state.active_run.frozen) {
      throw this.notLegal("Freeze or resume a run before starting a new batch.");
    }
    if (!this.state.active_run.batch_complete) {
      throw this.notLegal(
        "Start new batch is available only after the current batch completes."
      );
    }
    this.freeze();
  }

  /* A run that finishes instantly. The interface's job here is to show trial
   * progress and to disable the right buttons; a stub that blocked for the
   * length of a real acquisition would only make that harder to look at. The
   * real endpoint blocks for as long as the runner runs. */
  advanceRun(trials) {
    if (!this.state.active_run.frozen) this.freeze();
    const run = this.state.active_run;
    if (run.batch_complete) {
      throw this.notLegal("This batch is complete. Start a new batch.");
    }
    run.completed_trial_count = Math.min(
      run.trial_count,
      run.completed_trial_count + (trials === Infinity ? run.trial_count : trials)
    );
    run.batch_complete = run.completed_trial_count >= run.trial_count;
    this.state.stop_after_current_requested = false;
    this.state.status = [
      `Ran ${run.completed_trial_count} of ${run.trial_count} trials ` +
        `(development stub - no hardware).`,
    ];
  }

  // -----------------------------------------------------------------------
  // Derived state
  // -----------------------------------------------------------------------

  /* legal_actions and lifecycle are DERIVED in MATLAB and derived here too, so
   * that a button the stub disables is disabled for a reason the real backend
   * would also give. This mirrors legalActions() in the controller. */
  refreshDerivedState() {
    const state = this.state;
    const editing = state.plan_state !== "RUNNING";
    const hasFov = !!state.fov.loaded;
    const hasCells = state.cells.length > 0;
    const frozen = !!state.active_run.frozen;

    state.fov.cell_count = state.cells.length;
    state.lifecycle =
      state.plan_state === "FROZEN"
        ? "frozen"
        : state.plan_state === "RUNNING"
        ? state.stop_after_current_requested
          ? "stopping_after_current"
          : "running"
        : "editing";

    state.legal_actions = {
      edit_cells: editing && hasFov,
      edit_plan_parameters: editing,
      load_protocol: editing,
      load_fov: editing,
      save_fov: editing && hasFov,
      freeze_run: editing && hasFov && hasCells && !!state.protocol.loaded,
      run: editing,
      stop_after_current:
        state.plan_state === "RUNNING" && !state.stop_after_current_requested,
      return_to_editing: frozen && editing,
      start_new_batch: frozen && editing && !!state.active_run.batch_complete,
      resume_run: editing,
    };
  }

  markEditableChanged() {
    this.state.editable_state_changed = true;
    if (!this.state.active_run.frozen) this.state.plan_state = "EDITABLE";
  }

  markCurrentSnapshot() {
    const fovId = this.state?.fov?.fov_id ?? "";
    for (const choice of this.snapshotChoices) {
      choice.is_current = !!fovId && choice.choice_id === fovId;
    }
  }

  markCurrentProtocol() {
    const path = this.state?.protocol?.path ?? "";
    for (const choice of this.protocolChoices) {
      choice.is_current = !!path && choice.path === path;
    }
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  geometry(vertices) {
    return {
      area_pixels: polygonArea(vertices),
      centroid_xy: centroid(vertices),
      edge_distance_pixels: edgeDistance(vertices, this.state.fov.image_size),
      qc_status:
        edgeDistance(vertices, this.state.fov.image_size) >= 2
          ? "PASS"
          : "CHECK",
    };
  }

  vertices(value) {
    if (
      !Array.isArray(value) ||
      !value.every((v) => Array.isArray(v) && v.length === 2 &&
        v.every((n) => Number.isFinite(Number(n))))
    ) {
      throw this.refuse(
        "'vertices_xy' must be an N-by-2 list of [x y] vertices in " +
          "snapshot-intrinsic pixels."
      );
    }
    if (value.length < 3) {
      throw this.refuse(
        "A soma polygon needs at least three finite vertices."
      );
    }
    return value.map(([x, y]) => [Number(x), Number(y)]);
  }

  cellIndex(cellId) {
    const index = this.state.cells.findIndex((c) => c.cell_id === cellId);
    if (index < 0) throw this.refuse(`Unknown cell ID: ${cellId}`);
    return index;
  }

  cell(cellId) {
    return this.state.cells[this.cellIndex(cellId)];
  }

  refuse(message) {
    const error = new Error(message);
    error.status = "validation_error";
    return error;
  }

  notLegal(message) {
    const error = new Error(message);
    error.status = "not_legal";
    return error;
  }

  envelope(action, ok, status, expectedRevision, message) {
    return {
      schema_version: "1.0.0",
      ok,
      action,
      status,
      message,
      identifier: "",
      expected_revision:
        typeof expectedRevision === "number" ? expectedRevision : null,
      revision: this.state ? this.state.revision : null,
      state: this.state ? clone(this.state) : {},
    };
  }
}
