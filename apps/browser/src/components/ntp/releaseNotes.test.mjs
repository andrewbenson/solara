import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const componentURL = new URL("./releaseNotes.ts", import.meta.url).href;
const f = globalThis.releaseReceiptTest = {writes: [], selected: []};
const fake = source => ({url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true});
const sources = {
  "@solara/shell": `export const launchEnvironment = () => null, readDocument = () => null, systemInfo = () => ({appVersion:"1.0"}), writeDocument = (...args) => globalThis.releaseReceiptTest.writes.push(args);`,
  "../../lib/persistLatch": `export const persistenceRefused = () => false;`,
  "../../store/nativeStore": `export const nativeSafeMode = () => false;`,
  "../../lib/productName": `export const PRODUCT = "Solara";`,
  zustand: `export const create = initial => { let state = initial(); const use = select => { const value = select(state); globalThis.releaseReceiptTest.selected.push(value); return value; }; use.getState = () => state; use.setState = next => { state = {...state, ...next}; }; return use; };`,
};
const hooks = registerHooks({resolve(specifier, context, next) { return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context); }});
const release = await import("./releaseNotes.ts");
after(() => {hooks.deregister(); delete globalThis.releaseReceiptTest;});
beforeEach(() => {release.closeReleaseNotes(); release.applyPendingReleaseNotes(null); f.writes = []; f.selected = [];});

test("reopening the same version in the same window invalidates the old page receipt", () => {
  release.openReleaseNotes("w", "1.0");
  const old = release.releaseNotesPageReceipt("w", "1.0");
  release.openReleaseNotes("w", "1.0");
  const current = release.releaseNotesPageReceipt("w", "1.0");
  assert.notEqual(old, current);
  let closed = 0;
  release.closeReleaseNotesIfCurrent(old, () => closed++);
  assert.equal(closed, 0);
  release.closeReleaseNotesIfCurrent(current, () => closed++);
  assert.equal(closed, 1);
  assert.equal(release.releaseNotesPageReceipt("other", "1.0"), null);
  release.closeReleaseNotes();
  release.closeReleaseNotesIfCurrent(current, () => closed++);
  assert.equal(closed, 1);
});

test("pending and page hooks select changed objects when the version stays the same", () => {
  const first = {version: "1.0", since: 1};
  release.applyPendingReleaseNotes(first);
  const notes = release.usePendingReleaseNotes();
  assert.equal(f.selected.at(-1), first);
  const second = {version: "1.0", since: 2};
  release.applyPendingReleaseNotes(second);
  assert.equal(release.usePendingReleaseNotes(), notes);
  assert.equal(f.selected.at(-1), second);
  assert.equal(release.releaseNotesPendingReceipt(), second);
  release.openReleaseNotes("w", "1.0");
  release.useReleaseNotesPage("w");
  const page = f.selected.at(-1);
  release.openReleaseNotes("w", "1.0");
  release.useReleaseNotesPage("w");
  assert.notEqual(f.selected.at(-1), page);
});
