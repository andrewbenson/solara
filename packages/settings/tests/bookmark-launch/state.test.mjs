import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { beforeEach, test } from "node:test";

const native = {};
globalThis.bookmarkLaunchNative = native;
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "expo-modules-core") return {
      url: "data:text/javascript,export const requireOptionalNativeModule = () => globalThis.bookmarkLaunchNative;",
      shortCircuit: true,
    };
    return next(specifier, context);
  },
});
const settings = await import("../../src/index.ts");
const capabilities = [
  "bookmarkWriterSnapshot", "submitBookmarkMutations", "replaceBookmarkDocument", "replaceBookmarkDocumentWithRecords",
  "ackBookmarkFacts", "ackBookmarkFactsForLink", "observeBookmarkRecords", "observeBookmarkRecordsForLink",
  "clearBookmarkFacts", "setBookmarkSyncLinks", "bookmarkProjection", "reloadBookmarkProjection", "addListener",
];
beforeEach(() => {
  for (const key of Object.keys(native)) delete native[key];
  native.bookmarkWriterAPIVersion = () => 2;
  native.bookmarkWriterState = () => ({ state: "owned", generation: "17" });
  for (const name of capabilities) native[name] = () => {};
});

test("selected authority with an older bridge is unavailable rather than writable", () => {
  delete native.bookmarkWriterAPIVersion;
  assert.equal(settings.bookmarkWriterState().state, "read-only-unavailable");
});

test("selected authority requires every generation and state feed method", () => {
  for (const name of capabilities) {
    const saved = native[name];
    delete native[name];
    assert.equal(settings.bookmarkWriterState().state, "read-only-unavailable", name);
    native[name] = saved;
  }
});

test("a malformed native capability cannot advertise writable authority", () => {
  native.clearBookmarkFacts = true;
  assert.equal(settings.bookmarkWriterState().state, "read-only-unavailable");
});

test("a throwing state query never selects the legacy writer", () => {
  native.bookmarkWriterState = () => { throw new Error("bridge unavailable"); };
  assert.equal(settings.bookmarkWriterState().state, "read-only-unavailable");
});

test("starting and stopped remain native authority without advertising readiness", () => {
  for (const state of ["starting", "stopped", "read-only-unavailable"]) {
    native.bookmarkWriterState = () => ({ state });
    native.bookmarkWriterSnapshot = () => ({ engine: "", generation: "1", revision: "1", ready: true, document: "{}", facts: "{}" });
    assert.equal(settings.bookmarkWriterState().state, state);
    assert.throws(() => settings.bookmarkWriterSnapshot("default"));
  }
});

test("malformed ownership state fails closed", () => {
  for (const state of [null, {}, { state: "future" }, { state: "owned" }, { state: "owned", generation: 7 }]) {
    native.bookmarkWriterState = () => state;
    assert.equal(settings.bookmarkWriterState().state, "read-only-unavailable");
  }
});

test("the state feed rechecks compatibility before reporting owned", () => {
  let receive;
  let observed;
  native.addListener = (event, listener) => {
    assert.equal(event, "onBookmarkWriterState");
    receive = listener;
    return { remove() {} };
  };
  settings.onBookmarkWriterState((state) => { observed = state; });
  delete native.clearBookmarkFacts;
  receive({ state: "owned", generation: "17" });
  assert.equal(observed.state, "read-only-unavailable");
});
