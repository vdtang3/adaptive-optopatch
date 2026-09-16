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
and frames replies the way `JS_Server.write` does. That is all.

It does not emulate MATLAB, a rig or any device. It never runs a method, never
touches hardware and never writes a file. It binds to `127.0.0.1` only, prints a
banner saying what it is, and answers anything it does not recognise with the
"produced nothing" tag while logging it as `UNHANDLED` — so a gap shows up as a
missing value plus a log line rather than as an interface that hangs.

Requests it recognises:

| Request | Answer |
| --- | --- |
| `app_method get("tabs")` | `["Main", "AdaptiveOptopatch"]` |
| `app_method get("acquisition_active")` | `false` |
| `app_method get("User")` | `{ name: "dev" }` |
| `app_method get("datafolder")` | a placeholder string |
| `app_method get_device_availability_js` | `{ devices: [], count: 0, attaching: false }` |
| `app_method get_adaptive_optopatch_state_js` | the loaded fixture |
| `get_properties` | `{ numDevices: 0 }` |
| `set_property` | `1` |
| `dev_method` | JS_Server's `device_missing` reply |
| anything else | `{ empty_result: true }`, logged as `UNHANDLED` |

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

`fixtures/*.json` are **real** `AdaptiveOptopatchController.getState()`
snapshots, not hand-written JSON. Each file is exactly what `JS_Server` would put
on the wire as a reply's `data` field.

- `fake_ao_state_empty.json` — a fresh session: no FOV, no cells, no protocol.
- `fake_ao_state_loaded.json` — a reference FOV with two somata (one calibrated,
  one excluded from stimulation), a connectivity-screen protocol, and a frozen
  run.

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
- **Edit a fixture**: the file is watched, so saving it reloads the state and
  bumps the revision.
- **Bump the revision only**: `kill -USR2 <pid>` (the banner prints the command).
  Useful for checking that polling really does replace the view.

The revision offset is added to whatever the fixture says. It is a development
nudge, not part of the state — nothing else about the snapshot changes.

## Tests

```bash
cd ~/code/cohen-lab/software/adaptive-optopatch/dev/luminos-react
npm test
```

Node's built-in test runner; no dependencies, no lockfile, nothing to install.
Covers the newline framing, each supported reply, batch handling,
`return_event` preservation, a malformed line not ending the process, and
shutdown with a relay still connected.

## The React tab itself

The Adaptive Optopatch React tab currently lives in `luminos-private`
(`frontend/src/tabs/AdaptiveOptopatch/`, `frontend/src/matlabComms/
adaptiveOptopatchComms.tsx`, and one entry in `frontend/src/hooks/useTabs.tsx`)
and is **uncommitted** while we decide where it should live — see
`docs/notebook.md`. This harness is independent of that decision: it serves AO
state over the relay's protocol regardless of which repository the tab's source
ends up in.
