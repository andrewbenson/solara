import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { fake, folder, shell, S, settle, launch, reset, files, onAndSynced } = await import('./harness.mjs');

const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
const realRead = native.read;
const realNow = Date.now;

test("R-pending: a rebuilt scope with one file that never downloads never finishes the rebuild, so local deletions are never published", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  native.read = async (...args) => {
    const listing = await realRead(...args);
    return args[1] === `p:${syncId}` ? { ...listing, pending: ["stuck"], present: [...listing.present, "stuck"] } : listing;
  };
  try {
    shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
    const again = await launch();
    again.startSync();
    await settle();
    S().addBookmark({ profileId: "default", url: "https://early.example/", title: "Early" });
    await again.syncNow();
    await again.syncNow();
    await settle();
    const early = files().filter(({ scope }) => scope === `p:${syncId}`).flatMap(({ file }) => file.ops ?? []);
    console.log("published within the first day while one file is pending:", early.some((op) => op.v?.t === "Early"));
    const skew = 25 * 3_600_000;
    Date.now = () => realNow() + skew;
    S().addBookmark({ profileId: "default", url: "https://control.example/", title: "Control" });
    const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
    S().removeBookmark(one.id);
    assert.ok(!Object.values(S().bookmarks.nodes).some((n) => n.kind === "url" && n.title === "One"), "control: One is gone here");
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    const ops = files().filter(({ scope }) => scope === `p:${syncId}`).flatMap(({ file }) => file.ops ?? []);
    assert.ok(ops.some((op) => op.v?.t === "Control"), "control: an added bookmark is published after the 24 h give-up");
    const oneKey = ops.find((op) => op.v?.t === "One")?.k;
    assert.ok(ops.some((op) => op.k === oneKey && op.v === null), `the deletion of One is published (rebuilding: ${JSON.stringify(JSON.parse(shell.docs.get("sync.json")).rebuilding)})`);
  } finally {
    native.read = realRead;
    Date.now = realNow;
  }
});
