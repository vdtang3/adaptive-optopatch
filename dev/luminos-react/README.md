# Development harness: the Luminos React frontend without MATLAB

**Everything in this folder is development-only.** It belongs to this
repository, not to `luminos-private`: Luminos is shared by the whole lab, and a
fake MATLAB endpoint serving Adaptive Optopatch fixtures is specific to this
package. Nothing has to be added to Luminos for it to work — it speaks the
relay's existing protocol from the outside, so `JS_Server.m`,
`Rig_Control_App` and the relay need no knowledge of it at all.

`fake_matlab_server.js` stands in for the MATLAB end of the wire so the **real**
Luminos React frontend and the **real** Luminos relay can be run and exercised
on a machine with no rig, no MATLAB session and no Luminos Simulator — a Linux
workstation, for instance, where the Simulator does not run.

It answers the same requests production does, including the write endpoint, so
the whole Adaptive Optopatch workflow can be clicked through in a browser. What
it *does* with a write is a development imitation and is not Adaptive Optopatch
semantics — see [What the stub does and does not do](#what-the-stub-does-and-does-not-do).

```
React / Vite  :3000            luminos-private/src/User_Interface/frontend
     |
     v   socket.io
Luminos relay  :3009           luminos-private/src/User_Interface/relay
     |
     v   TCP, newline-delimited JSON
fake_matlab_server.js  :3010   <- this folder, in place of JS_Server.m
     |
     v
fixtures/*.json                <- real AdaptiveOptopatchController.getState()
```

Only the bottom two boxes are ours. Everything above them is the Luminos code
that ships, unmodified.

## Layout it assumes

The two repositories are siblings, as `~/code/cohen-lab/software` keeps them:

```
software/
    adaptive-optopatch/      <- this repository
        dev/luminos-react/
    luminos-private/
        src/User_Interface/{relay,frontend}
```

Nothing here resolves a path into `luminos-private`, so the two can live
anywhere; only the commands below assume the layout.

## What the stub does and does not do

It parses the request format `Data_Relay.sendToMatlab` writes, answers on the
`return_event` the request carried, unpacks batches the way `JS_Server` does,
and frames replies the way `JS_Server.write` does — including the binary path,
for an array larger than `JS_Server`'s own 1e4-element threshold, so the
reference image reaches the browser exactly as it does from a rig.

It does not emulate MATLAB, a rig or any device. It never touches hardware and
never writes a file. It binds to `127.0.0.1` only, prints a banner saying what
it is, and answers anything it does not recognise with the "produced nothing"
tag while logging it as `UNHANDLED` — so a gap shows up as a missing value plus
a log line rather than as an interface that hangs.

Requests it recognises:

| Request | Answer |
| --- | --- |
| `app_method get("tabs")` | `["Main", "AdaptiveOptopatch"]` |
| `app_method get("acquisition_active")` | `false` |
| `app_method get("User")` | `{ name: "dev" }` |
| `app_method get("datafolder")` | a placeholder string |
| `app_method get_device_availability_js` | `{ devices: [], count: 0, attaching: false }` |
| `app_method get_adaptive_optopatch_state_js` | the in-memory session state |
| `app_method adaptive_optopatch_action_js` | the same reply envelope MATLAB produces |
| `app_method get_adaptive_optopatch_reference_image_js` | the image fixture, binary-framed |
| `app_method get_adaptive_optopatch_protocol_choices_js` | the protocol listing fixture |
| `get_properties` | `{ numDevices: 0 }` |
| `set_property` | `1` |
| `dev_method` | JS_Server's `device_missing` reply |
| anything else | `{ empty_result: true }`, logged as `UNHANDLED` |

### Writes are imitated, not implemented

`fake_ao_session.js` applies actions to the loaded state so that the frontend's
`click -> action -> new authoritative state` loop can actually be exercised. It
mirrors the parts of the contract the frontend is written against:

- the same allowlist of action names
- the same staleness rule, and the same exemption for `stop_after_current`
- the same reply envelope, carrying the state after the action whether it was
  applied or refused
- `legal_actions` and `lifecycle` recomputed rather than carried over

Everything **below** that — what a polygon means, how a cell is named, whether a
protocol is valid, when a plan may be frozen, what a run does — is a plausible
imitation chosen so there is something to click. **Do not read it as Adaptive
Optopatch behaviour.** The real semantics are tested against the real controller
in `adaptive-optopatch/tests/TestAdaptiveOptopatchActions.m`; this file exists so
that a React bug can be found without MATLAB, not so that an AO question can be
answered without MATLAB.

Nothing here is imported by production React. The tab talks to whichever
endpoint answers and does not know this exists.

## Running it

Three terminals.

```bash
# 1. the stand-in for MATLAB          (this repository)
cd ~/code/cohen-lab/software/adaptive-optopatch/dev/luminos-react
node fake_matlab_server.js --fixture fixtures/fake_ao_state_loaded.json
#   or: npm run fake-matlab          (serves fake_ao_state_empty.json)

# 2. the real Luminos relay           (luminos-private)
cd ~/code/cohen-lab/software/luminos-private/src/User_Interface/relay
npm ci        # first time only
npm start

# 3. the real Luminos frontend        (luminos-private)
cd ~/code/cohen-lab/software/luminos-private/src/User_Interface/frontend
npm ci        # first time only
npm run dev
```

Then open <http://localhost:3000>.

Order does not matter: the relay reconnects to MATLAB once a second for as long
as it runs, so starting the stub after the relay works too.

The Luminos frontend's own `npm start` launches the relay alongside Vite through
`concurrently`, which is not in its dependencies — on Linux, run the two
separately as above. Nothing in Luminos's own startup path is modified by any of
this.

## Fixtures

`fixtures/*.json` are **real** endpoint output, not hand-written JSON: each file
is exactly what `JS_Server` would put on the wire as a reply's `data` field.

- `fake_ao_state_empty.json` — a fresh session: no FOV, no cells, no protocol.
- `fake_ao_state_loaded.json` — a 128 × 160 reference FOV with three somata (one
  calibrated, one excluded from stimulation), a connectivity-screen protocol,
  and a frozen run.
- `fake_ao_reference_image.json` — that FOV's reference image, as
  `reference_display_image` produces it: uint8, column-major, 20 480 pixels.
  Small on purpose. It is a deterministic synthetic field — a seeded noisy
  background with three Gaussian cells — because a committed fixture has to be
  small and a real snapshot is not, and because the canonical polygons have to
  sit on structure that is identical on every machine.
- `fake_ao_protocol_choices.json` — what `controller.protocolChoices()` reported
  for this repository's `pulse-protocols/generated`, with the generating
  machine's paths redacted.

Regenerate them with MATLAB, from this folder:

```bash
cd ~/code/cohen-lab/software/adaptive-optopatch/dev/luminos-react
matlab -batch "generate_ao_fixtures"
```

`generate_ao_fixtures.m` adds this repository's root to the path, builds the
controllers headlessly — no figure, no hardware, the simulated Luminos backend
the controller tests use — and writes `jsonencode(controller.getState())`.
Temporary run folders are rewritten to `<dev fixture>/...` so a fixture does not
carry a path that no longer exists.

### Changing state while the interface is open

- **Switch fixture**: stop the server and start it with the other `--fixture`.
  The tab shows the old state with a "not answering" notice while it is down and
  picks up the new one when it returns.
- **Edit a fixture**: the file is watched, so saving it reloads the state — and
  **discards anything clicked in the browser since**, which is the point.
- **Bump the revision only**: `kill -USR2 <pid>` (the banner prints the command).
  This is what a MATLAB-GUI edit looks like from the browser's side, and it is
  how the stale-revision path is exercised: bump, then use a control before the
  1 Hz poll catches up, and the action should be refused with the current state
  returned in its place.

## Tests

```bash
cd ~/code/cohen-lab/software/adaptive-optopatch/dev/luminos-react
npm test
```

Node's built-in test runner; no dependencies, no lockfile, nothing to install.

`test/fake_matlab_server.test.js` covers the wire: newline framing, each
supported reply, batch handling, `return_event` preservation, a malformed line
not ending the process, and shutdown with a relay still connected.

`test/fake_ao_session.test.js` covers the contract the React tab is written
against: the allowlist matching the MATLAB one, every reply carrying the state
after the action, a stale request changing nothing, revisions advancing by one,
no reply carrying a field named `error` (which the browser's bridge reads as a
thrown exception), and the reference image arriving binary-framed at the size
the state snapshot announced.

## The React tab itself

The Adaptive Optopatch React tab lives in `luminos-private`
(`frontend/src/tabs/AdaptiveOptopatch/`, `frontend/src/matlabComms/
adaptiveOptopatchComms.tsx`, and one entry in `frontend/src/hooks/useTabs.tsx`),
alongside every other tab — see `docs/notebook.md` for why. This harness is
independent of that: it serves AO state and actions over the relay's protocol
regardless of where the tab's source lives.
