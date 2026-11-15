import assert from "node:assert/strict";
import { test } from "node:test";
import { NativePaneFallbackFeed } from "./nativePaneFallbackFeed.ts";

test("late initial reads and ended window generations cannot replace fallback targets", () => {
  let generation = 8;
  const feed = new NativePaneFallbackFeed(() => generation);
  feed.begin("w", {});
  const current = { rootTag: 11, targetGeneration: 2, lease: 2, shown: true };
  assert.equal(feed.accept("w", { windowGeneration: 8, revision: 2, targets: { a: current } }), true);
  assert.equal(feed.accept("w", { windowGeneration: 8, revision: 1, targets: {} }), false);
  assert.equal(feed.read("w").a, current);
  generation = 9;
  assert.equal(feed.accept("w", { windowGeneration: 8, revision: 10, targets: {} }), false);
  assert.equal(feed.accept("w", { windowGeneration: 9, revision: 1, targets: {} }), true);
  assert.deepEqual(feed.read("w"), {});
});

test("a remounted content guest keeps its targets when the prior owner's cleanup arrives", () => {
  const feed = new NativePaneFallbackFeed(() => 4);
  const old = {}, fresh = {};
  feed.begin("w", old);
  feed.begin("w", fresh);
  feed.accept("w", { windowGeneration: 4, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, lease: 1, shown: true } } });
  feed.end("w", old);
  assert.equal(feed.read("w").a.rootTag, 11);
  feed.end("w", fresh);
  assert.deepEqual(feed.read("w"), {});
});

test("a stopped content guest rejects delayed native fallback snapshots", () => {
  const feed = new NativePaneFallbackFeed(() => 8);
  const owner = {};
  feed.begin("w", owner);
  feed.end("w", owner);
  assert.equal(feed.accept("w", { windowGeneration: 8, revision: 2, targets: { a: { rootTag: 11, targetGeneration: 2, lease: 2, shown: true } } }), false);
  assert.deepEqual(feed.read("w"), {});
});

test("skipped React renders still release replaced and removed acquired targets after commit", () => {
  const releases = [];
  const feed = new NativePaneFallbackFeed(() => 8, (...args) => releases.push(args));
  const owner = {};
  feed.begin("w", owner);
  const one = { windowGeneration: 8, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, lease: 1, shown: true } } };
  const two = { windowGeneration: 8, revision: 2, targets: { a: { rootTag: 21, targetGeneration: 2, lease: 2, shown: true } } };
  feed.accept("w", one);
  feed.accept("w", two);
  assert.deepEqual(releases, []);
  feed.flush("w", owner, feed.version("w"));
  assert.deepEqual(releases, [["w", "a", 1, 1]]);
  const version = feed.version("w");
  feed.accept("w", { windowGeneration: 8, revision: 3, targets: {} });
  assert.ok(feed.version("w") > version);
  feed.flush("w", owner, feed.version("w"));
  assert.deepEqual(releases, [["w", "a", 1, 1], ["w", "a", 2, 2]]);
});

test("stopped owners never acquire stale native publications", () => {
  let acquired = 0;
  const feed = new NativePaneFallbackFeed(() => 8);
  const owner = {};
  feed.begin("w", owner);
  feed.end("w", owner);
  const snapshot = { windowGeneration: 8, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, lease: 1, shown: true } } };
  assert.equal(feed.admit("w", snapshot, () => { acquired++; return snapshot; }), false);
  assert.equal(acquired, 0);
});

test("acquisition rejected by a native close still creates a post-commit receipt", () => {
  let generation = 8;
  const releases = [];
  const feed = new NativePaneFallbackFeed(() => generation, (...args) => releases.push(args));
  const owner = {};
  feed.begin("w", owner);
  const snapshot = { windowGeneration: 8, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, lease: 1, shown: true } } };
  const before = feed.version("w");
  assert.equal(feed.admit("w", snapshot, () => { generation = 0; return snapshot; }), false);
  assert.deepEqual(feed.read("w"), {});
  assert.ok(feed.version("w") > before);
  assert.deepEqual(releases, []);
  feed.flush("w", owner, feed.version("w"));
  assert.deepEqual(releases, [["w", "a", 1, 1]]);
});

test("late rejected snapshots cannot release an epoch held by the current portal", () => {
  const releases = [];
  const feed = new NativePaneFallbackFeed(() => 8, (...args) => releases.push(args));
  const owner = {};
  feed.begin("w", owner);
  const target = { rootTag: 11, targetGeneration: 1, lease: 1, shown: true };
  feed.accept("w", { windowGeneration: 8, revision: 2, targets: { a: target } });
  assert.equal(feed.accept("w", { windowGeneration: 8, revision: 1, targets: { a: target } }), false);
  feed.flush("w", owner, feed.version("w"));
  assert.deepEqual(releases, []);
  feed.end("w", owner);
  assert.deepEqual(releases, [["w", "a", 1, 1]]);
});

test("an obsolete publication cannot bypass the atomic native revision check", () => {
  const feed = new NativePaneFallbackFeed(() => 8);
  feed.begin("w", {});
  const snapshot = { windowGeneration: 8, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, lease: 1, shown: true } } };
  assert.equal(feed.admit("w", snapshot, () => null), false);
  assert.deepEqual(feed.read("w"), {});
});

test("an initial offer rejected by the current native stamp never acquires a lease", () => {
  const releases = [];
  const feed = new NativePaneFallbackFeed(() => 8, (...args) => releases.push(args));
  const owner = {};
  feed.begin("w", owner);
  const snapshot = { windowGeneration: 8, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, shown: true } } };
  assert.equal(feed.admit("w", snapshot, () => null), false);
  feed.flush("w", owner, feed.version("w"));
  assert.deepEqual(releases, []);
});

test("ending a guest drains current and never-rendered acquired epochs", () => {
  const releases = [];
  const feed = new NativePaneFallbackFeed(() => 8, (...args) => releases.push(args));
  const owner = {};
  feed.begin("w", owner);
  feed.accept("w", { windowGeneration: 8, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, lease: 1, shown: true } } });
  feed.accept("w", { windowGeneration: 8, revision: 2, targets: { b: { rootTag: 21, targetGeneration: 2, lease: 2, shown: true } } });
  feed.end("w", owner);
  assert.deepEqual(releases, [["w", "a", 1, 1], ["w", "b", 2, 2]]);
});

test("an earlier React commit never releases targets retired by a newer native snapshot", () => {
  const releases = [];
  const feed = new NativePaneFallbackFeed(() => 8, (...args) => releases.push(args));
  const owner = {};
  feed.begin("w", owner);
  feed.accept("w", { windowGeneration: 8, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, lease: 1, shown: true } } });
  const committedVersion = feed.version("w");
  feed.accept("w", { windowGeneration: 8, revision: 2, targets: { a: { rootTag: 21, targetGeneration: 2, lease: 2, shown: true } } });
  feed.flush("w", owner, committedVersion);
  assert.deepEqual(releases, []);
  feed.flush("w", owner, feed.version("w"));
  assert.deepEqual(releases, [["w", "a", 1, 1]]);
});

test("superseded admissions to the same physical target release only their own lease after commit", () => {
  const releases = [];
  const feed = new NativePaneFallbackFeed(() => 8, (...args) => releases.push(args));
  const owner = {};
  feed.begin("w", owner);
  feed.accept("w", { windowGeneration: 8, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, lease: 71, shown: true } } });
  const committedVersion = feed.version("w");
  feed.accept("w", { windowGeneration: 8, revision: 2, targets: { a: { rootTag: 11, targetGeneration: 1, lease: 72, shown: true } } });
  feed.flush("w", owner, committedVersion);
  assert.deepEqual(releases, []);
  feed.flush("w", owner, feed.version("w"));
  assert.deepEqual(releases, [["w", "a", 1, 71]]);
  feed.end("w", owner);
  assert.deepEqual(releases, [["w", "a", 1, 71], ["w", "a", 1, 72]]);
});

test("a delayed old-owner receipt cannot settle the remounted guest's acquisition", () => {
  const releases = [];
  const activeLeases = new Set();
  let nextLease = 80;
  const feed = new NativePaneFallbackFeed(() => 8, (...args) => releases.push(args));
  const offer = { windowGeneration: 8, revision: 1, targets: { a: { rootTag: 11, targetGeneration: 1, shown: true } } };
  const acquire = () => {
    const lease = ++nextLease;
    activeLeases.add(lease);
    return { ...offer, targets: { a: { ...offer.targets.a, lease } } };
  };
  const old = {}, fresh = {};
  feed.begin("w", old);
  feed.admit("w", offer, acquire);
  feed.end("w", old);
  feed.begin("w", fresh);
  feed.admit("w", offer, acquire);
  assert.equal(feed.read("w").a.lease, 82);
  assert.deepEqual(releases, [["w", "a", 1, 81]]);
  activeLeases.delete(releases[0][3]);
  assert.deepEqual([...activeLeases], [82]);
});
