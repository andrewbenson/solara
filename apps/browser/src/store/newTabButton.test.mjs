import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");

const S = () => useBrowser.getState();

test("fresh settings put new tabs and the button at the top while preserving saved pairs", () => {
  S().hydrate({});
  assert.equal(S().settings.newTabPosition, "top");
  assert.equal(S().settings.newTabButtonPosition, "top");
  const w = S().createWindow({ url: "https://first.example/" });
  const first = S().windows[w].tabIds[0];
  const second = S().newTab(w, { url: "https://second.example/" });
  assert.deepEqual(S().windows[w].tabIds, [second, first]);
  for (const newTabPosition of ["top", "bottom", "nextToCurrent"]) {
    for (const newTabButtonPosition of ["top", "bottom"]) {
      S().hydrate({ settings: { newTabPosition, newTabButtonPosition } });
      assert.equal(S().settings.newTabPosition, newTabPosition);
      assert.equal(S().settings.newTabButtonPosition, newTabButtonPosition);
    }
  }
});

test("a saved At the top keeps the New Tab button at the top; missing button choices use the default", () => {
  S().hydrate({ settings: { newTabPosition: "top", chosen: ["newTabPosition"], inferred: [] } });
  assert.equal(S().settings.newTabButtonPosition, "top");
  assert.ok(S().settings.chosen.includes("newTabButtonPosition"), "it syncs like the choice it came from");
  for (const newTabPosition of ["bottom", "nextToCurrent"]) {
    S().hydrate({ settings: { newTabPosition, chosen: ["newTabPosition"], inferred: [] } });
    assert.equal(S().settings.newTabButtonPosition, "top", newTabPosition);
  }
  S().hydrate({ settings: { newTabPosition: "top", newTabButtonPosition: "bottom", chosen: ["newTabPosition", "newTabButtonPosition"], inferred: [] } });
  assert.equal(S().settings.newTabButtonPosition, "bottom", "a saved button position wins");
});

test("the New Tab button and where new tabs open are set independently", () => {
  S().hydrate({});
  S().updateSettings({ newTabPosition: "nextToCurrent" });
  S().updateSettings({ newTabButtonPosition: "top" });
  assert.equal(S().settings.newTabPosition, "nextToCurrent");
  S().updateSettings({ newTabPosition: "bottom" });
  assert.equal(S().settings.newTabButtonPosition, "top");
});
