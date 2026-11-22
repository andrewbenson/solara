import assert from "node:assert/strict";
import { test } from "node:test";

const { useBrowser } = await import("../store/browser.ts");
const { deviceTabsAdapter } = await import("./adapters.ts");
const S = () => useBrowser.getState();

test("device tabs never exports an untouched placeholder even when a page report carries a URL", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://kept.example/" });
  const placeholder = S().newTab(w, { url: "https://transient.example/" });
  S().updateTab(placeholder, { newTabPlaceholder: true });
  const adapter = deviceTabsAdapter("default", "placeholder-test", () => "Mac");
  const tabs = adapter.extract().values.get("tabs:placeholder-test").tabs;
  assert.deepEqual(tabs.map((tab) => tab.u), ["https://kept.example/"]);
  S().settleNewTab(placeholder);
  assert.equal(adapter.extract().values.get("tabs:placeholder-test").tabs.some((tab) => tab.u === "https://transient.example/"), true);
});
