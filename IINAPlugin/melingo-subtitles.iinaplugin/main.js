// Melingo Subtitles — IINA plugin entry script (one instance per player window).
//
// What it does:
//   1. Reads the current subtitle line from mpv and draws it in a web overlay,
//      one <span> per word (IINA's own subtitles are bitmap-rendered and
//      cannot be selected).
//   2. Watches mouse presses and drags in the player window, works out which
//      words they cover, and pauses playback the moment a selection starts.
//   3. Sends the selection to Melingo over a loopback HTTP bridge; Melingo shows
//      the lookup panel.
//   4. Resumes playback when Melingo reports that the panel was closed.
//
// The bridge lives in Melingo: App/Services/IINABridge/IINABridgeController.swift

const { core, event, mpv, overlay, http, console, input } = iina;

const BRIDGE = "http://127.0.0.1:51730";
const BRIDGE_HEADERS = { "X-Melingo-Bridge": "1" };
const SUBTITLE_POLL_MS = 100;
const TRACK_POLL_MS = 1000;
const STATUS_POLL_MS = 300;
const RESYNC_MS = 2000;          // re-send the current line this often, in case a message was lost
// In IINA 1.5.1 the first loadFile() after the plugin starts never produces a
// working page, so an unanswered load is repeated after this long.
const OVERLAY_RETRY_MS = 1200;
const OVERLAY_MAX_ATTEMPTS = 8;
const HIT_SLOP = 3;            // px around a word that still counts as on it
const DRAG_SETTLE_MS = 350;    // IINA reports no mouse-up after a drag, so a drag
                               // counts as finished once the pointer rests this long
const PRESS_TIMEOUT_MS = 1500; // a press with no mouse-up and no drag is treated as a click

// Bitmap subtitle formats: mpv has no text for these, so leave them to IINA.
const IMAGE_CODECS = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"];

let overlayRequestedAt = 0;   // when loadFile() was last called (0 = never)
let overlayLoadAttempts = 0;
let overlayReady = false;     // the overlay page itself reported that it is listening
let lastText = null;
let lastStyleKey = null;
let lastPostAt = 0;
const lastSeq = {};           // last message number handled, per message name
let lastTrackCheck = 0;
let overlayOwnsSubtitles = false; // true while we hide IINA's own rendering

// A "session" spans from the first mouse-down on a word until the lookup
// panel closes. `resumeWhenDone` remembers whether the video was playing.
let session = null;
let activeLookupId = null;
let generation = 0; // bumped to invalidate in-flight requests and polls

// Word boxes reported by the overlay page: { text, width, height, words: [{start,end,x,y,w,h}] }
// in page pixels from the top-left corner.
let layout = null;
// The selection being made with the mouse: { anchor, focus, lookedUp }.
let drag = null;
let settleTimer = 0; // bumped to cancel a pending "selection finished" timer

// ---------------------------------------------------------------- helpers

function readString(name) {
  try {
    const value = mpv.getString(name);
    return typeof value === "string" ? value : "";
  } catch (error) {
    return "";
  }
}

function readNumber(name, fallback) {
  try {
    const value = mpv.getNumber(name);
    return typeof value === "number" && isFinite(value) ? value : fallback;
  } catch (error) {
    return fallback;
  }
}

function collapse(text) {
  return String(text || "").replace(/\s+/g, " ").trim();
}

function parseBody(response) {
  if (!response) return {};
  if (response.data && typeof response.data === "object") return response.data;
  try {
    return JSON.parse(response.text || "{}") || {};
  } catch (error) {
    return {};
  }
}

function bridgeGet(path, params) {
  return http.get(BRIDGE + path, { params: params, headers: BRIDGE_HEADERS });
}

function dismissPanel() {
  try {
    bridgeGet("/dismiss", { id: activeLookupId || "" }).catch(function () {});
  } catch (error) {
    // Melingo is gone; nothing to dismiss.
  }
}

// ------------------------------------------------------- subtitle mirroring

function subtitleTrackIsText() {
  const sid = readString("sid");
  if (sid === "no" || sid === "") return false;
  const codec = readString("current-tracks/sub/codec").toLowerCase();
  return IMAGE_CODECS.indexOf(codec) === -1;
}

function refreshTrackState() {
  if (!overlayReady) return; // never hide IINA's subtitles before ours can be drawn
  const shouldOwn = subtitleTrackIsText();
  if (shouldOwn) {
    // Re-assert: IINA can switch native subtitles back on (new file, new track).
    if (readString("sub-visibility") !== "no") mpv.set("sub-visibility", "no");
  } else if (overlayOwnsSubtitles) {
    mpv.set("sub-visibility", "yes");
  }
  overlayOwnsSubtitles = shouldOwn;
}

// IINA's own subtitle settings, read from mpv, so the controls in IINA's
// Subtitles panel (Position, Scale, Font size) also apply to the selectable line.
function readStyle() {
  return {
    scale: readNumber("sub-scale", 1),
    pos: readNumber("sub-pos", 100),          // 100 = bottom, lower = further up
    fontSize: readNumber("sub-font-size", 55), // in mpv units: pixels on a 720-high screen
    marginY: readNumber("sub-margin-y", 22),   // gap below the line, same units
  };
}

function postSubtitle(force) {
  if (!overlayReady) return;
  const text = overlayOwnsSubtitles ? readString("sub-text").replace(/\r\n?/g, "\n").trim() : "";
  const style = readStyle();
  const styleKey = [style.scale, style.pos, style.fontSize, style.marginY].join("|");
  const now = Date.now();
  const unchanged = text === lastText && styleKey === lastStyleKey;
  if (!force && unchanged && now - lastPostAt < RESYNC_MS) return;
  lastText = text;
  lastStyleKey = styleKey;
  lastPostAt = now;
  // The page ignores a line it already shows, so repeats are harmless.
  overlay.postMessage("subtitle", {
    text: text,
    scale: style.scale,
    pos: style.pos,
    fontSize: style.fontSize,
    marginY: style.marginY,
  });
}

function tick() {
  const now = Date.now();
  if (!overlayReady) loadOverlay(); // throttled; retries a page that never answered
  if (now - lastTrackCheck >= TRACK_POLL_MS) {
    lastTrackCheck = now;
    refreshTrackState();
  }
  postSubtitle(false);
}

// ---------------------------------------------------------------- sessions

function beginSession() {
  generation += 1; // a newer selection supersedes any lookup still on screen
  activeLookupId = null;
  if (!session) session = { resumeWhenDone: !core.status.paused };
  if (!core.status.paused) core.pause();
}

function endSession(resume) {
  const finished = session;
  session = null;
  drag = null;
  settleTimer += 1;
  activeLookupId = null;
  generation += 1;
  if (overlayReady) overlay.postMessage("clear-selection", {});
  if (resume && finished && finished.resumeWhenDone && core.status.paused) core.resume();
}

function fail(message) {
  core.osd(message);
  endSession(true);
}

async function lookup(data) {
  const text = collapse(data && data.text);
  if (!text) {
    endSession(true);
    return;
  }
  if (!session) beginSession();
  generation += 1;
  const mine = generation;

  let response = null;
  try {
    response = await bridgeGet("/lookup", {
      text: text,
      context: collapse(data && data.context),
      title: collapse(core.status.title),
      position: String(core.status.position || 0),
      trackLang: readString("current-tracks/sub/lang"),
    });
  } catch (error) {
    response = null;
  }
  if (mine !== generation) return; // superseded while waiting

  const body = parseBody(response);
  if (!response || response.statusCode !== 200 || !body.id) {
    if (body.error === "not-ready") fail("Melingo is still starting up — try again in a moment");
    else if (response && response.statusCode) fail("Melingo refused the lookup (" + response.statusCode + ")");
    else fail("Melingo is not running — open Melingo to look up words");
    return;
  }

  activeLookupId = String(body.id);
  setTimeout(function () { pollStatus(mine); }, STATUS_POLL_MS);
}

async function pollStatus(mine) {
  if (mine !== generation || !session) return;

  // The user pressed play themselves: close the panel, leave playback alone.
  if (!core.status.paused) {
    dismissPanel();
    endSession(false);
    return;
  }

  let state = "closed";
  try {
    const response = await bridgeGet("/status", { id: activeLookupId || "" });
    const body = parseBody(response);
    if (response && response.statusCode === 200 && body.state) state = body.state;
  } catch (error) {
    state = "closed"; // Melingo quit: do not leave the video stuck on pause
  }
  if (mine !== generation) return;

  if (state === "open") setTimeout(function () { pollStatus(mine); }, STATUS_POLL_MS);
  else endSession(true);
}

// ------------------------------------------------------------------- mouse
//
// The overlay is never made clickable. In IINA 1.5.1 a clickable overlay runs a
// nested run loop inside every hit test, and that crashes IINA when macOS asks
// for a hit test in the middle of a display update (seen while dragging a
// slider in the side panel). The plugin listens to the player window's own
// mouse events instead and does the hit testing itself.

// Mouse events arrive in window points measured from the bottom-left corner;
// word boxes are in page pixels from the top-left corner.
function toPagePoint(data) {
  if (!layout || !data) return null;
  let frame = null;
  try {
    frame = core.window.frame;
  } catch (error) {
    frame = null;
  }
  const width = frame && frame.width > 0 ? frame.width : layout.width;
  const height = frame && frame.height > 0 ? frame.height : layout.height;
  return {
    x: (data.x / width) * layout.width,
    y: (1 - data.y / height) * layout.height,
  };
}

// Index of the word closest to a point, or -1 if none lies within maxDistance.
function wordAt(point, maxDistance) {
  if (!layout || !point) return -1;
  let best = -1;
  let bestDistance = Infinity;
  for (let i = 0; i < layout.words.length; i += 1) {
    const box = layout.words[i];
    const dx = Math.max(box.x - point.x, 0, point.x - (box.x + box.w));
    const dy = Math.max(box.y - point.y, 0, point.y - (box.y + box.h));
    // Vertical distance counts double so a drag stays on its own line.
    const distance = Math.sqrt(dx * dx + 4 * dy * dy);
    if (distance < bestDistance) {
      best = i;
      bestDistance = distance;
    }
  }
  return bestDistance <= maxDistance ? best : -1;
}

function selectionReady() {
  return overlayReady && overlayOwnsSubtitles && layout && layout.words &&
    layout.words.length > 0 && layout.text === lastText;
}

function postSelection() {
  if (!drag) return;
  overlay.postMessage("select", {
    from: Math.min(drag.anchor, drag.focus),
    to: Math.max(drag.anchor, drag.focus),
  });
}

function settleAfter(delay) {
  settleTimer += 1;
  const mine = settleTimer;
  setTimeout(function () {
    if (mine === settleTimer) finishSelection();
  }, delay);
}

function finishSelection() {
  settleTimer += 1;
  if (!drag || !layout) return;
  const lo = Math.min(drag.anchor, drag.focus);
  const hi = Math.max(drag.anchor, drag.focus);
  if (lo < 0 || hi >= layout.words.length) {
    endSession(true);
    return;
  }
  const key = lo + ":" + hi;
  if (drag.lookedUp === key) return; // already looked up exactly this range
  drag.lookedUp = key;
  lookup({
    text: layout.text.slice(layout.words[lo].start, layout.words[hi].end),
    context: layout.text,
  });
}

function onMouseDown(data) {
  settleTimer += 1;
  drag = null;
  if (!selectionReady()) return false;
  const index = wordAt(toPagePoint(data), HIT_SLOP);
  if (index < 0) return false; // not on a word: leave the click to IINA
  drag = { anchor: index, focus: index, lookedUp: null };
  beginSession();
  postSelection();
  settleAfter(PRESS_TIMEOUT_MS);
  return true;
}

function onMouseDrag(data) {
  if (!drag || !layout) return false;
  const index = wordAt(toPagePoint(data), Infinity);
  if (index >= 0 && index !== drag.focus) {
    drag.focus = index;
    postSelection();
  }
  settleAfter(DRAG_SETTLE_MS);
  return false;
}

function onMouseUp() {
  if (!drag) return false;
  finishSelection();
  return true; // also stops IINA's own single-click and double-click actions
}

function installMouseHandlers() {
  try {
    input.onMouseDown(input.MOUSE, onMouseDown, input.PRIORITY_HIGH);
    input.onMouseUp(input.MOUSE, onMouseUp, input.PRIORITY_HIGH);
    input.onMouseDrag(input.MOUSE, onMouseDrag, input.PRIORITY_LOW);
  } catch (error) {
    console.log("Melingo Subtitles: mouse input is not available (" + error + ")");
  }
}

// ----------------------------------------------------------------- overlay

function overlayBecameReady() {
  overlayReady = true;
  // Repeat these now that the page exists; an early call can be lost.
  overlay.setClickable(false);
  overlay.show();
  lastTrackCheck = Date.now();
  refreshTrackState();
  postSubtitle(true);
}

// Registers a handler that ignores a repeat of the same numbered message, so it
// stays correct whether IINA replaces or stacks handlers when the page reloads.
function onOverlayMessage(name, handler) {
  overlay.onMessage(name, function (data) {
    const seq = data && data.seq;
    if (seq !== undefined && seq === lastSeq[name]) return;
    lastSeq[name] = seq;
    handler(data);
  });
}

function loadOverlay() {
  if (overlayReady) return;
  const now = Date.now();
  if (overlayRequestedAt && now - overlayRequestedAt < OVERLAY_RETRY_MS) return;
  if (overlayLoadAttempts >= OVERLAY_MAX_ATTEMPTS) return;
  overlayRequestedAt = now;
  overlayLoadAttempts += 1;
  try {
    overlay.loadFile("overlay.html");
    onOverlayMessage("ready", overlayBecameReady);
    onOverlayMessage("layout", function (data) { layout = data || null; });
    overlay.setClickable(false);
    overlay.show();
  } catch (error) {
    console.log("Melingo Subtitles: overlay not available yet (" + error + ")");
  }
}

// A window or file event is a good moment to try again from scratch.
function reloadOverlayIfMissing() {
  if (overlayReady) return;
  overlayRequestedAt = 0;
  overlayLoadAttempts = 0;
  loadOverlay();
}

event.on("iina.window-loaded", reloadOverlayIfMissing);

// The page finished loading: ask it to announce itself (it answers "ready").
event.on("iina.plugin-overlay-loaded", function () {
  overlay.postMessage("hello", {});
});

event.on("iina.file-loaded", function () {
  reloadOverlayIfMissing();
  if (session) {
    dismissPanel();
    endSession(false);
  }
  lastText = null;
  lastTrackCheck = 0;
});

installMouseHandlers();
setInterval(tick, SUBTITLE_POLL_MS); // also loads the overlay when the plugin starts in an open window
console.log("Melingo Subtitles loaded");
