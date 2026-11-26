import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { compare } from "./sidebar-oracle.mjs";

const manifest = JSON.parse(readFileSync(new URL("./sidebar-parity-cases.json", import.meta.url), "utf8"));
const find = (name) => manifest.cases.find((entry) => entry.name === name);

test("strict oracles reject missing fields, extra fields, changed notes, counts and reordered arrays", () => {
  const expected = find("Arc-selected").expected.swift;
  const changes = [
    (value) => { delete value.outcome.status.spaces; },
    (value) => { value.outcome.status.extra = "done"; },
    (value) => { value.outcome.notes.push("unexplained"); },
    (value) => { value.outcome.counts.tabs = 0; },
    (value) => { value.state.tabs.reverse(); },
    (value) => { value.state.tabs[0].unloaded = false; },
    (value) => { value.state.tabs[0].pinnedUrl = null; },
    (value) => { value.state.groups[0].path = "Wrong"; },
    (value) => { value.state.profiles[0].dataClass = 1; },
  ];
  for (const change of changes) {
    const actual = structuredClone(expected);
    change(actual);
    assert.throws(() => compare(actual, expected));
  }
});

test("Refused pins exact outcomes for both routes instead of suppressing differences", () => {
  const fixture = find("Refused");
  assert.equal(fixture.oracle, "route-specific");
  assert.equal(fixture.source.spaces.length, 1);
  assert.equal(fixture.source.spaces[0].name, "Refused");
  assert.equal(fixture.source.spaces[0].pins.length, 1);
  assert.equal(fixture.source.spaces[0].tabs.length, 1);
  assert.equal(fixture.source.icons, undefined);
  assert.deepEqual(fixture.expected.swift.outcome.status, { tabs: "failed", spaces: "failed", pinnedTabs: "failed" });
  assert.deepEqual(fixture.expected.swift.outcome.failures, ["tabs", "spaces", "pinnedTabs"].map((kind) => ({ kind, profiles: [] })));
  assert.deepEqual(fixture.expected.swift.outcome.notes, ["Nothing from Refused was imported, because Solara couldn't save its workspace."]);
  assert.deepEqual(fixture.expected.script.outcome.status, { tabs: "done", spaces: "done", pinnedTabs: "done" });
  assert.deepEqual(fixture.expected.script.outcome.failures, []);
  assert.deepEqual(fixture.expected.script.outcome.notes, []);
  assert.equal(fixture.expected.swift.outcome.counts.tabs, 0);
  assert.equal(fixture.expected.script.outcome.counts.tabs, 0);
  assert.deepEqual(fixture.expected.swift.state, fixture.expected.script.state);
  assert.throws(() => compare(fixture.expected.swift, fixture.expected.script));
});

test("theme and cancellation differences retain every route's persisted state", () => {
  const theme = find("Theme-rejection");
  assert.equal(theme.initial.files["sync.json"].profiles.default.themeAdopting, true);
  assert.equal(theme.expected.swift.outcome.counts.tabs, 2);
  assert.equal(theme.expected.script.outcome.counts.tabs, 2);
  assert.deepEqual(theme.expected.swift.state.tabs, theme.expected.script.state.tabs);
  assert.deepEqual(theme.expected.swift.state.groups, theme.expected.script.state.groups);
  assert.notDeepEqual(theme.expected.swift.state.profiles[0].theme, theme.expected.script.state.profiles[0].theme);
  const cancelled = find("Cancel-after-adoption");
  assert.equal(cancelled.expected.swift.outcome.cancelled, false);
  assert.deepEqual(cancelled.expected.swift.outcome.status, { tabs: "failed", spaces: "failed", pinnedTabs: "failed" });
  assert.deepEqual(cancelled.expected.swift.outcome.failures, []);
  const wrongFailures = structuredClone(cancelled.expected.swift.outcome);
  wrongFailures.failures.push({ kind: "tabs", profiles: [] });
  assert.throws(() => compare(wrongFailures, cancelled.expected.swift.outcome));
  assert.equal(cancelled.expected.swift.state.tabs.length, 0);
  assert.equal(cancelled.expected.script.state.tabs.length, 2);
  assert.equal(cancelled.expected.swift.relaunch.tabs.length, 0);
  assert.deepEqual(cancelled.expected.swift.state.nativeIconPages, [[], []]);
  assert.equal(cancelled.expected.script.outcome.cancelled, true);
  assert.deepEqual(cancelled.expected.script.outcome.status, {});
  assert.ok(cancelled.expected.script.state.tabs.every((tab) => tab.url !== "https://later.example/"));
  assert.equal(cancelled.expected.swift.state.profiles[1].name, "Clash");
  assert.equal(cancelled.expected.script.state.nativeIconPages[0].length, 2);
  assert.ok(cancelled.expected.swift.outcome.notes.length > 0);
});

test("numeric tolerance is narrow and never accepts missing theme keys", () => {
  const expected = find("Arc-theme-success").expected.swift;
  const actual = structuredClone(expected);
  actual.state.profiles[0].theme.stops[0].x += 5e-13;
  compare(actual, expected);
  actual.state.profiles[0].theme.stops[0].x += 1e-8;
  assert.throws(() => compare(actual, expected));
  delete actual.state.profiles[0].theme.stops[0].x;
  assert.throws(() => compare(actual, expected));
});
