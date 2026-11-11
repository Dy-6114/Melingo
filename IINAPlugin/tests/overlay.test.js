// Runs the overlay page script against a tiny DOM stub and checks word
// splitting, the word boxes it reports, highlighting, and size/position.
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

const html = fs.readFileSync(process.argv[2] + "/overlay.html", "utf8");
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

assert.ok(!html.includes("data-clickable"), "the overlay must never ask for mouse events");

class Node {
  constructor(tag) {
    this.tag = tag; this.children = []; this.parentNode = null; this.attrs = {}; this.className = ""; this.text = "";
    const props = {};
    this.style = { props, setProperty(name, value) { props[name] = value; } };
  }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  removeChild(child) { this.children = this.children.filter((c) => c !== child); child.parentNode = null; }
  get firstChild() { return this.children[0] || null; }
  setAttribute(k, v) { this.attrs[k] = v; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  set textContent(v) { this.text = v; }
  get textContent() { return this.text + this.children.map((c) => c.textContent).join(""); }
  // Fake geometry: words sit side by side, 10 px per character, 30 px high.
  getBoundingClientRect() {
    const siblings = this.parentNode.children.filter((c) => c.tag === "span");
    let left = 100;
    for (const s of siblings) { if (s === this) break; left += s.text.length * 10 + 5; }
    return { left: left + 0.04, top: 800.26, width: this.text.length * 10, height: 30 };
  }
}

function makePage(withSegmenter) {
  const body = new Node("body");
  const cue = new Node("div");
  body.appendChild(cue);
  const root = new Node("html");
  const page = { cue, root, posted: [], seqs: [], handlers: {}, windowListeners: {} };
  const document = {
    body,
    documentElement: root,
    getElementById: () => cue,
    createElement: (tag) => new Node(tag),
    createTextNode: (text) => { const n = new Node("#text"); n.text = text; return n; },
  };
  const window = {
    innerWidth: 1600,
    innerHeight: 900,
    iina: {
      postMessage: (name, data) => {
        const copy = JSON.parse(JSON.stringify({ name, data })); // copy out of the vm realm
        page.seqs.push(copy.data.seq);
        delete copy.data.seq;
        page.posted.push(copy);
      },
      onMessage: (name, fn) => { page.handlers[name] = fn; },
    },
    addEventListener: (name, fn) => { page.windowListeners[name] = fn; },
  };
  const context = vm.createContext({ window, document, setTimeout, Intl: withSegmenter ? Intl : {}, Symbol, String, Math, Date, parseInt, isNaN, isFinite });
  vm.runInContext(script, context, { filename: "overlay.js" });
  page.words = () => cue.children.filter((c) => c.tag === "span");
  page.selected = () => page.words().filter((w) => w.className.includes("selected")).map((w) => w.text);
  page.api = window.__melingoOverlay;
  return page;
}

for (const withSegmenter of [true, false]) {
  const label = withSegmenter ? "Intl.Segmenter" : "regex fallback";
  const page = makePage(withSegmenter);
  assert.deepStrictEqual(page.posted[0], { name: "ready", data: {} });
  assert.deepStrictEqual(Object.keys(page.windowListeners), ["resize"], "no mouse listeners at all");

  const line = "I don’t know, maybe 3.5 km.\nWell—okay!";
  page.posted.length = 0;
  page.handlers["subtitle"]({ text: line });
  const words = page.words();
  assert.deepStrictEqual(words.map((w) => w.text), ["I", "don’t", "know", "maybe", "3.5", "km", "Well", "okay"], label);
  assert.strictEqual(page.cue.children.filter((c) => c.tag === "br").length, 1, "line break kept");
  assert.strictEqual(page.cue.textContent, "I don’t know, maybe 3.5 km.Well—okay!", "no text lost");

  // word boxes reported to the plugin
  assert.strictEqual(page.posted.length, 1);
  const layout = page.posted[0];
  assert.strictEqual(layout.name, "layout");
  assert.strictEqual(layout.data.text, line);
  assert.strictEqual(layout.data.width, 1600);
  assert.strictEqual(layout.data.height, 900);
  assert.strictEqual(layout.data.words.length, 8);
  assert.deepStrictEqual(layout.data.words[0], { start: 0, end: 1, x: 100, y: 800.3, w: 10, h: 30 });
  assert.deepStrictEqual(layout.data.words.map((w) => line.slice(w.start, w.end)), words.map((w) => w.text), "offsets match the words");

  // an unchanged line is not redrawn, but its boxes are reported again
  const firstSpan = page.words()[0];
  page.handlers["subtitle"]({ text: line });
  assert.strictEqual(page.words()[0], firstSpan, "same DOM nodes");
  assert.strictEqual(page.posted.at(-1).name, "layout");
  page.windowListeners.resize();
  assert.strictEqual(page.posted.at(-1).name, "layout", "window resize re-reports the boxes");

  // highlighting is driven by the plugin
  page.handlers["select"]({ from: 1, to: 3 });
  assert.deepStrictEqual(page.selected(), ["don’t", "know", "maybe"]);
  page.handlers["select"]({ from: 2, to: 2 });
  assert.deepStrictEqual(page.selected(), ["know"]);
  page.handlers["clear-selection"]();
  assert.deepStrictEqual(page.selected(), []);
  page.handlers["select"]({ from: 0, to: 1 });
  page.handlers["subtitle"]({ text: "New line" });
  assert.deepStrictEqual(page.selected(), [], "a new line starts unselected");

  // size and position follow IINA's subtitle settings sent with each line
  page.handlers["subtitle"]({ text: "Sized" });
  assert.deepStrictEqual(page.root.style.props, { "--sub-scale": "1", "--sub-size": "6.11vh", "--sub-bottom": "3.06%" }, "defaults sit at the bottom margin");
  page.handlers["subtitle"]({ text: "Sized", scale: 1.5, pos: 50, fontSize: 40, marginY: 22 });
  assert.deepStrictEqual(page.root.style.props, { "--sub-scale": "1.5", "--sub-size": "4.44vh", "--sub-bottom": "53.06%" });
  page.handlers["subtitle"]({ text: "Sized", scale: 99, pos: 150, fontSize: 40, marginY: 0 });
  assert.deepStrictEqual(page.root.style.props, { "--sub-scale": "4", "--sub-size": "4.44vh", "--sub-bottom": "0.00%" }, "values are clamped");
  page.handlers["subtitle"]({ text: "Sized", pos: 100 });
  assert.deepStrictEqual(page.root.style.props, { "--sub-scale": "4", "--sub-size": "4.44vh", "--sub-bottom": "0.00%" }, "missing values keep the last ones");

  page.handlers["subtitle"]({ text: "" });
  assert.strictEqual(page.cue.children.length, 0, "empty cue clears the overlay");
  assert.deepStrictEqual(page.posted.at(-1).data.words, [], "and reports no boxes");

  // the plugin can ask the page to announce itself again
  page.posted.length = 0;
  page.handlers["hello"]();
  assert.deepStrictEqual(page.posted, [{ name: "ready", data: {} }]);
  assert.ok(page.seqs.every((s) => typeof s === "string" && s.includes(":")), "messages are numbered");
  assert.strictEqual(new Set(page.seqs).size, page.seqs.length, "message numbers never repeat");
}

// Languages without spaces need the segmenter.
const page = makePage(true);
const ja = page.api.tokenize("私は学生です。").filter((t) => t.isWord).map((t) => t.text);
assert.ok(ja.length >= 3, "Japanese splits into several words: " + ja.join("|"));
const zh = page.api.tokenize("我喜欢看电影").filter((t) => t.isWord).map((t) => t.text);
assert.ok(zh.length >= 3, "Chinese splits into several words: " + zh.join("|"));
console.log("overlay.test.js: all checks passed (ja: " + ja.join("|") + "  zh: " + zh.join("|") + ")");
