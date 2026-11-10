import assert from "node:assert/strict";
import { test } from "node:test";
import { createKeepAliveFeed, keepAliveCreated, keepAliveHandled, keepAliveFailed, keepAliveGone, observeKeepAlive } from "./keepAliveFeed.ts";

const identity = { tabId: "t", sessionGeneration: "G", registrationGeneration: 1 };
const facts = () => ({ route: "p/w", keep: { capturing: false, newTabShown: false, pip: false, displayRequest: false, media: "none" }, reveal: { fullscreen: false, crashed: false, unresponsive: false, scrolledDown: false, sharing: false } });
function fixture() {
  let running = true;
  let epoch = 0;
  let snapshot = facts();
  const jobs = [];
  const sent = [];
  const feed = createKeepAliveFeed({ running: () => running, register: () => ++epoch, read: () => snapshot, send: (id, report) => sent.push({ id, ...report }), schedule: (job) => jobs.push(job) });
  const flush = () => { while (jobs.length) jobs.shift()(); };
  return { feed, sent, flush, epoch: () => epoch, setRunning: (value) => { running = value; }, setSnapshot: (value) => { snapshot = value; }, snapshot: () => snapshot };
}

function guardedFixture() {
  let running = true;
  let epoch = 0;
  const snapshots = new Map([["t", facts()], ["other", facts()]]);
  const blocked = new Set();
  const validated = [];
  const waiting = [];
  const jobs = [];
  const sent = [];
  const feed = createKeepAliveFeed({
    running: () => running,
    register: () => ++epoch,
    read: (value) => snapshots.get(value.tabId) ?? null,
    ready: (value) => { validated.push({ ...value }); return !blocked.has(value.tabId); },
    send: (id, report) => sent.push(JSON.parse(JSON.stringify({ id, ...report }))),
    schedule: (job) => jobs.push(job),
    waiting: (pending) => waiting.push(pending),
  });
  const flush = () => { while (jobs.length) jobs.shift()(); };
  return { feed, sent, flush, validated, waiting, blocked, snapshots, setRunning: (value) => { running = value; } };
}

test("unchanged pages skip native validation while a changed acknowledgement validates only its page", () => {
  const f = guardedFixture();
  f.feed.created(identity, "pool");
  f.feed.created({ ...identity, tabId: "other" }, "pool");
  f.flush();
  assert.deepEqual(f.validated.map((value) => value.tabId), ["t", "other"]);
  f.validated.length = 0;
  f.feed.changed();
  f.flush();
  assert.equal(f.validated.length, 0);
  assert.equal(f.sent.length, 2);
  f.feed.handled(identity, 7);
  f.flush();
  assert.deepEqual(f.validated.map((value) => value.tabId), ["t"]);
  assert.equal(f.sent.length, 3);
  assert.equal(f.sent.at(-1).handled, 7);
  assert.equal(f.sent.at(-1).id, "t");
});

test("readiness pending cannot publish changed facts and retries the same snapshot until it can send", () => {
  const f = guardedFixture();
  f.feed.created(identity, "pool");
  f.flush();
  f.blocked.add("t");
  f.snapshots.get("t").keep.capturing = true;
  f.feed.handled(identity, 9);
  f.flush();
  assert.equal(f.sent.length, 1);
  assert.equal(f.waiting.at(-1), true);
  f.feed.changed();
  f.flush();
  assert.equal(f.sent.length, 1);
  assert.equal(f.waiting.at(-1), true);
  f.blocked.delete("t");
  f.feed.changed();
  f.flush();
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent.at(-1).keep.capturing, true);
  assert.equal(f.sent.at(-1).handled, 9);
  assert.equal(f.waiting.at(-1), false);
});

test("readiness that stops the runner cannot send a report", () => {
  let running = true;
  const jobs = [];
  const sent = [];
  const feed = createKeepAliveFeed({
    running: () => running,
    register: () => 1,
    read: facts,
    ready: () => { running = false; return true; },
    send: (id, report) => sent.push({ id, ...report }),
    schedule: (job) => jobs.push(job),
  });
  feed.created(identity, "pool");
  while (jobs.length) jobs.shift()();
  assert.equal(sent.length, 0);
});

test("same-value route changes validate before resending", () => {
  const f = guardedFixture();
  f.feed.created(identity, "pool");
  f.flush();
  f.validated.length = 0;
  f.blocked.add("t");
  f.snapshots.get("t").route = "p/second-window";
  f.feed.changed();
  f.flush();
  assert.deepEqual(f.validated, [identity]);
  assert.equal(f.sent.length, 1);
  f.blocked.delete("t");
  f.feed.changed();
  f.flush();
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent.at(-1).seq, 2);
});

test("runtime renewal and runner restart validate every page even when their JS facts are unchanged", () => {
  const f = guardedFixture();
  f.feed.created(identity, "rn");
  f.feed.created({ ...identity, tabId: "other" }, "pool");
  f.flush();
  f.validated.length = 0;
  f.feed.created({ ...identity, registrationGeneration: 2 }, "rn");
  f.feed.handled(identity, 99);
  f.flush();
  assert.deepEqual(f.validated, [{ ...identity, registrationGeneration: 2 }, { ...identity, tabId: "other" }]);
  assert.deepEqual(f.sent.slice(-2).map((value) => [value.epoch, value.seq, value.handled]), [[2, 1, 0], [2, 2, 0]]);
  f.validated.length = 0;
  f.setRunning(false);
  f.feed.changed();
  f.flush();
  assert.equal(f.validated.length, 0);
  f.setRunning(true);
  f.feed.changed();
  f.flush();
  assert.deepEqual(f.validated.map((value) => value.tabId), ["t", "other"]);
  assert.deepEqual(f.sent.slice(-2).map((value) => value.epoch), [3, 3]);
});

test("changes coalesce into full typed feeds with increasing sequence and only handled UI events", () => {
  const f = fixture();
  f.feed.created(identity, "pool");
  f.flush();
  assert.equal(f.sent.length, 1);
  assert.equal(f.sent[0].handled, 0);
  f.snapshot().keep.capturing = true;
  f.feed.changed();
  f.feed.handled(identity, 7);
  f.feed.changed();
  f.flush();
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent[1].keep.capturing, true);
  assert.equal(f.sent[1].seq, f.sent[0].seq + 1);
  assert.equal(f.sent[1].handled, 7);
  f.feed.changed();
  f.flush();
  assert.equal(f.sent.length, 2);
});

test("close and discard drop queued and cached snapshots", () => {
  for (const reason of ["close", "discard"]) {
    const f = fixture();
    f.feed.created(identity, "pool");
    f.flush();
    f.snapshot().keep.capturing = true;
    f.feed.changed();
    f.setSnapshot(null);
    if (reason === "close") f.feed.gone(identity);
    f.flush();
    assert.equal(f.sent.length, 1, reason);
    f.setSnapshot(facts());
    f.feed.changed();
    f.flush();
    assert.equal(f.sent.length, reason === "close" ? 1 : 2, reason);
    if (reason === "discard") {
      assert.equal(f.sent[1].keep.capturing, false);
      assert.equal(f.sent[1].seq, 2);
    }
  }
});

test("moves recompute the current routing feed and created requests a fresh full resend", () => {
  const f = fixture();
  f.feed.created(identity, "pool");
  f.flush();
  f.snapshot().route = "p/other";
  f.snapshot().keep.pip = true;
  f.feed.changed();
  f.flush();
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent[1].keep.pip, true);
  f.feed.created(identity, "pool");
  f.flush();
  assert.equal(f.sent.length, 3);
  assert.equal(f.sent[2].seq, 3);
  f.feed.created(identity, "pool");
  f.flush();
  assert.equal(f.sent[3].seq, 4);
});

test("old identity callbacks cannot acknowledge or resurrect replaced pages", () => {
  const f = fixture();
  f.feed.created(identity, "pool");
  f.flush();
  const next = { ...identity, sessionGeneration: "next", registrationGeneration: 2 };
  f.feed.created(next, "pool");
  f.feed.handled(identity, 99);
  f.flush();
  assert.equal(f.sent.at(-1).generation, "next");
  assert.equal(f.sent.at(-1).handled, 0);
  f.feed.gone(identity);
  f.feed.changed();
  f.flush();
  assert.equal(f.sent.length, 2);
});

test("RN re-registration starts a new epoch and republishes every current page", () => {
  const f = fixture();
  f.feed.created(identity, "rn");
  f.feed.created({ ...identity, tabId: "other" }, "pool");
  f.flush();
  assert.equal(f.epoch(), 1);
  f.feed.created({ ...identity, registrationGeneration: 2 }, "rn");
  f.flush();
  assert.equal(f.epoch(), 2);
  assert.deepEqual(f.sent.slice(-2).map((x) => x.epoch), [2, 2]);
  assert.deepEqual(f.sent.slice(-2).map((x) => x.seq), [1, 2]);
});

test("runner off registers and sends nothing including queued changes", () => {
  const f = fixture();
  f.setRunning(false);
  f.feed.created(identity, "rn");
  f.feed.changed();
  f.flush();
  assert.equal(f.epoch(), 0);
  assert.equal(f.sent.length, 0);
  f.setRunning(true);
  f.feed.changed();
  f.flush();
  assert.equal(f.sent.length, 1);
  f.feed.changed();
  f.setRunning(false);
  f.flush();
  assert.equal(f.sent.length, 1);
});


test("a failed UI handler keeps later event acknowledgments protective until a new native session", () => {
  const f = fixture();
  f.feed.created(identity, "pool");
  f.flush();
  f.feed.failed(identity);
  f.feed.handled(identity, 9);
  f.snapshot().keep.capturing = false;
  f.flush();
  assert.equal(f.sent.length, 1);
  f.feed.created(identity, "pool");
  f.flush();
  assert.equal(f.sent.length, 1);
  f.feed.created({ ...identity, sessionGeneration: "new", registrationGeneration: 2 }, "pool");
  f.flush();
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent.at(-1).handled, 0);
});


test("observer bootstrap retains handled events and handler failures processed before producer startup", () => {
  const early = { ...identity, tabId: "bootstrap" };
  keepAliveCreated(early, "pool");
  keepAliveHandled(early, 8);
  keepAliveFailed(early);
  const observed = [];
  const stop = observeKeepAlive({ created: (value) => observed.push(["created", value.tabId]), handled: (value, seq) => observed.push(["handled", value.tabId, seq]), failed: (value) => observed.push(["failed", value.tabId]), gone: () => {} });
  assert.deepEqual(observed.filter((value) => value[1] === "bootstrap"), [["created", "bootstrap"], ["handled", "bootstrap", 8], ["failed", "bootstrap"]]);
  stop();
  keepAliveGone(early);
});
