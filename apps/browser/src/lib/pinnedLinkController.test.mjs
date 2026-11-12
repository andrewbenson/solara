import assert from "node:assert/strict";
import { test } from "node:test";
import { pinnedLinkController } from "./pinnedLinkController.ts";
import { pinnedLinkSourceIds } from "./pinnedLinks.ts";

function fixture(target = "peek") {
  let source = { id: "pin", identity: "window:profile:https://mail.google.com/", url: "https://mail.google.com/", pinned: true, topApp: false, target, incognito: false };
  let present = true;
  let time = 0;
  const answers = [];
  const opens = [];
  const handle = pinnedLinkController({
    source: (id) => id === "pin" ? source : null,
    present: (id) => id === "pin" && present,
    answer: async (...args) => { answers.push(args); return true; },
    open: (...args) => opens.push(args),
    now: () => time,
  });
  const event = { phase: "decide", requestId: "request", sourceId: "pin", sourceURL: source.url, url: "https://www.google.com/url?q=https%3A%2F%2Fexample.org%2Fstory", newWindow: false };
  return { handle, answers, opens, event, setSource: (next) => { source = next; }, source: () => source, setPresent: (value) => { present = value; }, advance: (ms) => { time += ms; } };
}

for (const target of ["peek", "tab", "littleSolara"]) {
  test(`routes ${target} only after the engine says it cancelled the navigation`, () => {
    const f = fixture(target);
    f.handle(f.event);
    assert.deepEqual(f.answers, [["request", true]]);
    assert.equal(f.opens.length, 0);
    f.handle({ ...f.event, phase: "intercepted", point: { x: 120, y: 80 } });
    assert.equal(f.opens.length, 1);
    assert.equal(f.opens[0][1], f.event.url, "the wrapper itself opens, so its link scan still runs");
    assert.equal(f.opens[0][2], target);
    assert.deepEqual(f.opens[0][3], { x: 120, y: 80 });
    f.handle({ ...f.event, phase: "intercepted" });
    assert.equal(f.opens.length, 1);
  });
}

test("a new-window link takes the same path and opens no provisional tab", () => {
  const f = fixture();
  f.handle({ ...f.event, newWindow: true });
  assert.equal(f.opens.length, 0);
  f.handle({ ...f.event, newWindow: true, phase: "intercepted" });
  assert.equal(f.opens.length, 1);
  assert.equal(f.opens[0][0].id, "pin");
  assert.equal(f.opens[0][3], null);
});

test("unpinned, same-site and stale-source requests continue normally", () => {
  for (const mode of ["unpinned", "same-site", "stale", "missing"]) {
    const f = fixture();
    if (mode === "unpinned") f.setSource({ ...f.source(), pinned: false });
    if (mode === "missing") f.setSource(null);
    f.handle({ ...f.event, ...(mode === "same-site" ? { url: "https://docs.google.com/document" } : {}), ...(mode === "stale" ? { sourceURL: "https://old.example/" } : {}) });
    assert.deepEqual(f.answers, [["request", false]], mode);
    f.handle({ ...f.event, phase: "intercepted" });
    assert.equal(f.opens.length, 0, mode);
  }
});

test("Top Apps qualify, and Little Solara from a private window opens a private tab instead", () => {
  const f = fixture("littleSolara");
  f.setSource({ ...f.source(), pinned: false, topApp: true, incognito: true });
  f.handle(f.event);
  f.handle({ ...f.event, phase: "intercepted" });
  assert.equal(f.opens[0][2], "tab");
});

test("after the engine cancelled, a source that moved on still gets the link, in a background tab", () => {
  for (const mode of ["switch", "navigate"]) {
    const f = fixture();
    f.handle(f.event);
    if (mode === "switch") f.setSource(null);
    else f.setSource({ ...f.source(), url: "https://mail.google.com/new", identity: "changed" });
    f.handle({ ...f.event, phase: "intercepted", point: { x: 1, y: 2 } });
    assert.equal(f.opens.length, 1, mode);
    assert.equal(f.opens[0][0].id, "pin");
    assert.equal(f.opens[0][1], f.event.url, "the wrapper itself opens, so its link scan still runs");
    assert.equal(f.opens[0][2], "background");
    assert.equal(f.opens[0][3], null);
  }
});

test("after the engine cancelled, a closed source or window drops the link and opens nothing", () => {
  const f = fixture();
  f.handle(f.event);
  f.setSource(null);
  f.setPresent(false);
  f.handle({ ...f.event, phase: "intercepted" });
  assert.equal(f.opens.length, 0);
});

test("unpinning after the decision keeps the chosen target: the click happened on a pinned page", () => {
  const f = fixture();
  f.handle(f.event);
  f.setSource({ ...f.source(), pinned: false, topApp: false });
  f.handle({ ...f.event, phase: "intercepted" });
  assert.equal(f.opens[0][2], "peek");
});

test("an acknowledgment that is late, unsolicited or for an expired decision opens nothing", () => {
  const f = fixture();
  f.handle({ ...f.event, phase: "intercepted" });
  assert.equal(f.opens.length, 0);
  f.handle(f.event);
  f.advance(29000);
  f.handle({ ...f.event, requestId: "other", phase: "intercepted" });
  f.handle({ ...f.event, phase: "intercepted" });
  assert.equal(f.opens.length, 1, "a slow bridge within the decision lifetime still routes");
  const g = fixture();
  g.handle(g.event);
  g.advance(30001);
  g.handle({ ...g.event, phase: "intercepted" });
  assert.equal(g.opens.length, 0);
});

test("native refusal and a rejected reply clear the pending route", async () => {
  for (const answer of [async () => false, async () => { throw Error("gone"); }]) {
    const opens = [];
    const f = fixture();
    const handle = pinnedLinkController({ source: () => f.source(), present: () => true, answer, open: (...args) => opens.push(args) });
    handle(f.event);
    await Promise.resolve();
    await Promise.resolve();
    handle({ ...f.event, phase: "intercepted" });
    assert.equal(opens.length, 0);
  }
});

test("duplicate decisions cannot overwrite or replay an accepted request", async () => {
  const f = fixture();
  f.handle(f.event);
  f.handle({ ...f.event, url: "https://different.example/" });
  assert.deepEqual(f.answers, [["request", true]]);
  await Promise.resolve();
  f.handle({ ...f.event, phase: "intercepted" });
  assert.equal(f.opens.length, 1);
  assert.equal(f.opens[0][1], f.event.url, "the wrapper itself opens, so its link scan still runs");
  f.handle(f.event);
  f.handle({ ...f.event, phase: "intercepted" });
  assert.equal(f.opens.length, 1);
});

test("a hash route change on the pinned page doesn't refuse the click", () => {
  const f = fixture();
  f.handle({ ...f.event, sourceURL: "https://mail.google.com/#inbox/123" });
  assert.deepEqual(f.answers, [["request", true]]);
  f.handle({ ...f.event, phase: "intercepted", sourceURL: "https://mail.google.com/#inbox/456" });
  assert.equal(f.opens[0][2], "peek");
});

test("pinned link sources are the pinned tabs of main windows, not pinned-group members or Little Solara", () => {
  const tabs = {
    tile: { id: "tile", windowId: "w1", pinned: true },
    row: { id: "row", windowId: "w1", pinned: true, pinnedAsRow: true },
    member: { id: "member", windowId: "w1", pinned: false },
    plain: { id: "plain", windowId: "w1", pinned: false },
    late: { id: "late", windowId: "w1", pinned: true },
    small: { id: "small", windowId: "w2", pinned: true },
    moved: { id: "moved", windowId: "w3", pinned: true },
  };
  const windows = {
    w1: { id: "w1", kind: "normal", tabIds: ["tile", "member", "row", "plain", "late", "moved"] },
    w2: { id: "w2", kind: "small", tabIds: ["small"] },
    w3: { id: "w3", kind: "normal", tabIds: ["moved"] },
  };
  assert.deepEqual(pinnedLinkSourceIds({ tabs, windows }), ["late", "moved", "row", "tile"]);
});
