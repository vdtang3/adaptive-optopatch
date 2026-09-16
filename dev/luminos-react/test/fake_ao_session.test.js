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
    readJson(path.join(FIXTURES, "fake_ao_protocol_choices.json"))
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
    "set_cell_eligibility", "add_soma", "update_soma", "delete_soma",
    "load_protocol_choice", "set_plan_parameter", "freeze_run",
    "start_new_run", "return_to_editing", "start_new_batch",
    "run_next", "run_all", "stop_after_current",
  ]));
});

test("every reply carries the state after the action, refused or not", () => {
  const session = newSession();
  for (const response of [
    act(session, "set_cell_eligibility", { cell_id: "cell_001", recording_enabled: false }),
    act(session, "not_an_action"),
    act(session, "start_new_batch"),
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
  for (const action of ["not_an_action", "start_new_batch", "freeze_run"]) {
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

test("freezing and returning to editing move the lifecycle both ways", () => {
  const session = newSession(EMPTY_FIXTURE);
  // An empty session cannot freeze, and says so rather than pretending to.
  assert.equal(act(session, "freeze_run").status, "not_legal");

  const loaded = newSession();
  const frozen = act(loaded, "freeze_run");
  assert.equal(frozen.ok, true);
  assert.equal(frozen.state.plan_state, "FROZEN");
  assert.equal(frozen.state.lifecycle, "frozen");
  assert.equal(frozen.state.legal_actions.return_to_editing, true);

  const editing = act(loaded, "return_to_editing");
  assert.equal(editing.state.plan_state, "EDITABLE");
  assert.equal(editing.state.active_run.frozen, false);
  assert.equal(editing.state.legal_actions.return_to_editing, false);
});

test("a new batch is offered only once the current one has finished", () => {
  const session = newSession();
  act(session, "freeze_run");
  const first = session.state.active_run.batch_number;
  assert.equal(act(session, "start_new_batch").status, "not_legal");

  act(session, "run_all");
  assert.equal(session.state.active_run.batch_complete, true);
  assert.equal(session.state.legal_actions.start_new_batch, true);
  assert.equal(act(session, "start_new_batch").ok, true);
  assert.equal(session.state.active_run.batch_number, first + 1);
  assert.equal(session.state.active_run.completed_trial_count, 0);
});

test("legal_actions is recomputed, not carried over from the fixture", () => {
  const session = newSession();
  act(session, "return_to_editing");
  assert.equal(session.state.legal_actions.freeze_run, true);

  // Removing every soma removes the thing freezing needs.
  for (const cell of [...session.state.cells]) {
    act(session, "delete_soma", { cell_id: cell.cell_id });
  }
  assert.equal(session.state.legal_actions.freeze_run, false);
  assert.equal(act(session, "freeze_run").status, "not_legal");
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
