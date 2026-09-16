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
| `app_method get_adaptive_optopatch_reference_image_js` | the loaded snapshot's image, binary-framed |
| `app_method get_adaptive_optopatch_snapshot_choices_js` | the snapshot listing fixture |
| `app_method get_adaptive_optopatch_reference_choices_js` | the snapshot listing plus whatever has been saved in this session, typed by `kind` |
| `app_method get_adaptive_optopatch_protocol_choices_js` | the protocol listing fixture |
| `app_method get_adaptive_optopatch_spatial_preview_js` | an imitated targeting overlay — see below |
| `app_method get_adaptive_optopatch_waveform_preview_js` | an imitated command trace — see below |
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
- `fov.source_kind` and `fov.source_path`, so the chooser can mark the loaded
  entry and the tab can say whether cells were restored or drawn
- the `(0, 5] V` range the controller enforces on a per-cell Blue calibration

`load_snapshot_choice` is the one action that does not imitate anything: it
REPLAYS what the real controller did. The FOV it installs and the image it
then serves were both captured from a real `loadSnapshotChoice`, so camera
identity, crop origin, binning and image size are MATLAB's numbers rather than
the stub's. A stub that invented them would let a frontend bug that mishandles
a cropped frame pass unnoticed here and fail on the rig.
`load_reference_choice` dispatches to it for a `snapshot` entry, and to an
in-memory restore for an `ao_fov` one.

### Saved FOVs exist only in memory

This server never touches the filesystem, so `save_fov` writes no file. What it
keeps is the slice of state a real save would have persisted, so that saving in
the browser adds an entry to the chooser and loading it back restores the
cells. The **naming** is the real rule — `<snapshot>_FOV###`, next unused
number, never replacing one, never renaming through a chain of saves — because
that is what the frontend displays and groups on. What a bundle **contains** is
an imitation; the schema is MATLAB's and is tested in
`tests/TestAdaptiveOptopatchReferenceChooser.m`.

### The previews are shaped right and drawn wrong

`spatialPreview` and `waveformPreview` return payloads whose SHAPE matches the
endpoints — kinds, coordinate space, outline rings, spiral path, parking point,
channels, event list, per-target counts, decimation fields — so the canvas
overlay, the mode switching, the staleness rule, the plot and all their empty
states can be exercised without MATLAB.

The NUMBERS are invented. The "Blue mask" outline is the canonical polygon
scaled about its centroid rather than one `apply_blue_mask_adjustment` eroded,
the spiral is an analytic curve rather than the Fermat spiral Luminos scans,
and the waveform is a made-up pulse train rather than a resolved schedule. **Do
not read any of it as Adaptive Optopatch geometry or timing.** The real ones are
computed by MATLAB and tested in
`tests/TestAdaptiveOptopatchFrontendPreviews.m`.

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
#
# Start from the EMPTY fixture to exercise the normal startup workflow:
# the tab opens with no FOV, and a snapshot is chosen from the tab itself.

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
- `fake_ao_snapshots.json` — the camera snapshots a session can start from, and
  what loading each one actually did. Three parts: `choices`, which is what
  `controller.snapshotChoices()` reported; and per choice a `fov` (the FOV
  summary the controller produced after loading it) and its reference image
  (uint8, column-major, exactly what the image endpoint returns).

  Two snapshots, and the second one matters: **160 × 128 at sensor origin
  [0, 0], bin 1**, and **140 × 96 at [512, 300], bin 2** — cropped, binned and
  non-square, because that is the normal case on the Virtual Upright and is
  exactly where a frontend that quietly assumed a square full-sensor image
  would go wrong. Switching between the two in a browser proves the canvas
  follows the reference rather than a remembered aspect ratio.

  The images are deterministic synthetic fields — a seeded noisy background
  with Gaussian cells — because a committed fixture has to be small and a real
  snapshot is not, and because the canonical polygons have to sit on structure
  that is identical on every machine.
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

It also covers starting a session from a snapshot: that an empty session offers
snapshots and has no FOV, that choosing one installs the FOV the real
controller produced for it, that the reference revision advances (which is the
whole trigger for a frontend refetching the image), that the served image
follows the snapshot that was loaded, that a new reference discards the somata
drawn on the old one, and that an id that was never offered - a path, in
particular - is refused.

And it covers the unified chooser as the tab reads it: that both kinds arrive
in one listing grouped by reference, that saving allocates the next number
without replacing anything, that a saved FOV restores cells while its snapshot
loads fresh, that exactly one entry is marked current, that Blue V is refused
outside the controller's range and leaves the stored value alone, and that
neither preview changes the session.

## The React tab itself

The Adaptive Optopatch React tab lives in `luminos-private`
(`frontend/src/tabs/AdaptiveOptopatch/`, `frontend/src/matlabComms/
adaptiveOptopatchComms.tsx`, and one entry in `frontend/src/hooks/useTabs.tsx`),
alongside every other tab — see `docs/notebook.md` for why. This harness is
independent of that: it serves AO state and actions over the relay's protocol
regardless of where the tab's source lives.
