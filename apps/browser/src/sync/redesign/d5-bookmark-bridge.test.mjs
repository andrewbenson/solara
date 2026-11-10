import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "./switchOn.mjs";
const { useBrowser } = await import("../../store/browser.ts");
const { reloadBookmarks, startBookmarks } = await import("../../lib/bookmarks.ts");
const stub = await import("../../test-native/index.ts");
const { solaraCoreNativeModules } = await import("../../test-native/solaracore.ts");
const cef = solaraCoreNativeModules.SolaraCEF;
const realEngineCall = cef.engineCall;
let applyGate = null;
cef.engineCall = async (name, profile, json) => {
  if (name === "ac_bookmarks_apply" && applyGate) await applyGate;
  return realEngineCall(name, profile, json);
};

const S = () => useBrowser.getState();
const settle = () => new Promise((r) => setTimeout(r, 0));
const chromeTitle = (id) => stub.chromeBookmarks("").get(id)?.t;

async function started() {
  S().hydrate({});
  stub.docs.clear();
  stub.bookmarkDbs.clear();
  const stop = startBookmarks();
  await settle();
  await reloadBookmarks();
  const id = S().addBookmark({ profileId: "default", url: "https://a.example/", title: "A" });
  await settle();
  await reloadBookmarks();
  return { stop, id };
}

test("D5a: an extension's rename made in Chrome while the app's own rename of that bookmark is still pending isn't hidden by the replay", { todo: "step 9" }, async () => {
  const { stop, id } = await started();
  try {
    let open;
    applyGate = new Promise((r) => (open = r));
    S().updateBookmark(id, { title: "renamed in the app" });
    await settle();
    stub.chromeBookmarkEdit("", [{ op: "add", id, k: "u", t: "renamed by an extension", u: "https://a.example/", a: 1, parent: "bar", index: 0 }]);
    await settle();
    await reloadBookmarks().catch(() => {});
    applyGate = null;
    open();
    for (let i = 0; i < 5; i++) await settle();
    await reloadBookmarks();
    await settle();
    assert.equal(S().bookmarks.nodes[id]?.title, chromeTitle(id), "the store and Chrome agree");
    assert.equal(S().bookmarks.nodes[id]?.title, "renamed by an extension", `the later edit, the extension's, stands (store has ${S().bookmarks.nodes[id]?.title})`);
  } finally {
    stop();
  }
});

test("D5b: adopting an unchanged tree from Chrome changes no bookmark in the store", async () => {
  const { stop } = await started();
  try {
    const before = S().bookmarks.nodes;
    await reloadBookmarks();
    await settle();
    const changed = Object.keys(S().bookmarks.nodes).filter((id) => JSON.stringify(S().bookmarks.nodes[id]) !== JSON.stringify(before[id]));
    assert.deepEqual(changed, [], "no node's value changes");
  } finally {
    stop();
  }
});
