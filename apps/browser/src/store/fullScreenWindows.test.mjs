import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");

const S = () => useBrowser.getState();
const tick = () => new Promise((resolve) => setTimeout(resolve, 2));

test("full screen stamps follow entry order and clear on exit", async () => {
  S().hydrate({});
  const a = S().createWindow({ url: "a.com" });
  const b = S().createWindow({ url: "b.com" });
  const c = S().createWindow({ url: "c.com" });
  S().setWindowFullScreen(b, true);
  await tick();
  S().setWindowFullScreen(a, true);
  assert.ok(S().windows[b].fullScreen > 0);
  assert.ok(S().windows[a].fullScreen > S().windows[b].fullScreen);
  assert.equal("fullScreen" in S().windows[c], false);
  const stamp = S().windows[b].fullScreen;
  S().setWindowFullScreen(b, true);
  assert.equal(S().windows[b].fullScreen, stamp, "entering again keeps the first stamp");
  S().setWindowFullScreen(b, false);
  assert.equal("fullScreen" in S().windows[b], false);
});
