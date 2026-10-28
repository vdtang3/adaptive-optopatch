# Interface screenshots

Captured from the **real** Adaptive Optopatch React tab, driven by the
development harness in `dev/luminos-react` — the real Luminos frontend and
the real relay, with `fake_matlab_server.js` in place of a rig. The state
they render is `jsonencode(controller.getState())` from a genuine MATLAB
session (see `dev/luminos-react/README.md`), so every number in them is
MATLAB's.

What a click *does* in the harness is an imitation and is documented as
such in that README. These are pictures of the interface; they are not
evidence about the backend, which is tested in `tests/`.

Regenerate them with the three servers running:

```bash
google-chrome --headless=new --remote-debugging-port=9222 \
    --no-sandbox --disable-gpu about:blank &
cd dev/luminos-react
node capture_ao_screenshots.mjs ../../docs/gui
```

| File | What it shows |
| --- | --- |
| `01-loaded-fov.png` | the whole tab with a FOV loaded and a plan ready |
| `02-hardware-ownership-panel.png` | the ownership block and the mask control |
| `03-orange-recording-voltage.png` | the Orange recording voltage field in the spatial settings |
| `04-recording-mask-active.png` | the whole tab with the recording mask projected |
| `05-recording-mask-panel.png` | the ownership panel while the mask is projected |
