/* Tests for the development MATLAB stub.
 *
 * Two halves. The pure ones exercise the framing and the reply table directly.
 * The rest drive a real TCP connection, because the properties that matter -
 * a chunk boundary in the middle of a request, a malformed line not ending the
 * process, one reply per batched request - only exist on a socket.
 *
 * Run with: npm test   (from dev/luminos-react)
 */
import assert from "node:assert/strict";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  LineFramer,
  encodeReply,
  replyFor,
  startFakeMatlabServer,
} from "../fake_matlab_server.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EMPTY_FIXTURE = path.join(HERE, "..", "fixtures", "fake_ao_state_empty.json");
const LOADED_FIXTURE = path.join(HERE, "..", "fixtures", "fake_ao_state_loaded.json");

// ---------------------------------------------------------------------------
// A. newline-delimited request parsing
// ---------------------------------------------------------------------------

test("framing: one line per request, however the chunks fall", () => {
  const framer = new LineFramer();
  assert.deepEqual(framer.push(Buffer.from('{"a":1}\n{"b":')), ['{"a":1}']);
  assert.deepEqual(framer.push(Buffer.from('2}\n')), ['{"b":2}']);
});

test("framing: a request split one byte at a time still arrives once", () => {
  const line = JSON.stringify({ type: "app_method", method: "get", args: ["tabs"] });
  const buffer = Buffer.from(line + "\n");
  const framer = new LineFramer();
  const lines = [];
  for (const byte of buffer) lines.push(...framer.push(Buffer.from([byte])));
  assert.deepEqual(lines, [line]);
});

test("framing: a partial line yields nothing until its newline", () => {
  const framer = new LineFramer();
  assert.deepEqual(framer.push(Buffer.from('{"a":1}')), []);
  assert.deepEqual(framer.push(Buffer.from("\n")), ['{"a":1}']);
});

test("replies are one line of JSON, the way JS_Server.write frames one", () => {
  const encoded = encodeReply("ev1", { a: 1 });
  assert.ok(encoded.endsWith("\n"));
  assert.equal(encoded.indexOf("\n"), encoded.length - 1);
  assert.deepEqual(JSON.parse(encoded), { event: "ev1", data: { a: 1 } });
});

test("non-ASCII is escaped, so the relay's string index matches its byte index", () => {
  const encoded = encodeReply("ev1", { note: "café — done" });
  assert.equal(Buffer.byteLength(encoded, "utf8"), encoded.length);
  assert.equal(JSON.parse(encoded).data.note, "café — done");
});

// ---------------------------------------------------------------------------
// Reply table, without a socket
// ---------------------------------------------------------------------------

test("an unrecognised request is not recognised, rather than answered wrongly", () => {
  const fixture = { current: () => null };
  assert.equal(replyFor({ type: "app_method", method: "multiple_snap_js" }, fixture), undefined);
  assert.equal(replyFor({ type: "app_method", method: "get", args: ["nonesuch"] }, fixture), undefined);
  assert.equal(replyFor({ type: "no_such_type" }, fixture), undefined);
});

test("a device method is answered as absent hardware, not as a failure", () => {
  const reply = replyFor(
    { type: "dev_method", devtype: "Camera", method: "Snap_JS" },
    { current: () => null }
  );
  // matlabHelpers checks device_missing BEFORE matlab_exception, so this
  // resolves null quietly instead of raising a red snackbar on every tab.
  assert.equal(reply.device_missing, true);
  assert.equal(reply.devtype, "Camera");
});

test("get_properties answers with a shape, because callers read numDevices first", () => {
  const reply = replyFor({ type: "get_properties", devtype: "Camera", properties: ["ROI"] }, {});
  assert.equal(reply.numDevices, 0);
});

// ---------------------------------------------------------------------------
// Over a real socket
// ---------------------------------------------------------------------------

/** Start the stub on an ephemeral port and connect to it, as the relay does. */
const withServer = async (fixturePath, body) => {
  const running = startFakeMatlabServer({ port: 0, fixturePath, log: () => {} });
  await new Promise((resolve) => running.server.once("listening", resolve));
  const { port } = running.server.address();

  const socket = net.createConnection(port, "127.0.0.1");
  await new Promise((resolve) => socket.once("connect", resolve));

  // Replies come back framed exactly as the relay reads them: one JSON line
  // each, so a test waits on the return_event it asked for.
  const waiters = new Map();
  const framer = new LineFramer();
  socket.on("data", (chunk) => {
    for (const line of framer.push(chunk)) {
      const reply = JSON.parse(line);
      waiters.get(reply.event)?.(reply.data);
      waiters.delete(reply.event);
    }
  });

  let nextEvent = 0;
  const request = (message) => {
    const return_event = `ev${nextEvent++}`;
    const answered = new Promise((resolve) => waiters.set(return_event, resolve));
    socket.write(JSON.stringify({ ...message, return_event }) + "\n");
    return answered;
  };

  /** Send one message verbatim, for the cases that are not a single request. */
  const raw = (text) => socket.write(text);

  try {
    await body({ request, raw, waiters, socket, fixture: running.fixture });
  } finally {
    socket.destroy();
    await running.close();
  }
};

// B. app_method get tabs
test("app_method get(tabs) lists Adaptive Optopatch alongside the shell tabs", () =>
  withServer(EMPTY_FIXTURE, async ({ request }) => {
    const tabs = await request({ type: "app_method", method: "get", args: ["tabs"] });
    assert.ok(Array.isArray(tabs));
    assert.ok(tabs.includes("AdaptiveOptopatch"));
    assert.ok(tabs.includes("Main"));
  }));

// C. acquisition_active
test("acquisition_active is false, in the shape the shell polls for", () =>
  withServer(EMPTY_FIXTURE, async ({ request }) => {
    const active = await request({
      type: "app_method",
      method: "get",
      args: ["acquisition_active"],
    });
    assert.equal(active, false);
  }));

test("the device inventory carries a count, so the shell does not fail open", () =>
  withServer(EMPTY_FIXTURE, async ({ request }) => {
    const info = await request({
      type: "app_method",
      method: "get_device_availability_js",
      args: [],
    });
    assert.equal(info.count, 0);
    assert.deepEqual(info.devices, []);
  }));

// D. AO state reply preserves return_event
test("the AO state reply comes back on the return_event it was asked on", () =>
  withServer(EMPTY_FIXTURE, async ({ socket, waiters }) => {
    const mine = "ev_adaptive_optopatch";
    const answered = new Promise((resolve) => waiters.set(mine, resolve));
    socket.write(
      JSON.stringify({
        type: "app_method",
        method: "get_adaptive_optopatch_state_js",
        args: [],
        return_event: mine,
      }) + "\n"
    );
    const state = await answered;
    assert.equal(state.schema_version, "1.0.0");
  }));

// G. AO state is valid JSON, and is the real controller's shape
test("the AO state served is the controller's own getState payload", () =>
  withServer(LOADED_FIXTURE, async ({ request }) => {
    const state = await request({
      type: "app_method",
      method: "get_adaptive_optopatch_state_js",
      args: [],
    });
    // Round-trips, which is the JSON validity claim.
    assert.deepEqual(JSON.parse(JSON.stringify(state)), state);

    for (const field of [
      "schema_version",
      "revision",
      "lifecycle",
      "plan_state",
      "editable_state_changed",
      "stop_after_current_requested",
      "status",
      "fov",
      "cells",
      "soma_polygons",
      "protocol",
      "plan_parameters",
      "active_run",
      "legal_actions",
    ]) {
      assert.ok(field in state, `AO state is missing ${field}`);
    }
    assert.equal(state.lifecycle, "frozen");
    assert.equal(state.fov.loaded, true);
    assert.equal(state.cells.length, 2);
  }));

// E. batch request handling
test("a batch is answered once per request, in order", () =>
  withServer(EMPTY_FIXTURE, async ({ socket, waiters }) => {
    const wait = (event) => new Promise((resolve) => waiters.set(event, resolve));
    const tabs = wait("ev_tabs");
    const active = wait("ev_active");
    const state = wait("ev_state");

    socket.write(
      JSON.stringify({
        type: "batch",
        requests: [
          { type: "app_method", method: "get", args: ["tabs"], return_event: "ev_tabs" },
          {
            type: "app_method",
            method: "get",
            args: ["acquisition_active"],
            return_event: "ev_active",
          },
          {
            type: "app_method",
            method: "get_adaptive_optopatch_state_js",
            args: [],
            return_event: "ev_state",
          },
        ],
      }) + "\n"
    );

    assert.ok((await tabs).includes("AdaptiveOptopatch"));
    assert.equal(await active, false);
    assert.equal((await state).plan_state, "EDITABLE");
  }));

// F. malformed request does not kill the server
test("a malformed line is skipped and the next request is still answered", () =>
  withServer(EMPTY_FIXTURE, async ({ raw, request }) => {
    raw("this is not json\n");
    raw('{"type":"app_method","method":"get"\n'); // truncated JSON
    const tabs = await request({ type: "app_method", method: "get", args: ["tabs"] });
    assert.ok(tabs.includes("AdaptiveOptopatch"));
  }));

test("an unrecognised request is answered rather than left to hang", () =>
  withServer(EMPTY_FIXTURE, async ({ request }) => {
    const reply = await request({ type: "app_method", method: "multiple_snap_js", args: [] });
    // The tag matlabHelpers turns back into null.
    assert.deepEqual(reply, { empty_result: true });
  }));

test("a request arriving in pieces is answered once it is complete", () =>
  withServer(EMPTY_FIXTURE, async ({ raw, waiters }) => {
    const answered = new Promise((resolve) => waiters.set("ev_split", resolve));
    const line =
      JSON.stringify({
        type: "app_method",
        method: "get",
        args: ["tabs"],
        return_event: "ev_split",
      }) + "\n";
    raw(line.slice(0, 11));
    raw(line.slice(11, 30));
    raw(line.slice(30));
    assert.ok((await answered).includes("AdaptiveOptopatch"));
  }));

test("shutdown returns promptly with the relay still connected", async () => {
  const running = startFakeMatlabServer({ port: 0, fixturePath: EMPTY_FIXTURE, log: () => {} });
  await new Promise((resolve) => running.server.once("listening", resolve));
  const socket = net.createConnection(running.server.address().port, "127.0.0.1");
  await new Promise((resolve) => socket.once("connect", resolve));

  // server.close() alone only stops accepting and then waits for every open
  // connection to end by itself, which the relay's never does - so Ctrl-C used
  // to release the port and then sit there.
  await Promise.race([
    running.close(),
    new Promise((_, reject) => setTimeout(() => reject(new Error("close() did not return")), 2000)),
  ]);
  socket.destroy();
});

test("bumping the revision changes what the next poll is told", () =>
  withServer(LOADED_FIXTURE, async ({ request, fixture }) => {
    const ask = () =>
      request({
        type: "app_method",
        method: "get_adaptive_optopatch_state_js",
        args: [],
      });

    const before = await ask();
    fixture.bumpRevision(); // what the SIGUSR2 handler calls
    const after = await ask();

    assert.equal(after.revision, before.revision + 1);
    // Only the revision moves: the bump is a development nudge, not an edit of
    // what the controller said.
    assert.deepEqual({ ...after, revision: 0 }, { ...before, revision: 0 });
  }));
