import assert from "node:assert/strict";
import { test } from "node:test";
await import("../../test-native/index.ts");
const { useBrowser } = await import("../../store/browser.ts");
const { closeInstallPrompt, installRequesterGone, useExtensions } = await import("./store.ts");

const showInstallPrompt = (windowId, p) => useExtensions.setState({ install: { windowId, profile: "", source: "webStore", status: "ready", pkg: { id: p.id }, prompt: p } });

const prompt = (requestId, id = "ext") => ({ requestId, profile: "", id, name: "Ext", version: "1", type: "permissions", icon: "", permissions: ["bookmarks"], browserId: 0 });

function setup() {
  useBrowser.getState().hydrate({});
  const w = useBrowser.getState().createWindow({ url: "a.com" });
  useExtensions.setState({ install: null, popup: null });
  return w;
}

test("a prompt closed outside the dialog takes the dialog down", () => {
  const w = setup();
  showInstallPrompt(w, prompt("install1"));
  assert.equal(useExtensions.getState().install?.status, "ready");
  closeInstallPrompt("install1");
  assert.equal(useExtensions.getState().install, null);
});

test("closing an older prompt leaves the newer one up", () => {
  const w = setup();
  showInstallPrompt(w, prompt("install1"));
  showInstallPrompt(w, prompt("install2"));
  closeInstallPrompt("install1");
  assert.equal(useExtensions.getState().install?.prompt?.requestId, "install2");
});

test("the requester is gone once its tab closes or its popup does", () => {
  const w = setup();
  const tabId = useBrowser.getState().windows[w].tabIds[0];
  assert.equal(installRequesterGone({ tabId }, useBrowser.getState(), null), false);
  assert.equal(installRequesterGone({ tabId: "gone" }, useBrowser.getState(), null), true);
  const popup = { extensionId: "ext" };
  assert.equal(installRequesterGone({ popupOf: "ext" }, useBrowser.getState(), popup), false);
  assert.equal(installRequesterGone({ popupOf: "ext" }, useBrowser.getState(), null), true);
  assert.equal(installRequesterGone({ popupOf: "ext" }, useBrowser.getState(), { extensionId: "other" }), true);
  assert.equal(installRequesterGone(null, useBrowser.getState(), null), false);
});
