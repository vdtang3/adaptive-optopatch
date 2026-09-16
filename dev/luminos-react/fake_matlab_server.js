/* DEVELOPMENT ONLY - a stand-in for JS_Server.m, for frontend work without MATLAB.
 *
 * WHAT THIS IS
 * Data_Relay.js connects to MATLAB as a TCP client on port 3010 and speaks a
 * newline-delimited JSON protocol. This server answers on that port with
 * canned, read-only replies so the REAL React frontend and the REAL relay can
 * be developed and exercised on a machine that has no rig, no MATLAB session
 * and no Luminos Simulator.
 *
 * WHAT THIS IS NOT
 * It does not emulate MATLAB, a rig, or any device. It never runs a method,
 * never touches hardware, never writes a file, and has no code path that could.
 * Every request it does not explicitly recognise is answered with the
 * "succeeded and produced nothing" tag and logged as UNHANDLED, so a gap shows
 * up as a missing value in the interface rather than as a hang.
 *
 * WHERE IT LIVES
 * In THIS repository, not in luminos-private. Luminos is shared by the whole
 * lab, and a fake MATLAB endpoint serving Adaptive Optopatch fixtures is
 * neither shared nor generic - it belongs to the package whose frontend it
 * exists to develop. Nothing has to be added to Luminos for it to work: it
 * speaks the relay's existing protocol from the outside, so the relay and
 * JS_Server.m need no knowledge of it whatsoever.
 *
 * It listens on the loopback interface only and prints a banner saying what it
 * is. Production is unchanged: JS_Server.m, Rig_Control_App and the relay know
 * nothing about this file.
 *
 *   node fake_matlab_server.js [--fixture fixtures/fake_ao_state_loaded.json]
 *                             [--port 3010]
 *
 * See README.md in this folder for the three-terminal development sequence.
 */

import net from "net";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { FakeAoSession } from "./fake_ao_session.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// The port Data_Relay.js dials for MATLAB. Luminos's
// src/User_Interface/relay/index.js constructs `new Data_Relay(3010, 3009)`, so
// 3010 is MATLAB's side and 3009 is the browser's. That file is the authority;
// this is the one place to change if it ever moves.
const MATLAB_PORT = 3010;

const DEFAULT_FIXTURE = path.join(HERE, "fixtures", "fake_ao_state_empty.json");

// The app method a future Rig_Control_App would expose for AO state. Named the
// way every other consolidated state read in Luminos is named -
// get_patch_state_js, get_environment_state_js, get_device_availability_js - so
// swapping this server for the real one is backend wiring and no frontend
// change at all.
const AO_STATE_METHOD = "get_adaptive_optopatch_state_js";

// The write endpoint and the two on-demand reads that go with it. Named
// exactly as luminos-private/src/Experimental_Scripts/js does, so swapping this
// server for the real one is backend wiring and no frontend change at all.
const AO_ACTION_METHOD = "adaptive_optopatch_action_js";
const AO_IMAGE_METHOD = "get_adaptive_optopatch_reference_image_js";
const AO_PROTOCOLS_METHOD = "get_adaptive_optopatch_protocol_choices_js";

// The fixtures that go with the state one. Beside it, and named after it.
const DEFAULT_IMAGE_FIXTURE = path.join(
  HERE, "fixtures", "fake_ao_reference_image.json");
const DEFAULT_PROTOCOLS_FIXTURE = path.join(
  HERE, "fixtures", "fake_ao_protocol_choices.json");

// Which tabs the shell renders. Main is included because useTabs starts on it,
// and because a rig with no devices is exactly the case every tab is already
// written to handle. Anything more would only add polling this server has
// nothing to say about.
const DEV_TABS = ["Main", "AdaptiveOptopatch"];

// ---------------------------------------------------------------------------
// Wire format
// ---------------------------------------------------------------------------

/* Requests arrive as one JSON object per line: Data_Relay.sendToMatlab writes
 * JSON.stringify(msg) + "\n". A TCP chunk can hold several lines, or half of
 * one, so the tail is carried over - which is what MATLAB's tcpserver
 * terminator callback does on the other side.
 *
 * Exported for the tests: the framing is the stateful part, and a boundary in
 * the wrong place is not something to verify by reading. */
export class LineFramer {
  constructor() {
    this.pending = "";
  }

  /** Feed one chunk; returns the complete lines it finished, blank ones dropped. */
  push(chunk) {
    this.pending += chunk.toString("utf8");
    const parts = this.pending.split("\n");
    this.pending = parts.pop();
    return parts.map((line) => line.trim()).filter((line) => line.length > 0);
  }
}

/* One reply exactly as JS_Server.write puts it on the socket: a single line of
 * JSON carrying `event` and `data`, terminated by the newline writeline adds.
 *
 * Non-ASCII is escaped. The relay finds the end of the metadata by indexing a
 * decoded STRING and then slices the BUFFER at that index, so a multi-byte
 * character before the newline would misalign everything after it. Escaping
 * keeps every reply one byte per character while parsing to the same value. */
export const encodeReply = (event, data) =>
  JSON.stringify({ event, data }).replace(
    /[-￿]/g,
    (character) => "\\u" + character.charCodeAt(0).toString(16).padStart(4, "0")
  ) + "\n";

/* JS_Server sends a numeric array larger than SMALL_DATA_SIZE as raw bytes
 * after its metadata line, in the array's own class, rather than as JSON -
 * jsonencode on an array that size costs more than the transfer. Anything
 * smaller goes as ordinary JSON.
 *
 * Mirrored here, threshold and all, because the two paths reach the browser
 * DIFFERENTLY: the relay hands a decoded binary array over as a flat list of
 * numbers, while a JSON reply arrives as whatever shape jsonencode produced.
 * A stub that always used one path would let the frontend be written against
 * a framing production does not use for the size of image that matters.
 *
 * Exported for the tests: this is the one piece of wire format here that is
 * not a single line of JSON. */
export const SMALL_DATA_SIZE = 1e4;

export const encodeArrayReply = (event, values, arrClass = "uint8") => {
  const header = JSON.stringify({
    event,
    arrLength: values.length,
    arrClass,
  }) + "\n";
  return Buffer.concat([
    Buffer.from(header, "utf8"),
    Buffer.from(Uint8Array.from(values).buffer),
  ]);
};

/* A numeric array a reply should carry, tagged so writeReply can choose the
 * framing JS_Server would have chosen for it. */
export class NumericArrayReply {
  constructor(values, arrClass = "uint8") {
    this.values = values;
    this.arrClass = arrClass;
  }
}

// JS_Server.runAndWriteBack tags a method that legitimately returned nothing,
// because write() has no way to frame an empty MATLAB value. matlabHelpers
// turns the tag back into null. This is what an unrecognised request gets.
const EMPTY_RESULT = { empty_result: true };

// JS_Server's answer for a device this rig does not have. matlabHelpers
// swallows it quietly - console.debug, no snackbar - which is the right
// treatment for every device call on a machine with no rig.
const deviceMissing = (devtype, method) => ({
  error: `No ${devtype} is loaded on this development server, so ${method} was not run.`,
  matlab_exception: true,
  device_missing: true,
  devtype: String(devtype ?? ""),
});

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

/* The Adaptive Optopatch session this server serves.
 *
 * The files are real endpoint output, produced by generate_ao_fixtures.m from
 * an actual AdaptiveOptopatchController - see README.md. The state fixture is
 * reloaded when it changes on disk, so it can be edited while the interface is
 * open; editing it DISCARDS anything clicked in the browser since, which is
 * the point of editing it.
 *
 * Once loaded, the state is MUTABLE: FakeAoSession applies actions to it so
 * that the frontend's click -> action -> new authoritative state loop can be
 * exercised. What that session does with an action is a development
 * imitation, not Adaptive Optopatch semantics - see fake_ao_session.js.
 *
 * The reference image and the protocol listing are separate fixtures because
 * they are separate endpoints: neither belongs on the state poll.
 *
 * `bumpRevision` exists so that a developer can make the state visibly change
 * under a running frontend (kill -USR2 <pid>) and watch the tab replace its
 * view. */
class AoDevSession {
  constructor({ statePath, imagePath, protocolsPath, log }) {
    this.statePath = statePath;
    this.imagePath = imagePath;
    this.protocolsPath = protocolsPath;
    this.log = log;
    this.image = this.readImage();
    this.reload();
  }

  reload() {
    this.session = new FakeAoSession(
      this.readJson(this.statePath, null, "AO state"),
      this.readJson(this.protocolsPath, [], "protocol choices")
    );
    // The fixture is a snapshot of derived state too; recomputing it here
    // means a hand-edited fixture cannot leave legal_actions disagreeing with
    // the lifecycle it was edited into.
    if (this.session.state) this.session.refreshDerivedState();
  }

  readJson(file, fallback, what) {
    try {
      const value = JSON.parse(fs.readFileSync(file, "utf8"));
      this.log(`${what} fixture loaded: ${file}`);
      return value;
    } catch (error) {
      // A missing or broken fixture must not take the server down: the point of
      // this process is to keep answering so the frontend's error path is the
      // thing under test, not this file's.
      this.log(`${what} fixture UNREADABLE (${error.message}); serving none`);
      return fallback;
    }
  }

  readImage() {
    const fixture = this.readJson(this.imagePath, null, "reference image");
    if (!fixture || !Array.isArray(fixture.pixels)) return null;
    return fixture.pixels;
  }

  /** Reload on the next change, so a fixture can be edited while it runs. */
  watch() {
    try {
      this.watcher = fs.watch(this.statePath, { persistent: false }, () => {
        this.reload();
        this.bumpRevision();
        this.log("state fixture changed -> reloaded");
      });
    } catch (error) {
      this.log(`not watching the fixture: ${error.message}`);
    }
  }

  bumpRevision() {
    if (!this.session.state) return;
    this.session.state.revision += 1;
    this.log(`revision -> ${this.session.state.revision}`);
  }

  current() {
    return this.session.current();
  }

  choices() {
    return this.session.choices();
  }

  /* What the reference-image endpoint returns: the flat uint8 list, or null
   * when no reference is loaded. Read only - calling it never changes the
   * state, exactly as the real endpoint never does. */
  referenceImage() {
    if (!this.session.state?.fov?.loaded) return null;
    return this.image;
  }

  apply(action, payload, expectedRevision) {
    const response = this.session.apply(action, payload, expectedRevision);
    this.log(
      `  action ${action} -> ${response.status} (revision ${response.revision})`
    );
    return response;
  }

  close() {
    this.watcher?.close();
  }
}

// ---------------------------------------------------------------------------
// Replies
// ---------------------------------------------------------------------------

/** What `app_method get(<name>)` answers for the properties the shell reads. */
const appProperty = (name) => {
  switch (name) {
    case "tabs":
      return DEV_TABS;
    // Read every 500 ms by GlobalAppVariablesContext, and every tab's polling
    // is gated on it. Always false: nothing here acquires anything.
    case "acquisition_active":
      return false;
    // miscellaneousComms.getImageFolderPath builds a path out of User.name.
    case "User":
      return { name: "dev" };
    case "datafolder":
      return "<development server - no data folder>";
    default:
      return undefined;
  }
};

/** What `app_method <method>(...)` answers. undefined means "not recognised". */
const appMethod = (method, args, session) => {
  switch (method) {
    case "get":
      return appProperty(args?.[0]);

    // useDeviceAvailability needs a numeric `count` to tell "read, and empty"
    // from "could not read"; without one it fails open and every device tab
    // renders as though the rig had everything.
    case "get_device_availability_js":
      return { devices: [], count: 0, attaching: false };

    case AO_STATE_METHOD:
      return session.current();

    // The write endpoint. Arguments arrive in the order the MATLAB function
    // declares them: (app, action, payload, expected_revision), so args[0..2]
    // here.
    case AO_ACTION_METHOD:
      return session.apply(args?.[0], args?.[1] ?? {}, args?.[2] ?? null);

    // Framed the way JS_Server would frame it for its size - binary for a real
    // FOV, JSON for a small one - so the frontend's decoder is exercised on
    // the path production actually uses.
    case AO_IMAGE_METHOD: {
      const pixels = session.referenceImage();
      if (!pixels || pixels.length === 0) return null;
      return pixels.length > SMALL_DATA_SIZE
        ? new NumericArrayReply(pixels, "uint8")
        : pixels;
    }

    case AO_PROTOCOLS_METHOD:
      return session.choices();

    default:
      return undefined;
  }
};

/** The reply payload for one request, or undefined when nothing is recognised. */
export const replyFor = (request, session) => {
  switch (request?.type) {
    case "app_method":
      return appMethod(request.method, request.args, session);

    // getPropertiesForMultipleDevices reads numDevices off the reply before
    // anything else, so a rig with none of that device has to answer with a
    // shape rather than with nothing. This is what JS_Server produces for an
    // empty device array.
    case "get_properties":
      return { numDevices: 0 };

    // Neither of these can do anything here. A set is answered the way
    // JS_Server answers one (1 for success) because it has, vacuously,
    // succeeded; a device method is answered as absent hardware.
    case "set_property":
      return 1;
    case "dev_method":
      return deviceMissing(request.devtype, request.method);

    default:
      return undefined;
  }
};

/** A one-line description of a request, for the log. */
const describe = (request) => {
  if (!request || typeof request !== "object") return String(request);
  if (request.type === "app_method") {
    const args = (request.args ?? []).map((a) => JSON.stringify(a)).join(", ");
    return `app_method ${request.method}(${args})`;
  }
  return `${request.type} ${request.devtype ?? ""}.${
    request.method ?? request.property ?? ""
  }`;
};

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

export const startFakeMatlabServer = ({
  port = MATLAB_PORT,
  fixturePath = DEFAULT_FIXTURE,
  imagePath = DEFAULT_IMAGE_FIXTURE,
  protocolsPath = DEFAULT_PROTOCOLS_FIXTURE,
  watchFixture = false,
  log = console.log,
} = {}) => {
  const session = new AoDevSession({
    statePath: fixturePath,
    imagePath,
    protocolsPath,
    log,
  });
  if (watchFixture) session.watch();

  // A request with no return_event wants no answer - JS_Server has nowhere to
  // write one either.
  const writeReply = (socket, returnEvent, payload) => {
    if (!returnEvent || socket.destroyed) return;
    if (payload instanceof NumericArrayReply) {
      socket.write(encodeArrayReply(returnEvent, payload.values, payload.arrClass));
      return;
    }
    socket.write(encodeReply(returnEvent, payload));
  };

  const handleRequest = (request, socket) => {
    const payload = replyFor(request, session);

    if (payload === undefined) {
      // Not recognised. Answered anyway, and loudly: a request left unanswered
      // hangs its caller for an hour (matlabHelpers.ABANDON_MS) and presents as
      // an interface that half works, which is far harder to read than a
      // missing value plus this line.
      log(`  UNHANDLED ${describe(request)} -> empty_result`);
      writeReply(socket, request?.return_event, EMPTY_RESULT);
      return;
    }

    log(`  ${describe(request)}`);
    // JS_Server.write drops an empty payload because it cannot frame one, and
    // runAndWriteBack tags it instead. Mirrored so callers see the same thing.
    writeReply(
      socket,
      request?.return_event,
      payload === null ? EMPTY_RESULT : payload
    );
  };

  const handleLine = (line, socket) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      // Malformed input is reported and skipped. It must not end the process:
      // the same connection carries every other request too.
      log(`  MALFORMED request ignored: ${error.message}`);
      return;
    }

    // matlabHelpers batches every request issued in the same tick into one
    // message; JS_Server.unpackRequests flattens it and runs each through the
    // same path, in order. Same here.
    if (message && message.type === "batch") {
      const requests = Array.isArray(message.requests) ? message.requests : [];
      log(`batch of ${requests.length}`);
      for (const request of requests) handleRequest(request, socket);
      return;
    }

    handleRequest(message, socket);
  };

  // Tracked so shutdown can hang up on them. server.close() only stops
  // ACCEPTING - it waits for every open connection to end by itself, and the
  // relay holds its connection open and reconnects for as long as it runs. Left
  // to itself, Ctrl-C therefore stopped listening and then sat there.
  const open = new Set();

  const server = net.createServer((socket) => {
    log(`relay connected from ${socket.remoteAddress}`);
    open.add(socket);
    const framer = new LineFramer();

    socket.on("data", (chunk) => {
      for (const line of framer.push(chunk)) handleLine(line, socket);
    });
    socket.on("error", (error) => log(`socket error: ${error.message}`));
    socket.on("close", () => {
      open.delete(socket);
      log("relay disconnected");
    });
  });

  // Loopback only. Nothing here should ever be reachable from another machine,
  // and binding explicitly is cheaper to verify than a firewall rule.
  server.listen(port, "127.0.0.1");

  return {
    server,
    session,
    close: () => {
      session.close();
      for (const socket of open) socket.destroy();
      return new Promise((resolve) => server.close(resolve));
    },
  };
};

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

const parseArgs = (argv) => {
  const options = { port: MATLAB_PORT, fixturePath: DEFAULT_FIXTURE };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--fixture") {
      options.fixturePath = path.resolve(HERE, argv[++i] ?? "");
    } else if (argv[i] === "--port") {
      options.port = Number(argv[++i]);
    } else {
      throw new Error(
        `Unknown option ${argv[i]}. Usage: node fake_matlab_server.js ` +
          `[--fixture <file>] [--port <n>]`
      );
    }
  }
  return options;
};

const runFromCommandLine = () => {
  const options = parseArgs(process.argv.slice(2));

  console.log("");
  console.log("  DEVELOPMENT MATLAB STUB - not a rig, not MATLAB, not safe for");
  console.log(`  production. Read-only canned state on 127.0.0.1:${options.port}`);
  console.log(`  Fixture: ${options.fixturePath}`);
  console.log(`  Bump the AO revision with:  kill -USR2 ${process.pid}`);
  console.log("  Ctrl-C to stop.");
  console.log("");

  const running = startFakeMatlabServer({ ...options, watchFixture: true });

  running.server.on("error", (error) => {
    if (error.code === "EADDRINUSE") {
      console.error(
        `Port ${options.port} is already in use. A real JS_Server, or another ` +
          `copy of this stub, is already listening.`
      );
      process.exit(1);
    }
    throw error;
  });

  // A visible state change under a running frontend, for checking that polling
  // really does replace the view rather than merging into it.
  process.on("SIGUSR2", () => running.session.bumpRevision());

  const shutdown = async () => {
    console.log("\nstopping");
    await running.close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
};

// Only when run directly, so the tests can import the pieces above.
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  runFromCommandLine();
}
