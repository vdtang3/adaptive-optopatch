/* Tests for the development AO session.
 *
 * What is being checked here is the DEVELOPMENT HARNESS, not Adaptive
 * Optopatch. The properties that matter are the ones the React tab is written
 * against and would otherwise only be discovered by clicking: that an action
 * comes back with the state after it, that a stale request changes nothing,
 * that a refusal is a result rather than a throw, and that the allowlist here
 * is the allowlist there.
 *
 * Whether any of these actions MEANS the right thing is a question for
 * adaptive-optopatch/tests/TestAdaptiveOptopatchActions.m, which asks the real
 * controller.
 *
 * Run with: npm test   (from dev/luminos-react)
 */
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { ACTIONS, FakeAoSession } from "../fake_ao_session.js";
import {
  LineFramer,
  encodeArrayReply,
  startFakeMatlabServer,
} from "../fake_matlab_server.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(HERE, "..", "fixtures");
const LOADED_FIXTURE = path.join(FIXTURES, "fake_ao_state_loaded.json");
const EMPTY_FIXTURE = path.join(FIXTURES, "fake_ao_state_empty.json");

const readJson = (file) => JSON.parse(fs.readFileSync(file, "utf8"));

const newSession = (fixture = LOADED_FIXTURE) => {
  const session = new FakeAoSession(
    readJson(fixture),
    readJson(path.join(FIXTURES, "fake_ao_protocol_choices.json")),
    readJson(path.join(FIXTURES, "fake_ao_snapshots.json"))
  );
  session.refreshDerivedState();
  return session;
};

/** One action at whatever revision the session is currently at. */
const act = (session, action, payload = {}) =>
  session.apply(action, payload, session.state.revision);

// ---------------------------------------------------------------------------
// The contract shape
// ---------------------------------------------------------------------------

test("the allowlist matches the one the MATLAB dispatcher publishes", () => {
  // Kept in step by hand, and asserted here so that drifting apart is a test
  // failure rather than an action that works in the browser and not on the rig.
  assert.deepEqual(new Set(ACTIONS), new Set([
    "load_reference_choice", "load_snapshot_choice", "save_fov",
    "set_cell_eligibility", "set_cell_blue_voltage",
    "add_soma", "update_soma", "delete_soma",
    "load_protocol_choice", "set_plan_parameter",
    "update_plan", "run", "stop_after_current",
  ]));
});

test("every reply carries the state after the action, refused or not", () => {
  const session = newSession();
  for (const response of [
    act(session, "set_cell_eligibility", { cell_id: "cell_001", recording_enabled: false }),
    act(session, "not_an_action"),
    act(session, "run"),
    session.apply("delete_soma", { cell_id: "cell_001" }, 999),
  ]) {
    assert.ok("state" in response, `${response.action} carried no state`);
    assert.equal(typeof response.state.revision, "number");
    assert.equal(response.state.revision, session.state.revision);
    assert.equal(response.revision, session.state.revision);
  }
});

test("no reply carries a field named error, which the bridge reads as a throw", () => {
  const session = newSession();
  for (const action of ["not_an_action", "run", "update_plan"]) {
    assert.ok(!("error" in act(session, action)));
  }
});

test("an action outside the allowlist is refused, however plausible", () => {
  const session = newSession();
  for (const action of ["setCellBlueVoltage", "clearSomata", "loadSnapshot", "delete"]) {
    assert.equal(act(session, action).status, "unknown_action");
  }
});

// ---------------------------------------------------------------------------
// Revisions
// ---------------------------------------------------------------------------

test("a successful action advances the revision by exactly one", () => {
  const session = newSession();
  const before = session.state.revision;
  const response = act(session, "set_plan_parameter", {
    name: "orange_expansion_pixels", value: 5,
  });
  assert.equal(response.ok, true);
  assert.equal(response.revision, before + 1);
  assert.equal(response.state.plan_parameters.orange_expansion_pixels, 5);
});

test("a stale request is refused and mutates nothing", () => {
  const session = newSession();
  const before = JSON.parse(JSON.stringify(session.current()));

  const response = session.apply("delete_soma", { cell_id: "cell_001" }, before.revision - 1);

  assert.equal(response.ok, false);
  assert.equal(response.status, "stale_revision");
  assert.deepEqual(session.current(), before);
  assert.deepEqual(response.state, before);
});

test("a request with no revision at all is refused", () => {
  const session = newSession();
  const cells = session.state.cells.length;
  assert.equal(session.apply("delete_soma", { cell_id: "cell_001" }).status, "stale_revision");
  assert.equal(session.state.cells.length, cells);
});

test("the returned revision is the one the next action should send", () => {
  const session = newSession();
  let revision = session.state.revision;
  for (let expansion = 1; expansion <= 4; expansion += 1) {
    const response = session.apply("set_plan_parameter",
      { name: "orange_expansion_pixels", value: expansion }, revision);
    assert.equal(response.ok, true, response.message);
    revision = response.revision;
  }
  assert.equal(session.state.plan_parameters.orange_expansion_pixels, 4);
});

// ---------------------------------------------------------------------------
// The workflow the tab drives
// ---------------------------------------------------------------------------

test("a drawn soma becomes a cell the session names", () => {
  const session = newSession();
  const before = session.state.fov.next_cell_index;

  const response = act(session, "add_soma", {
    vertices_xy: [[10, 10], [22, 10], [22, 22], [10, 22]],
  });

  assert.equal(response.ok, true);
  const added = response.state.cells.at(-1);
  assert.equal(added.cell_id, `cell_${String(before).padStart(3, "0")}`);
  assert.equal(response.state.fov.next_cell_index, before + 1);
  assert.deepEqual(response.state.soma_polygons.at(-1),
    [[10, 10], [22, 10], [22, 22], [10, 22]]);
});

test("a deleted soma does not renumber the survivors", () => {
  const session = newSession();
  const nextBefore = session.state.fov.next_cell_index;

  const response = act(session, "delete_soma", { cell_id: "cell_001" });

  assert.equal(response.ok, true);
  assert.ok(!response.state.cells.some((c) => c.cell_id === "cell_001"));
  assert.equal(response.state.cells[0].cell_id, "cell_002");
  assert.equal(response.state.fov.next_cell_index, nextBefore);
});

test("a polygon with fewer than three vertices is refused", () => {
  const session = newSession();
  const response = act(session, "add_soma", { vertices_xy: [[1, 1], [2, 2]] });
  assert.equal(response.status, "validation_error");
});

test("recording and stimulation eligibility move independently", () => {
  const session = newSession();
  act(session, "set_cell_eligibility", { cell_id: "cell_001", recording_enabled: false });
  const response = act(session, "set_cell_eligibility", {
    cell_id: "cell_001", stimulation_enabled: false,
  });
  assert.equal(response.state.cells[0].recording_enabled, false);
  assert.equal(response.state.cells[0].stimulation_enabled, false);
});

test("choosing a protocol by id loads it and marks it current", () => {
  const session = newSession();
  const choice = session.choices()[0];

  const response = act(session, "load_protocol_choice", { choice_id: choice.choice_id });

  assert.equal(response.ok, true);
  assert.equal(response.state.protocol.loaded, true);
  assert.equal(response.state.protocol.summary.protocol_id, choice.protocol_id);
  assert.equal(session.choices().find((c) => c.choice_id === choice.choice_id).is_current, true);
});

test("a protocol id that was never offered is refused", () => {
  const session = newSession();
  assert.equal(act(session, "load_protocol_choice", { choice_id: "/etc/passwd" }).status,
    "validation_error");
});

test("the internal lifecycle names are not actions the browser may send", () => {
  // Every one of these was an action until the workflow became
  // configure -> Update plan -> Run. They remain controller methods and
  // the MATLAB planning window still offers most of them; no endpoint
  // reaches them, so a frontend cannot freeze a plan or run one
  // acquisition even by asking for it by name.
  const session = newSession();
  for (const name of [
    "freeze_run", "start_new_run", "return_to_editing",
    "start_new_batch", "run_next", "run_all",
  ]) {
    assert.equal(act(session, name).status, "unknown_action", name);
  }
});

test("an unpreparable experiment is neither updatable nor runnable", () => {
  const session = newSession(EMPTY_FIXTURE);

  for (const action of ["update_plan", "run"]) {
    const response = act(session, action);
    assert.equal(response.status, "not_legal", action);
    assert.equal(response.identifier, "adaptive_optopatch:PlanNotReady");
    assert.equal(response.state.plan_status, "not_ready");
  }
  const readiness = session.current().plan_readiness;
  assert.equal(readiness.can_run, false);
  assert.equal(readiness.can_update_plan, false);
  assert.ok(readiness.blocking_issues.length > 0);
});

test("a describable experiment needs an update before it can run", () => {
  const session = newSession();
  // Any execution input moves the prepared fixture plan out of date.
  act(session, "set_plan_parameter", {
    name: "orange_expansion_pixels",
    value: 6,
  });

  assert.equal(session.current().plan_status, "update_required");
  assert.equal(session.current().legal_actions.run, false);
  assert.equal(session.current().legal_actions.update_plan, true);

  const refused = act(session, "run");
  assert.equal(refused.status, "not_legal");
  assert.equal(refused.identifier, "adaptive_optopatch:PlanUpdateRequired");

  const updated = act(session, "update_plan");
  assert.equal(updated.ok, true, updated.message);
  assert.equal(updated.state.plan_status, "ready");
  assert.equal(updated.state.legal_actions.run, true);
});

test("execution-affecting edits stale the plan and name what moved", () => {
  const edits = [
    ["cell_decisions", "set_cell_eligibility",
      { cell_id: "cell_001", stimulation_enabled: false }],
    ["cell_decisions", "set_cell_blue_voltage",
      { cell_id: "cell_001", voltage_v: 2.1 }],
    ["spatial", "set_plan_parameter",
      { name: "blue_mask_adjustment_pixels", value: -4 }],
    ["run_controls", "set_plan_parameter",
      { name: "repeat_batch_count", value: 3 }],
  ];

  for (const [group, action, payload] of edits) {
    const session = newSession();
    act(session, "update_plan");
    assert.equal(session.current().plan_status, "ready", group);

    act(session, action, payload);

    assert.equal(session.current().plan_status, "update_required", group);
    assert.deepEqual(session.current().plan_readiness.stale_inputs, [group]);
    assert.equal(act(session, "run").status, "not_legal", group);
  }
});

test("read-only operations leave a ready plan ready", () => {
  // The distinction the whole design rests on: the revision advances for
  // these, and the plan is still the right one.
  const session = newSession();
  act(session, "update_plan");
  const revision = session.state.revision;

  session.current();
  session.references();
  session.snapshots();
  session.choices();
  session.spatialPreview("1p_dmd");
  session.spatialPreview("2p_spiral");
  session.waveformPreview();
  act(session, "save_fov");

  assert.ok(session.state.revision > revision, "the revision did advance");
  assert.equal(session.current().plan_status, "ready");
  assert.deepEqual(session.current().plan_readiness.stale_inputs, []);
});

test("the summary counts acquisitions, repeats and cells separately", () => {
  const session = newSession();
  act(session, "set_plan_parameter", { name: "repeat_batch_count", value: 3 });
  act(session, "update_plan");

  const summary = session.current().plan_summary;
  const stimulating = session.current().cells.filter(
    (cell) => cell.stimulation_enabled
  );
  assert.equal(summary.prepared, true);
  assert.equal(summary.stimulating_cell_count, stimulating.length);
  assert.equal(summary.repeats, 3);
  assert.equal(
    summary.total_acquisitions,
    summary.acquisitions_per_repeat * summary.repeats
  );
  // An event is not an acquisition: the counts are reported separately and
  // the frontend must never derive one from the other.
  assert.ok("light_event_count" in summary);
});

test("deselecting Stim changes the authoritative plan once it is updated", () => {
  const session = newSession();
  act(session, "update_plan");
  const before = session.current().plan_summary.acquisitions_per_repeat;

  act(session, "set_cell_eligibility", {
    cell_id: session.current().cells.find((c) => c.stimulation_enabled).cell_id,
    stimulation_enabled: false,
  });
  act(session, "update_plan");

  const after = session.current().plan_summary;
  assert.equal(after.acquisitions_per_repeat, before - 1);
  assert.equal(after.stimulating_cell_count, before - 1);
});

test("Run executes the whole plan and leaves it reusable", () => {
  const session = newSession();
  act(session, "update_plan");
  const total = session.current().plan_summary.total_acquisitions;

  const run = act(session, "run");

  assert.equal(run.ok, true, run.message);
  assert.equal(run.state.run_progress.completed_acquisitions, total);
  assert.equal(run.state.run_progress.total_acquisitions, total);
  // Nothing changed, so the plan is still the right one and Run is offered.
  assert.equal(run.state.plan_status, "ready");
  assert.equal(run.state.legal_actions.run, true);
  assert.equal(act(session, "run").ok, true, "Run may be pressed again");
});

test("legal_actions is recomputed, not carried over from the fixture", () => {
  const session = newSession();
  assert.equal(session.current().legal_actions.update_plan, true);

  // Removing every soma removes the thing a plan needs.
  for (const cell of [...session.state.cells]) {
    act(session, "delete_soma", { cell_id: cell.cell_id });
  }

  assert.equal(session.current().plan_status, "not_ready");
  assert.equal(session.current().legal_actions.update_plan, false);
  assert.equal(session.current().legal_actions.run, false);
  assert.equal(act(session, "update_plan").status, "not_legal");
});

// ---------------------------------------------------------------------------
// Framing of the image reply
// ---------------------------------------------------------------------------

test("a large array is framed as metadata plus raw bytes, as JS_Server does", () => {
  const values = Array.from({ length: 8 }, (_, i) => i * 17);
  const frame = encodeArrayReply("ev1", values, "uint8");
  const newline = frame.indexOf(10);
  const metadata = JSON.parse(frame.slice(0, newline).toString("utf8"));

  assert.deepEqual(metadata, { event: "ev1", arrLength: 8, arrClass: "uint8" });
  assert.deepEqual([...frame.slice(newline + 1)], values);
});

/** Read one binary-framed reply off a socket: header line, then arrLength bytes. */
const readArrayReply = (socket) =>
  new Promise((resolve) => {
    let buffer = Buffer.alloc(0);
    const onData = (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      const newline = buffer.indexOf(10);
      if (newline < 0) return;
      const metadata = JSON.parse(buffer.slice(0, newline).toString("utf8"));
      if (buffer.length - newline - 1 < metadata.arrLength) return;
      socket.off("data", onData);
      resolve({
        metadata,
        bytes: [...buffer.slice(newline + 1, newline + 1 + metadata.arrLength)],
      });
    };
    socket.on("data", onData);
  });

const withSocket = async (fixturePath, body) => {
  const running = startFakeMatlabServer({ port: 0, fixturePath, log: () => {} });
  await new Promise((resolve) => running.server.once("listening", resolve));
  const socket = net.createConnection(running.server.address().port, "127.0.0.1");
  await new Promise((resolve) => socket.once("connect", resolve));
  try {
    await body({ socket, session: running.session });
  } finally {
    socket.destroy();
    await running.close();
  }
};

test("the reference image arrives as the flat uint8 list the endpoint returns", () =>
  withSocket(LOADED_FIXTURE, async ({ socket }) => {
    const state = readJson(LOADED_FIXTURE);
    const [rows, columns] = state.fov.image_size;
    const pending = readArrayReply(socket);
    socket.write(JSON.stringify({
      type: "app_method",
      method: "get_adaptive_optopatch_reference_image_js",
      args: [],
      return_event: "ev_image",
    }) + "\n");

    const { metadata, bytes } = await pending;
    assert.equal(metadata.event, "ev_image");
    assert.equal(metadata.arrClass, "uint8");
    assert.equal(metadata.arrLength, rows * columns);
    assert.equal(bytes.length, rows * columns);
    assert.ok(bytes.every((b) => Number.isInteger(b) && b >= 0 && b <= 255));
  }));

test("fetching the image repeatedly changes nothing about the session", () =>
  withSocket(LOADED_FIXTURE, async ({ socket, session }) => {
    const before = JSON.parse(JSON.stringify(session.current()));
    let previous = null;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const pending = readArrayReply(socket);
      socket.write(JSON.stringify({
        type: "app_method",
        method: "get_adaptive_optopatch_reference_image_js",
        args: [],
        return_event: `ev_image_${attempt}`,
      }) + "\n");
      const { bytes } = await pending;
      if (previous) assert.deepEqual(bytes, previous);
      previous = bytes;
    }
    assert.deepEqual(session.current(), before);
  }));

test("there is no image to fetch before a reference is loaded", () =>
  withSocket(EMPTY_FIXTURE, async ({ socket }) => {
    const answered = new Promise((resolve) => {
      const framer = new LineFramer();
      socket.on("data", (chunk) => {
        for (const line of framer.push(chunk)) {
          const reply = JSON.parse(line);
          if (reply.event === "ev_image") resolve(reply.data);
        }
      });
    });
    socket.write(JSON.stringify({
      type: "app_method",
      method: "get_adaptive_optopatch_reference_image_js",
      args: [],
      return_event: "ev_image",
    }) + "\n");
    // The tag matlabHelpers turns back into null, which is what JS_Server
    // sends for a method that returned an empty MATLAB value.
    assert.deepEqual(await answered, { empty_result: true });
  }));

// ---------------------------------------------------------------------------
// Over the wire
// ---------------------------------------------------------------------------

test("an action over the socket takes its arguments in the MATLAB order", () =>
  withSocket(LOADED_FIXTURE, async ({ socket, session }) => {
    const answered = new Promise((resolve) => {
      const framer = new LineFramer();
      socket.on("data", (chunk) => {
        for (const line of framer.push(chunk)) {
          const reply = JSON.parse(line);
          if (reply.event === "ev_action") resolve(reply.data);
        }
      });
    });
    // adaptive_optopatch_action_js(app, action, payload, expected_revision)
    socket.write(JSON.stringify({
      type: "app_method",
      method: "adaptive_optopatch_action_js",
      args: ["set_cell_eligibility",
        { cell_id: "cell_001", stimulation_enabled: false },
        session.current().revision],
      return_event: "ev_action",
    }) + "\n");

    const response = await answered;
    assert.equal(response.ok, true);
    assert.equal(response.status, "applied");
    assert.equal(response.state.cells[0].stimulation_enabled, false);
  }));

test("the protocol listing is served on its own endpoint, not on the state poll", () =>
  withSocket(LOADED_FIXTURE, async ({ socket, session }) => {
    const answered = new Promise((resolve) => {
      const framer = new LineFramer();
      socket.on("data", (chunk) => {
        for (const line of framer.push(chunk)) {
          const reply = JSON.parse(line);
          if (reply.event === "ev_choices") resolve(reply.data);
        }
      });
    });
    socket.write(JSON.stringify({
      type: "app_method",
      method: "get_adaptive_optopatch_protocol_choices_js",
      args: [],
      return_event: "ev_choices",
    }) + "\n");

    const choices = await answered;
    assert.ok(Array.isArray(choices) && choices.length > 0);
    for (const choice of choices) assert.ok(typeof choice.choice_id === "string");
    assert.ok(!("protocol_choices" in session.current()),
      "The state snapshot must stay free of the protocol listing.");
  }));

// ---------------------------------------------------------------------------
// Starting a session from a snapshot
// ---------------------------------------------------------------------------

test("an empty session offers snapshots but has no FOV", () => {
  const session = newSession(EMPTY_FIXTURE);
  assert.equal(session.current().fov.loaded, false);
  assert.ok(session.snapshots().length >= 2);
  for (const choice of session.snapshots()) {
    assert.equal(typeof choice.choice_id, "string");
    assert.ok(choice.choice_id.length > 0);
    // The listing is what a frontend reads before anything is loaded, so it
    // has to carry enough to tell two crops of one field apart.
    assert.equal(choice.image_size.length, 2);
    assert.equal(choice.roi_origin_xy.length, 2);
  }
});

test("choosing a snapshot loads its FOV and nothing else", () => {
  const session = newSession(EMPTY_FIXTURE);
  const cropped = session.snapshots()
    .find((c) => c.roi_origin_xy[0] > 0);
  assert.ok(cropped, "the fixture should include a cropped snapshot");

  const response = act(session, "load_snapshot_choice", {
    choice_id: cropped.choice_id,
  });

  assert.equal(response.ok, true, response.message);
  const fov = response.state.fov;
  assert.equal(fov.loaded, true);
  assert.equal(fov.fov_id, cropped.choice_id);
  // Straight from what the real controller reported, not recomputed here.
  assert.deepEqual(fov.image_size, cropped.image_size);
  assert.deepEqual(fov.roi_origin_xy, cropped.roi_origin_xy);
  assert.equal(fov.camera_bin, cropped.camera_bin);
  assert.equal(fov.camera_name, cropped.camera_name);
});

test("loading a snapshot advances the reference revision", () => {
  // This is the whole trigger for a frontend refetching the image.
  const session = newSession(EMPTY_FIXTURE);
  const before = session.current().fov.reference_revision;
  const choice = session.snapshots()[0];

  const response = act(session, "load_snapshot_choice", {
    choice_id: choice.choice_id,
  });

  assert.ok(response.state.fov.reference_revision > before);
});

test("the served image follows the snapshot that was loaded", () => {
  const session = newSession(EMPTY_FIXTURE);
  assert.equal(session.referenceImageFor(session.current().fov.fov_id), null);

  for (const choice of session.snapshots()) {
    const response = session.apply("load_snapshot_choice",
      { choice_id: choice.choice_id }, session.state.revision);
    assert.equal(response.ok, true, response.message);
    const pixels = session.referenceImageFor(response.state.fov.fov_id);
    const [rows, columns] = response.state.fov.image_size;
    assert.equal(pixels.length, rows * columns,
      `${choice.choice_id}: pixels must match the announced image_size`);
  }
});

test("a new reference discards the somata drawn on the old one", () => {
  // Cell geometry is indices into a particular frame, so the controller
  // clears it when it adopts a new reference. A stub that kept them would
  // let a frontend bug that draws stale overlays pass unnoticed.
  const session = newSession();
  assert.ok(session.current().cells.length > 0);
  const other = session.snapshots().find((c) => !c.is_current);

  const response = act(session, "load_snapshot_choice", {
    choice_id: other.choice_id,
  });

  assert.deepEqual(response.state.cells, []);
  assert.deepEqual(response.state.soma_polygons, []);
  assert.equal(response.state.legal_actions.update_plan, false,
    "a reference with no somata cannot be prepared");
  assert.equal(response.state.legal_actions.edit_cells, true);
});

test("the loaded snapshot is marked current in the listing", () => {
  const session = newSession(EMPTY_FIXTURE);
  assert.ok(!session.snapshots().some((c) => c.is_current));
  const choice = session.snapshots()[1];

  act(session, "load_snapshot_choice", { choice_id: choice.choice_id });

  const current = session.snapshots().filter((c) => c.is_current);
  assert.equal(current.length, 1);
  assert.equal(current[0].choice_id, choice.choice_id);
});

test("a snapshot id that was never offered is refused", () => {
  const session = newSession(EMPTY_FIXTURE);
  const before = JSON.parse(JSON.stringify(session.current()));

  for (const id of ["/data/Snaps/something.mat", "../elsewhere", "nonesuch"]) {
    const response = act(session, "load_snapshot_choice", { choice_id: id });
    assert.equal(response.status, "validation_error", id);
    assert.equal(response.state.fov.loaded, false);
  }
  assert.deepEqual(session.current(), before);
});

test("a stale snapshot load is refused and loads nothing", () => {
  const session = newSession(EMPTY_FIXTURE);
  const choice = session.snapshots()[0];

  const response = session.apply("load_snapshot_choice",
    { choice_id: choice.choice_id }, session.state.revision - 1);

  assert.equal(response.status, "stale_revision");
  assert.equal(response.state.fov.loaded, false);
});

// ---------------------------------------------------------------------------
// The unified Reference/FOV chooser
//
// What these pin is the CONTRACT the React tab is written against: one typed
// listing carrying both kinds, a save that allocates rather than replaces, and
// a load that dispatches on the kind the listing reported. What each kind
// actually does to a session is MATLAB's, and is tested in
// tests/TestAdaptiveOptopatchReferenceChooser.m.
// ---------------------------------------------------------------------------

test("snapshots and saved FOVs are offered in one typed listing", () => {
  const session = newSession();

  const before = session.references();
  assert.ok(before.length > 0);
  assert.ok(before.every((entry) => entry.kind === "snapshot"),
    "with nothing saved yet, every entry is a camera snapshot");
  assert.ok(before.every((entry) => entry.choice_id.length > 0));

  act(session, "save_fov");

  const after = session.references();
  assert.equal(after.length, before.length + 1);
  const saved = after.filter((entry) => entry.kind === "ao_fov");
  assert.equal(saved.length, 1);
  // Grouped with the snapshot it was drawn on, and named for it.
  const snapshot = after.find(
    (entry) => entry.kind === "snapshot" &&
      entry.reference_id === saved[0].reference_id
  );
  assert.ok(snapshot, "a saved FOV is grouped with its snapshot");
  assert.equal(saved[0].group_index, snapshot.group_index);
});

test("saving chooses the next available number and replaces nothing", () => {
  const session = newSession();

  act(session, "save_fov");
  act(session, "save_fov");
  act(session, "save_fov");

  const saved = session.references().filter((e) => e.kind === "ao_fov");
  assert.deepEqual(saved.map((e) => e.fov_number), [1, 2, 3]);
  const reference = saved[0].reference_id;
  assert.deepEqual(
    saved.map((e) => e.choice_id),
    [1, 2, 3].map((n) => `${reference}_FOV${String(n).padStart(3, "0")}`)
  );
  // The camera snapshot is still offered, and still a snapshot.
  const original = session
    .references()
    .find((e) => e.choice_id === reference);
  assert.ok(original);
  assert.equal(original.kind, "snapshot");
});

test("a saved FOV restores cells; its snapshot loads fresh", () => {
  const session = newSession();
  act(session, "set_cell_blue_voltage", { cell_id: "cell_002", voltage_v: 2.25 });
  act(session, "set_cell_eligibility", {
    cell_id: "cell_003",
    recording_enabled: false,
  });
  const drawn = session.current().cells.length;
  assert.ok(drawn > 0);

  const bundle = act(session, "save_fov").state;
  assert.equal(bundle.fov.source_kind, "ao_fov");
  const savedId = session
    .references()
    .find((e) => e.kind === "ao_fov").choice_id;
  const reference = session
    .references()
    .find((e) => e.kind === "snapshot").choice_id;

  // The snapshot: a fresh FOV, no cells.
  const fresh = act(session, "load_reference_choice", { choice_id: reference });
  assert.equal(fresh.ok, true, fresh.message);
  assert.equal(fresh.state.fov.source_kind, "snapshot");
  assert.deepEqual(fresh.state.cells, []);

  // The bundle: the decisions come back.
  const restored = act(session, "load_reference_choice", { choice_id: savedId });
  assert.equal(restored.ok, true, restored.message);
  assert.equal(restored.state.fov.source_kind, "ao_fov");
  assert.equal(restored.state.cells.length, drawn);
  assert.equal(
    restored.state.cells.find((c) => c.cell_id === "cell_002")
      .selected_blue_voltage_v,
    2.25
  );
  assert.equal(
    restored.state.cells.find((c) => c.cell_id === "cell_003").recording_enabled,
    false
  );
});

test("a reference id that was never offered reaches nothing", () => {
  const session = newSession(EMPTY_FIXTURE);
  const before = JSON.parse(JSON.stringify(session.current()));

  for (const id of [
    "/data/Snaps/something.mat",
    "../elsewhere",
    "nonesuch",
    "nonesuch_FOV001",
  ]) {
    const response = act(session, "load_reference_choice", { choice_id: id });
    assert.equal(response.status, "validation_error", id);
    assert.equal(response.state.fov.loaded, false);
  }
  assert.deepEqual(session.current(), before);
});

test("loading marks exactly one entry current, by path", () => {
  const session = newSession();
  act(session, "save_fov");
  const saved = session.references().find((e) => e.kind === "ao_fov");

  act(session, "load_reference_choice", { choice_id: saved.choice_id });

  const current = session.references().filter((e) => e.is_current);
  assert.equal(current.length, 1);
  assert.equal(current[0].choice_id, saved.choice_id);
});

// ---------------------------------------------------------------------------
// Blue V
// ---------------------------------------------------------------------------

test("Blue V is an allowlisted edit with the controller's own range", () => {
  const session = newSession();

  const ok = act(session, "set_cell_blue_voltage", {
    cell_id: "cell_001",
    voltage_v: 1.9,
  });
  assert.equal(ok.status, "applied", ok.message);
  assert.equal(ok.state.cells[0].selected_blue_voltage_v, 1.9);

  for (const voltage of [0, -1, 5.5, "high", NaN]) {
    const refused = act(session, "set_cell_blue_voltage", {
      cell_id: "cell_001",
      voltage_v: voltage,
    });
    assert.equal(refused.status, "validation_error", String(voltage));
    assert.equal(refused.state.cells[0].selected_blue_voltage_v, 1.9,
      "a refused edit leaves the stored calibration alone");
  }
});

test("editing Blue V changes nothing about the loaded protocol", () => {
  // The claim the React panel makes: this is a stored calibration, not a
  // command source. Precedence itself is the resolver's and is tested in
  // MATLAB; what is checked here is that the tab's own edit does not touch
  // the protocol the panel is showing beside it.
  const session = newSession();
  const before = JSON.parse(JSON.stringify(session.current().protocol));

  act(session, "set_cell_blue_voltage", { cell_id: "cell_001", voltage_v: 3.3 });

  assert.deepEqual(session.current().protocol, before);
});

// ---------------------------------------------------------------------------
// The previews
//
// The GEOMETRY and the SAMPLES this stub produces are invented - see the
// comments on spatialPreview and waveformPreview. What is asserted here is
// only the shape the React panels read, and that both are read-only.
// ---------------------------------------------------------------------------

test("a preview changes nothing about the session", () => {
  const session = newSession();
  const before = JSON.parse(JSON.stringify(session.current()));

  session.spatialPreview("1p_dmd");
  session.spatialPreview("2p_spiral");
  session.waveformPreview();

  assert.deepEqual(session.current(), before);
  assert.equal(session.current().revision, before.revision);
});

test("each spatial preview reports the layers its own modality has", () => {
  const session = newSession();

  const onePhoton = session.spatialPreview("1p_dmd");
  assert.equal(onePhoton.available, true);
  assert.equal(onePhoton.coordinate_space, "snapshot_intrinsic_pixels");
  assert.ok(onePhoton.blue.length > 0, "1P shows Blue stimulation masks");
  assert.ok(onePhoton.orange.length > 0, "1P shows Orange recording masks");
  assert.equal(onePhoton.spiral.length, 0);

  const twoPhoton = session.spatialPreview("2p_spiral");
  assert.equal(twoPhoton.blue.length, 0, "there are no Blue masks in 2P");
  assert.ok(twoPhoton.spiral.length > 0);
  assert.ok(twoPhoton.spiral[0].path_xy.length > 1);
  assert.equal(twoPhoton.spiral[0].parking_xy.length, 2);
});

test("a spatial preview carries the revision it describes", () => {
  // What makes an overlay invalidate: the tab drops one whose revision is no
  // longer the session's, rather than deciding for itself which edits matter.
  const session = newSession();
  const preview = session.spatialPreview("2p_spiral");
  assert.equal(preview.revision, session.current().revision);

  act(session, "set_cell_eligibility", {
    cell_id: "cell_001",
    stimulation_enabled: false,
  });

  assert.notEqual(preview.revision, session.current().revision);
});

test("a FOV with no somata says so rather than claiming a preview", () => {
  const session = newSession(EMPTY_FIXTURE);
  const empty = session.spatialPreview("1p_dmd");
  assert.equal(empty.available, false);
  assert.ok(empty.message.length > 0);
  assert.deepEqual(empty.blue, []);
  assert.deepEqual(empty.spiral, []);
});

test("with no protocol the waveform preview says to load one", () => {
  const session = newSession(EMPTY_FIXTURE);

  const preview = session.waveformPreview();

  assert.equal(preview.available, false);
  assert.equal(preview.message, "Load a pulse protocol to preview waveforms.");
  assert.deepEqual(preview.channels, []);
  assert.deepEqual(preview.time_s, []);
});

test("a waveform preview gives one value per time point on every channel", () => {
  const session = newSession();

  const preview = session.waveformPreview();

  assert.equal(preview.available, true);
  assert.ok(preview.channels.length > 0);
  for (const channel of preview.channels) {
    assert.equal(channel.values.length, preview.time_s.length,
      `${channel.name} must be plottable against time_s`);
  }
  assert.ok(preview.events.length > 0);
  assert.ok(preview.targets.length > 0);
  assert.equal(
    preview.targets.reduce((total, t) => total + t.event_count, 0),
    preview.events.filter((e) => !e.is_null).length
  );
});
