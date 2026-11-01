import assert from "node:assert/strict";
import { readdirSync } from "node:fs";
import { test } from "node:test";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

let results;
function live() {
  if (results) return results;
  const path = "native/SolaraKit/Sources/SolaraLive/";
  const directory = new URL("../../../../native/SolaraKit/Sources/SolaraLive/", import.meta.url);
  const production = readdirSync(directory).filter((name) => name.endsWith(".swift")).sort().map((name) => source(path + name)).join("\n");
  const module = source("packages/shell/ios/ShellModule.swift");
  const store = declaration(module, "public enum DocumentStore {")
    .replace(declaration(module, "public static var safeMode: Bool"), "public static var safeMode = false");
  const nativeSource = source("packages/settings/ios/Live/NativeLiveEngine.swift");
  const native = declaration(nativeSource, "func command(name: String, payloadJSON: String)");
  const box = declaration(nativeSource, "final class NativeLiveReplicaBox:");
  return results = runNative("LiveDocuments.swift", [production, source("packages/shell/ios/Core/SafeLaunchDocuments.swift"),
    source("packages/shell/ios/Core/DocumentListing.swift"), source("packages/shell/ios/Core/DurableDocument.swift"),
    source("packages/shell/ios/Core/DocumentWriteStore.swift"), store, box,
    `final class FixtureHost { let engine: LiveEngine; let box = NativeLiveReplicaBox(text: nil, failure: nil); init(_ engine: LiveEngine) { self.engine = engine }\n${native} }`,
  ].join("\n"), [], true);
}

test("safe-mode Live folder and calendar edits survive a fresh normal-mode engine over the same document store", () => {
  for (const row of live().filter(({ path }) => path === "user")) {
    assert.equal(row.folder, "p");
    assert.equal(row.alertLead, "10");
    assert.deepEqual(row.hidden, ["private"]);
    assert.ok(row.writes > 0);
  }
});

test("safe-mode Live startup, orphan cleanup and automatic calendar prompting preserve documents with normal controls", () => {
  const rows = live().filter(({ path }) => path === "automatic");
  assert.deepEqual(rows, [
    { path: "automatic", safe: true, started: false, remaining: 1, prompted: false, writes: 0, preserved: true },
    { path: "automatic", safe: false, started: true, remaining: 0, prompted: true, writes: 1, preserved: false },
  ]);
});


test("safe-mode folder creation skips automatic refresh and explicit refresh renders in memory without saving derived caches", () => {
  assert.deepEqual(live().filter(({ path }) => path === "fetch"), [
    { path: "fetch", safe: true, automaticFetches: 0, fetched: 1, refreshError: "", refreshWrites: 0, rendered: ["derived"], savedItems: [], savedLead: "15" },
    { path: "fetch", safe: false, automaticFetches: 1, fetched: 2, refreshError: "", refreshWrites: 0, rendered: ["derived"], savedItems: ["derived"], savedLead: "15" },
  ]);
});

test("safe-mode Live disk failures reject the user command and safe quit never writes a cached replica", () => {
  for (const row of live().filter(({ path }) => path === "failure")) {
    assert.match(row.error, /fixture disk refused/i);
    assert.match(row.retryError, /fixture disk refused/i);
    assert.equal(row.saved, false);
  }
  assert.deepEqual(live().filter(({ path }) => path === "quit"), [
    { path: "quit", safe: true, saved: false },
    { path: "quit", safe: false, saved: true },
  ]);
});


test("safe-mode read and unread choices survive a normal-mode fetch after an in-memory refresh", () => {
  const [row] = live().filter(({ path }) => path === "read");
  assert.deepEqual(row.unread, ["unread"]);
  assert.ok(row.known.includes("derived"));
  assert.ok(row.known.includes("unread"));
});


test("safe-mode focus, tab-deactivation, calendar-change, notification and meeting timers are held with normal controls", () => {
  assert.deepEqual(live().filter(({ path }) => path === "observers"), [
    { path: "observers", safe: true, focusFetches: 0, nudgeFetches: 0, calendarReads: 0, notifications: 0, meetingReads: 0, groups: 1 },
    { path: "observers", safe: false, focusFetches: 1, nudgeFetches: 1, calendarReads: 1, notifications: 1, meetingReads: 1, groups: 0 },
  ]);
});
