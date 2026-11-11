// Runs the IINA plugin entry script against a mocked `iina` API and a mock
// Melingo bridge, and checks subtitle mirroring, mouse selection, and the
// pause / lookup / resume behaviour.
const fs = require("fs");
const vm = require("vm");
const http = require("http");
const assert = require("assert");

const pluginDir = process.argv[2];
const source = fs.readFileSync(pluginDir + "/main.js", "utf8");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

assert.ok(!/setClickable\(\s*true\s*\)/.test(source), "the overlay must never be made clickable (crashes IINA 1.5.1)");

function makeBridge() {
  const bridge = { requests: [], state: "open", nextId: 1, rejectHeaderless: 0 };
  bridge.server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const params = Object.fromEntries(url.searchParams.entries());
    const send = (status, obj) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    if (!req.headers["x-melingo-bridge"]) { bridge.rejectHeaderless += 1; return send(403, { error: "forbidden" }); }
    bridge.requests.push({ path: url.pathname, params });
    if (url.pathname === "/lookup") { bridge.state = "open"; return send(200, { id: "L" + bridge.nextId++ }); }
    if (url.pathname === "/status") return send(200, { state: bridge.state });
    if (url.pathname === "/dismiss") { bridge.state = "closed"; return send(200, { ok: true }); }
    send(404, { error: "not-found" });
  });
  bridge.lookups = () => bridge.requests.filter((r) => r.path === "/lookup").map((r) => r.params.text);
  return bridge;
}

// Window 1000 x 500 points; the overlay page is 2000 x 1000 px, so positions
// double. Words sit on one line near the bottom of the page.
const LINE = "He looked away.";
const LAYOUT = {
  text: LINE,
  width: 2000,
  height: 1000,
  words: [
    { start: 0, end: 2, x: 800, y: 900, w: 60, h: 50 },   // He
    { start: 3, end: 9, x: 880, y: 900, w: 160, h: 50 },  // looked
    { start: 10, end: 14, x: 1060, y: 900, w: 120, h: 50 }, // away
  ],
};
// Centre of a word in window points (origin bottom-left), as IINA reports it.
const at = (i) => {
  const box = LAYOUT.words[i];
  return { x: (box.x + box.w / 2) / 2, y: 500 - (box.y + box.h / 2) / 2 };
};

function makePlayer(port) {
  const player = {
    log: [],
    props: { sid: "1", "current-tracks/sub/codec": "subrip", "current-tracks/sub/lang": "eng", "sub-visibility": "yes", "sub-text": LINE },
    events: {},
    messages: {},
    mouse: {},
    posted: [],
    timers: [],
  };
  const status = { paused: false, title: "Movie.mkv", position: 12.5 };
  player.status = status;
  const iina = {
    core: {
      status,
      window: { frame: { x: 0, y: 0, width: 1000, height: 500 } },
      pause() { status.paused = true; player.log.push("pause"); },
      resume() { status.paused = false; player.log.push("resume"); },
      osd(message) { player.log.push("osd:" + message); },
    },
    mpv: {
      getString(name) { return player.props[name]; },
      getNumber(name) { return player.props[name]; },
      set(name, value) { player.props[name] = value; player.log.push("set:" + name + "=" + value); },
    },
    overlay: {
      loadFile(path) { player.log.push("loadFile:" + path); },
      setClickable(v) { player.log.push("clickable:" + v); },
      show() { player.log.push("show"); },
      onMessage(name, cb) { player.messages[name] = cb; },
      postMessage(name, data) { player.posted.push(JSON.parse(JSON.stringify({ name, data }))); }, // copy out of the vm realm
    },
    input: {
      MOUSE: "mouse", PRIORITY_HIGH: 200, PRIORITY_LOW: 100,
      onMouseDown(button, cb, priority) { player.mouse.down = cb; player.mouse.downPriority = priority; },
      onMouseUp(button, cb, priority) { player.mouse.up = cb; player.mouse.upPriority = priority; },
      onMouseDrag(button, cb) { player.mouse.drag = cb; },
    },
    http: {
      async get(url, options) {
        const target = new URL(url.replace("51730", String(port)));
        for (const [k, v] of Object.entries(options.params || {})) {
          assert.strictEqual(typeof v, "string", "param " + k + " must be a string");
          target.searchParams.set(k, v);
        }
        const res = await fetch(target, { headers: options.headers });
        return { statusCode: res.status, text: await res.text() };
      },
    },
    event: { on(name, cb) { player.events[name] = cb; return name; } },
    console: { log() {} },
  };
  const context = vm.createContext({
    iina,
    setTimeout,
    setInterval: (fn, ms) => { const t = setInterval(fn, ms); player.timers.push(t); return t; },
    Date, JSON, String, Math, console, isFinite,
  });
  vm.runInContext(source, context, { filename: "main.js" });
  player.stop = () => player.timers.forEach(clearInterval);
  player.selections = () => player.posted.filter((m) => m.name === "select").map((m) => m.data.from + "-" + m.data.to);
  player.lastControl = () => player.posted.filter((m) => m.name !== "subtitle").at(-1);
  return player;
}

async function boot(port) {
  const player = makePlayer(port);
  player.events["iina.window-loaded"]();
  player.messages["ready"]();
  player.messages["layout"](JSON.parse(JSON.stringify(LAYOUT)));
  await sleep(150);
  return player;
}

(async () => {
  const bridge = makeBridge();
  await new Promise((r) => bridge.server.listen(0, "127.0.0.1", r));
  const port = bridge.server.address().port;

  // A. overlay load + subtitle mirroring; the overlay never takes mouse events
  let p = await boot(port);
  assert.deepStrictEqual(p.log.slice(0, 3), ["loadFile:overlay.html", "clickable:false", "show"]);
  assert.ok(!p.log.includes("clickable:true"));
  assert.strictEqual(p.mouse.downPriority, 200, "mouse-down is seen before IINA's own handling");
  assert.strictEqual(p.mouse.upPriority, 200);
  assert.strictEqual(p.props["sub-visibility"], "no", "native subtitles hidden once the overlay is ready");
  assert.deepStrictEqual(p.posted.at(-1), { name: "subtitle", data: { text: LINE, scale: 1, pos: 100, fontSize: 55, marginY: 22 } });
  p.props["sub-scale"] = 1.5; p.props["sub-pos"] = 60; p.props["sub-font-size"] = 40; // IINA's own subtitle controls
  await sleep(250);
  assert.deepStrictEqual(p.posted.at(-1), { name: "subtitle", data: { text: LINE, scale: 1.5, pos: 60, fontSize: 40, marginY: 22 } });
  p.events["iina.file-loaded"](); // must not load the overlay twice
  assert.strictEqual(p.log.filter((l) => l.startsWith("loadFile")).length, 1);
  await sleep(150);

  // B. click a word while playing -> pause -> lookup -> panel closes -> resume
  p.log.length = 0; bridge.requests.length = 0;
  assert.strictEqual(p.mouse.down(at(1)), true, "a press on a word is taken from IINA");
  assert.deepStrictEqual(p.log, ["pause"], "pauses at mouse-down");
  assert.deepStrictEqual(p.selections().at(-1), "1-1", "the pressed word is highlighted");
  assert.strictEqual(p.mouse.up(at(1)), true, "and so is its release, so IINA's click action does not fire");
  await sleep(800);
  const lookupReq = bridge.requests.find((r) => r.path === "/lookup");
  assert.deepStrictEqual(lookupReq.params, { text: "looked", context: LINE, title: "Movie.mkv", position: "12.5", trackLang: "eng" });
  assert.ok(bridge.requests.some((r) => r.path === "/status" && r.params.id === "L1"), "polls status with the lookup id");
  assert.ok(p.status.paused && !p.log.includes("resume"), "stays paused while the panel is open");
  bridge.state = "closed";
  await sleep(500);
  assert.deepStrictEqual(p.log, ["pause", "resume"], "resumes after the panel closes");
  assert.strictEqual(p.lastControl().name, "clear-selection");
  const polls = bridge.requests.length;
  await sleep(500);
  assert.strictEqual(bridge.requests.length, polls, "stops polling once the session ended");

  // C. clicks that are not on a word are left to IINA
  p.log.length = 0; bridge.requests.length = 0;
  assert.strictEqual(p.mouse.down({ x: 100, y: 400 }), false);
  assert.strictEqual(p.mouse.up({ x: 100, y: 400 }), false);
  assert.strictEqual(p.mouse.down({ x: at(1).x, y: at(1).y + 30 }), false, "just above the line is not a hit");
  assert.strictEqual(p.mouse.drag({ x: 300, y: 300 }), false);
  await sleep(450);
  assert.deepStrictEqual(p.log, []);
  assert.strictEqual(bridge.requests.length, 0);

  // D. drag across a phrase: IINA sends no mouse-up after a drag, so the
  //    selection is looked up once the pointer rests
  p.log.length = 0; bridge.requests.length = 0; p.posted.length = 0;
  assert.strictEqual(p.mouse.down(at(0)), true);
  p.mouse.drag({ x: at(0).x + 20, y: at(0).y - 3 });
  p.mouse.drag(at(1));
  await sleep(150);
  assert.deepStrictEqual(bridge.lookups(), [], "no lookup while the pointer is still moving");
  p.mouse.drag({ x: at(1).x + 30, y: at(1).y }); // still inside "looked"
  await sleep(600);
  assert.deepStrictEqual(p.selections(), ["0-0", "0-1"], "highlight follows the drag");
  assert.deepStrictEqual(bridge.lookups(), ["He looked"]);
  p.mouse.drag(at(2)); // the user carries on dragging after a pause
  p.mouse.drag({ x: 990, y: 5 }); // far past the end of the line: still the last word
  await sleep(600);
  assert.deepStrictEqual(p.selections().at(-1), "0-2");
  assert.deepStrictEqual(bridge.lookups(), ["He looked", "He looked away"], "the longer phrase replaces the first lookup");
  assert.deepStrictEqual(p.log, ["pause"], "one pause for the whole gesture");
  await sleep(500);
  assert.deepStrictEqual(bridge.lookups().length, 2, "resting on the same words does not look them up again");
  bridge.state = "closed";
  await sleep(500);
  assert.deepStrictEqual(p.log, ["pause", "resume"]);

  // E. dragging backwards selects from the earlier word
  bridge.requests.length = 0;
  p.mouse.down(at(2));
  p.mouse.drag(at(1));
  await sleep(600);
  assert.deepStrictEqual(bridge.lookups(), ["looked away"]);
  bridge.state = "closed";
  await sleep(500);

  // F. a press that gets neither a release nor a drag is treated as a click
  bridge.requests.length = 0;
  p.mouse.down(at(2));
  await sleep(1200);
  assert.deepStrictEqual(bridge.lookups(), []);
  await sleep(600);
  assert.deepStrictEqual(bridge.lookups(), ["away"]);
  bridge.state = "closed";
  await sleep(500);

  // G. video was already paused -> stays paused afterwards
  p.log.length = 0;
  p.status.paused = true;
  p.mouse.down(at(2)); p.mouse.up(at(2));
  await sleep(450);
  bridge.state = "closed";
  await sleep(500);
  assert.deepStrictEqual(p.log, [], "no pause/resume when the video was already paused");
  assert.strictEqual(p.status.paused, true);

  // H. user presses play while the panel is open -> dismiss, no extra resume
  p.status.paused = false; p.log.length = 0; bridge.requests.length = 0;
  p.mouse.down(at(1)); p.mouse.up(at(1));
  await sleep(450);
  p.status.paused = false; // manual play
  await sleep(500);
  assert.ok(bridge.requests.some((r) => r.path === "/dismiss"), "tells Melingo to close the panel");
  assert.deepStrictEqual(p.log, ["pause"], "does not resume or pause again");

  // I. second selection while the first panel is open keeps one session
  p.log.length = 0; bridge.requests.length = 0;
  p.mouse.down(at(1)); p.mouse.up(at(1));
  await sleep(450);
  p.mouse.down(at(2)); p.mouse.up(at(2));
  await sleep(450);
  assert.deepStrictEqual(bridge.lookups(), ["looked", "away"]);
  assert.deepStrictEqual(p.log, ["pause"], "only one pause across two lookups");
  bridge.state = "closed";
  await sleep(500);
  assert.deepStrictEqual(p.log, ["pause", "resume"], "resumes once after the last panel closes");
  assert.strictEqual(bridge.rejectHeaderless, 0, "every request carried the bridge header");

  // J. word boxes for a different line than the one on screen are not trusted
  p.props["sub-text"] = "Something else entirely";
  await sleep(250);
  p.log.length = 0;
  assert.strictEqual(p.mouse.down(at(1)), false, "stale boxes: the click is left to IINA");
  assert.deepStrictEqual(p.log, []);
  p.props["sub-text"] = LINE;
  await sleep(250);

  // K. bitmap subtitles: hand rendering back to IINA, ignore clicks
  p.props["current-tracks/sub/codec"] = "hdmv_pgs_subtitle";
  await sleep(1300);
  assert.strictEqual(p.props["sub-visibility"], "yes");
  assert.strictEqual(p.posted.filter((m) => m.name === "subtitle").at(-1).data.text, "");
  assert.strictEqual(p.mouse.down(at(1)), false);
  p.stop();

  // L. a duplicated message is handled once; a reloaded page is not a duplicate
  p = makePlayer(port);
  p.events["iina.window-loaded"]();
  p.log.length = 0;
  p.messages["ready"]({ seq: "a:1" });
  p.messages["ready"]({ seq: "a:1" });
  assert.strictEqual(p.log.filter((l) => l === "show").length, 1, "one ready for a duplicated delivery");
  p.messages["ready"]({ seq: "b:1" });
  assert.strictEqual(p.log.filter((l) => l === "show").length, 2, "a reloaded page's first message is not dropped");
  p.stop();

  // M. the page never answers -> the plugin loads it again, keeps IINA's own subtitles, then recovers
  p = makePlayer(port);
  await sleep(1700);
  assert.strictEqual(p.log.filter((l) => l.startsWith("loadFile")).length, 2, "retries the overlay load");
  assert.strictEqual(p.props["sub-visibility"], "yes", "does not hide native subtitles while the overlay is missing");
  assert.strictEqual(p.mouse.down(at(1)), false, "and ignores clicks");
  p.events["iina.plugin-overlay-loaded"]();
  assert.deepStrictEqual(p.posted.at(-1), { name: "hello", data: {} });
  p.messages["ready"]({ seq: "c:1" });
  assert.strictEqual(p.props["sub-visibility"], "no");
  assert.deepStrictEqual(p.log.slice(-3), ["clickable:false", "show", "set:sub-visibility=no"]);
  const before = p.posted.filter((m) => m.name === "subtitle").length;
  await sleep(2300);
  assert.ok(p.posted.filter((m) => m.name === "subtitle").length > before, "re-sends the current line periodically");
  p.stop();

  // N. Melingo not running -> message + resume
  await new Promise((r) => bridge.server.close(r));
  bridge.server.closeAllConnections && bridge.server.closeAllConnections();
  p = await boot(port);
  p.log.length = 0;
  p.mouse.down(at(1)); p.mouse.up(at(1));
  await sleep(600);
  assert.strictEqual(p.log[0], "pause");
  assert.ok(p.log[1].startsWith("osd:Melingo is not running"), p.log[1]);
  assert.strictEqual(p.log[2], "resume");
  p.stop();

  console.log("plugin.test.js: all scenarios passed");
  process.exit(0);
})().catch((error) => { console.error(error); process.exit(1); });
