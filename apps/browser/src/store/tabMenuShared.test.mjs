import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { tabMenuItems } from "../components/sidebar/tabMenuPlan.ts";

const fixture = JSON.parse(readFileSync(new URL("../../../../native/SolaraKit/Tests/SolaraStoreTests/Cases/tab-menu.json", import.meta.url), "utf8"));
const canonical = (items) => items === null ? null : items.map(({ key, modifiers, ...item }) => item.separator ? { separator: true } : {
  ...item,
  enabled: item.enabled ?? true,
  checked: item.checked ?? false,
  ...(item.children ? { children: canonical(item.children) } : {}),
});

for (const c of fixture.cases) {
  test(`Tab menu plan (shared with Swift): ${c.name}`, () => {
    const before = JSON.stringify(c.state);
    assert.deepEqual(canonical(tabMenuItems(c.state, c.windowId, c.tabId, c.context)), c.items);
    assert.equal(JSON.stringify(c.state), before, "planning leaves state unchanged");
  });
}

test("Tab menu plan attaches supplied keyboard shortcuts without changing the state", () => {
  const c = fixture.cases.find((c) => c.name === "ordinary middle tab");
  const key = { key: "c", modifiers: ["command", "shift"] };
  const items = tabMenuItems(c.state, c.windowId, c.tabId, { shortcuts: { copyUrl: key } });
  const copy = items.find((item) => item.id === "copy");
  assert.equal(copy.key, key.key);
  assert.deepEqual(copy.modifiers, key.modifiers);
});
