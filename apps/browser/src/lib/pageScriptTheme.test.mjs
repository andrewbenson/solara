import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const script = readFileSync(new URL("../../../../packages/solaracore/ios/page_script.js", import.meta.url), "utf8");
const start = script.indexOf("  const parse = (css) =>");
const end = script.indexOf("  if (window.visualViewport)");
assert.ok(start > 0 && end > start, "page_script.js has the theme block");
const source = script.slice(start, end);

function page({ meta = "#fff", bodyBackground = "rgba(0, 0, 0, 0)", htmlBackground = "rgba(0, 0, 0, 0)", header = null, headerPosition = "static" } = {}) {
  const reports = [];
  const frames = [];
  const observers = [];
  const listeners = [];
  const handlers = {};
  const element = (nodeName, parentElement, background, position = "static") => ({
    nodeName,
    parentElement,
    background,
    position,
    attrs: {},
    getAttribute(name) {
      return this.attrs[name] ?? null;
    },
  });
  const html = element("HTML", null, htmlBackground);
  const body = element("BODY", html, bodyBackground);
  const top = element("DIV", body, header ?? "rgba(0, 0, 0, 0)", headerPosition);
  html.appendChild = () => {};
  class MutationObserver {
    constructor(callback) {
      this.callback = callback;
      this.targets = new Map();
      observers.push(this);
    }
    observe(target, options) {
      this.targets.set(target, options);
    }
  }
  const parseColor = (value) => {
    if (!value) return "";
    if (value.startsWith("rgb")) return value;
    const h = value.length === 4 ? value.replace(/[0-9a-f]/gi, (d) => d + d) : value;
    return `rgb(${parseInt(h.slice(1, 3), 16)}, ${parseInt(h.slice(3, 5), 16)}, ${parseInt(h.slice(5, 7), 16)})`;
  };
  const themeMeta = { getAttribute: (name) => (name === "content" ? meta : null) };
  const context = {
    document: {
      documentElement: html,
      body,
      head: element("HEAD", html, "rgba(0, 0, 0, 0)"),
      querySelectorAll: () => (meta ? [themeMeta] : []),
      createElement: () => ({ style: {}, remove() {} }),
      elementFromPoint: () => top,
      addEventListener() {},
    },
    getComputedStyle: (el) => ({
      backgroundColor: el.background,
      position: el.position,
      colorScheme: "normal",
      color: parseColor(el.style?.color),
    }),
    MutationObserver,
    innerWidth: 1000,
    scrollY: 0,
    performance,
    setTimeout() {},
    clearTimeout() {},
    addEventListener() {},
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    apply: Reflect.apply,
    raf: (fn) => frames.push(fn),
    guard: (fn) => fn,
    handlers,
    listen(type, fn) {
      listeners.push({ target: this, type, fn });
    },
    onReady: (fn) => fn(),
    send: (_kind, data) => reports.push(JSON.parse(JSON.stringify(data))),
  };
  context.window = context;
  runInNewContext(source, context);
  const restyle = (el, background) => {
    const oldValue = el.getAttribute("style");
    el.background = background;
    el.attrs.style = background;
    for (const observer of observers)
      if (observer.targets.get(el)?.attributeFilter?.includes("style")) observer.callback([{ type: "attributes", target: el, attributeName: "style", oldValue }]);
    while (frames.length) frames.shift()();
  };
  const fire = (type) => {
    for (const l of listeners) if (l.target === context.document && l.type === type) l.fn();
  };
  const repaint = (el, background) => {
    el.background = background;
  };
  return { last: () => reports.at(-1), count: () => reports.length, body, restyle, repaint, fire, handlers };
}

test("the page's painted background wins over theme-color", () => {
  assert.deepEqual(page({ meta: "#191a1e", bodyBackground: "rgb(19, 20, 20)" }).last(), { color: "#131414", source: "background" });
});

test("a white theme-color over a dark page follows the page", () => {
  assert.deepEqual(page({ bodyBackground: "rgb(17, 17, 17)" }).last(), { color: "#111111", source: "background" });
});

test("a painted top header wins over theme-color and the page", () => {
  assert.deepEqual(page({ meta: "#1da1f2", bodyBackground: "rgb(255, 255, 255)", header: "rgb(36, 41, 47)", headerPosition: "sticky" }).last(), {
    color: "#24292F",
    source: "header",
  });
});

test("with no painted background or header, theme-color is kept", () => {
  assert.deepEqual(page({ meta: "#0d1117" }).last(), { color: "#0D1117", source: "meta" });
});

test("with nothing painted and no theme-color, the default page colour is reported", () => {
  assert.deepEqual(page({ meta: null }).last(), { color: "#FFFFFF", source: "background" });
});

test("restyling the page follows its painted colour, and theme-color returns once nothing is painted", () => {
  const p = page({ bodyBackground: "rgb(17, 17, 17)" });
  assert.equal(p.last().source, "background");
  p.restyle(p.body, "rgb(31, 31, 31)");
  assert.deepEqual(p.last(), { color: "#1F1F1F", source: "background" });
  p.restyle(p.body, "rgba(0, 0, 0, 0)");
  assert.deepEqual(p.last(), { color: "#FFFFFF", source: "meta" });
});

test("themeRecheck re-reads a colour that changed without a mutation, as a hidden page's prefers-color-scheme flip does", () => {
  const p = page({ bodyBackground: "rgb(28, 28, 28)" });
  assert.deepEqual(p.last(), { color: "#1C1C1C", source: "background" });
  p.repaint(p.body, "rgb(246, 246, 247)");
  p.handlers.themeRecheck();
  assert.deepEqual(p.last(), { color: "#F6F6F7", source: "background" });
});

test("themeRecheck sends nothing when the colour is unchanged", () => {
  const p = page({ bodyBackground: "rgb(28, 28, 28)" });
  const before = p.count();
  p.handlers.themeRecheck();
  assert.equal(p.count(), before);
});

test("a frozen page ignores themeRecheck and rechecks when it resumes", () => {
  const p = page({ bodyBackground: "rgb(28, 28, 28)" });
  p.fire("freeze");
  p.repaint(p.body, "rgb(246, 246, 247)");
  p.handlers.themeRecheck();
  assert.deepEqual(p.last(), { color: "#1C1C1C", source: "background" });
  p.fire("resume");
  assert.deepEqual(p.last(), { color: "#F6F6F7", source: "background" });
});
