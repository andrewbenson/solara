import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "./switchOn.mjs";
const { S, settle, reset, onAndSynced, useBrowser, files } = await import('./harness.mjs');

test("AUDIT-history-restore: Chrome's History rolled back to before some visits publishes no deletion for them", { todo: "step 6" }, async () => {
  reset();
  const now = Date.now();
  const entries = Array.from({ length: 6 }, (_, i) => ({ url: `https://h${i}.example/`, title: `H${i}`, favicon: null, visits: 1, lastVisit: now - i * 60_000, visitTimes: [now - i * 60_000] }));
  useBrowser.setState((s) => ({ historyReady: { default: true }, history: { ...s.history, default: entries } }));
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  useBrowser.setState((s) => ({ history: { ...s.history, default: entries.slice(3) } }));
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  const deletions = files().filter(({ scope }) => scope === `p:${syncId}`).flatMap(({ file }) => file.ops ?? []).filter((op) => op.k.startsWith("h:") && op.v === null);
  assert.deepEqual(deletions.map((op) => op.k), [], "visits missing after a restore aren't published as deleted");
  void S;
});

test("AUDIT-store-vs-journal: Solara's store doc rolled back while the journal isn't", { skip: "the harness has no persisted store documents; needs persist.ts in the harness" }, () => {});
