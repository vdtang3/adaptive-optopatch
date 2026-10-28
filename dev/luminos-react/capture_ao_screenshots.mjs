/* Capture screenshots of the real Adaptive Optopatch tab, for review.
 *
 * DEVELOPMENT ONLY, and part of this repository for the reason the rest of
 * dev/luminos-react is: it drives the Luminos React frontend from outside,
 * over the relay's own protocol, and nothing in Luminos knows it exists.
 *
 * It talks to a headless Chrome over the DevTools protocol rather than
 * through Playwright or Puppeteer, because neither is a dependency of the
 * Luminos frontend and adding one to take pictures would be a poor trade.
 * Node 22 has a global WebSocket, which is all CDP needs.
 *
 * Run the three servers first, as dev/luminos-react/README.md describes,
 * then:
 *
 *     google-chrome --headless=new --remote-debugging-port=9222 \
 *         --no-sandbox --disable-gpu about:blank &
 *     node capture_ao_screenshots.mjs <output directory>
 *
 * What it captures is the REAL tab rendering REAL controller state: the
 * fixtures under fixtures/ are jsonencode(controller.getState()) from a
 * genuine session. What a click DOES is the harness's imitation - see the
 * README - so these are pictures of the interface, not evidence about the
 * backend.
 */
import fs from "node:fs";
import path from "node:path";

const FRONTEND = "http://localhost:3000";
const DEVTOOLS = "http://localhost:9222";
const outputDir = process.argv[2] ?? "screenshots";

let nextId = 1;
const pending = new Map();

const connect = async () => {
  const targets = await (await fetch(`${DEVTOOLS}/json/list`)).json();
  const page = targets.find((t) => t.type === "page");
  if (!page) throw new Error("no page target in the headless browser");
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    const waiting = pending.get(message.id);
    if (!waiting) return;
    pending.delete(message.id);
    if (message.error) waiting.reject(new Error(message.error.message));
    else waiting.resolve(message.result);
  });
  return socket;
};

const send = (socket, method, params = {}) => {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
};

/** Evaluate in the page and return the value, failing loudly on a throw. */
const evaluate = async (socket, expression) => {
  const result = await send(socket, "Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.exception?.description ?? "threw");
  }
  return result.result.value;
};

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/* Poll rather than sleep: the tab's first paint waits on a MATLAB round
 * trip through the relay, and a fixed delay would be either flaky or slow. */
const waitForText = async (socket, text, timeoutMs = 20000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    /* Case-insensitively, because innerText is the RENDERED text and the
     * panel headings are uppercased by CSS: a literal match on
     * "Hardware ownership" never fires against "HARDWARE OWNERSHIP". */
    const found = await evaluate(
      socket,
      `document.body.innerText.toLowerCase()
         .includes(${JSON.stringify(text.toLowerCase())})`
    );
    if (found) return;
    await wait(250);
  }
  throw new Error(`timed out waiting for ${JSON.stringify(text)}`);
};

/* Exact trimmed text first, then a containing one.
 *
 * The tab strip and the page body are both made of buttons, and an
 * ancestor's textContent CONTAINS every label beneath it - so a
 * contains-only match picks the outermost element and clicks the wrong
 * thing, silently. */
const clickText = async (socket, selector, text) => {
  const clicked = await evaluate(
    socket,
    `(() => {
       const nodes = [...document.querySelectorAll(${JSON.stringify(selector)})];
       const wanted = ${JSON.stringify(text)};
       const node =
         nodes.find((n) => n.textContent.trim() === wanted) ??
         nodes.find((n) => n.textContent.trim().includes(wanted));
       if (node && node.disabled) return false;
       if (!node) return false;
       node.click();
       return true;
     })()`
  );
  if (!clicked) throw new Error(`no ${selector} containing ${text}`);
  await wait(900);
};

const capture = async (socket, name) => {
  /* The whole page, not the viewport: the tab is two tall columns and a
   * viewport-sized shot would cut the Run panel off. */
  const { cssContentSize } = await send(socket, "Page.getLayoutMetrics");
  const { data } = await send(socket, "Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: true,
    clip: {
      x: 0,
      y: 0,
      width: Math.ceil(cssContentSize.width),
      height: Math.ceil(cssContentSize.height),
      scale: 1,
    },
  });
  const file = path.join(outputDir, `${name}.png`);
  fs.writeFileSync(file, Buffer.from(data, "base64"));
  console.log(`wrote ${file}`);
};

/* The viewport as it stands, at a size chosen for the thing being shown.
 * Used for the close-ups; capture() is for the whole tall page. */
const captureViewport = async (socket, name, width, height) => {
  await send(socket, "Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 2,
    mobile: false,
  });
  await wait(600);
  const { data } = await send(socket, "Page.captureScreenshot", {
    format: "png",
  });
  const file = path.join(outputDir, `${name}.png`);
  fs.writeFileSync(file, Buffer.from(data, "base64"));
  console.log(`wrote ${file}`);
  await send(socket, "Emulation.setDeviceMetricsOverride", {
    width: 1680,
    height: 1200,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await wait(500);
};

const main = async () => {
  fs.mkdirSync(outputDir, { recursive: true });
  const socket = await connect();
  await send(socket, "Page.enable");
  await send(socket, "Runtime.enable");
  await send(socket, "Emulation.setDeviceMetricsOverride", {
    width: 1680,
    height: 1200,
    deviceScaleFactor: 1,
    mobile: false,
  });

  await send(socket, "Page.navigate", { url: FRONTEND });
  /* Retried rather than clicked once. The tab strip is painted from the
   * rig's tab list, which arrives over the relay, so the anchor exists a
   * beat after the page does - and a single click that lands too early
   * does nothing and says nothing. */
  const deadline = Date.now() + 40000;
  for (;;) {
    try {
      await clickText(socket, "button, a, [role='tab']", "Adaptive Optopatch");
      await waitForText(socket, "Hardware ownership", 3000);
      break;
    } catch (error) {
      if (Date.now() > deadline) throw error;
      await wait(1000);
    }
  }
  await wait(1500);

  await capture(socket, "01-loaded-fov");

  /* The ownership block and the recording-mask control, on their own. The
   * panel is what an experimenter reads first, so it is worth a shot that
   * is not three thousand pixels tall. */
  await evaluate(
    socket,
    `(() => {
       const heading = [...document.querySelectorAll("div")]
         .find((n) => n.textContent.trim() === "Hardware ownership");
       heading?.scrollIntoView({ block: "start" });
       return true;
     })()`
  );
  await wait(400);
  await captureViewport(socket, "02-hardware-ownership-panel", 820, 560);

  /* The Orange recording voltage, where an experimenter meets it: in the
   * spatial settings beneath the reference image, immediately below the
   * preview control that exists to help fill it in. */
  await evaluate(
    socket,
    `(() => {
       const label = [...document.querySelectorAll("span, label, div")]
         .find((n) => n.textContent.trim() === "Orange recording voltage");
       label?.scrollIntoView({ block: "center" });
       return true;
     })()`
  );
  await wait(500);
  await captureViewport(socket, "03-orange-recording-voltage", 980, 620);

  /* The recording-mask preview, through the real control. The harness
   * applies the action; what a real one does to the DMD is MATLAB's. */
  await clickText(socket, "button", "Show recording mask");
  await waitForText(socket, "Clear recording mask");
  await capture(socket, "04-recording-mask-active");
  /* scrollIntoView, not window.scrollTo: the tab scrolls inside a
   * container of its own, so scrolling the window moves nothing. */
  await evaluate(
    socket,
    `(() => {
       const heading = [...document.querySelectorAll("div")]
         .find((n) => n.textContent.trim() === "Hardware ownership");
       heading?.scrollIntoView({ block: "start" });
       return true;
     })()`
  );
  await wait(500);
  await captureViewport(socket, "05-recording-mask-panel", 820, 560);

  await clickText(socket, "button", "Clear recording mask");
  await waitForText(socket, "Show recording mask");

  socket.close();
};

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
