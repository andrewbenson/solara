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

const multiFixture = JSON.parse(readFileSync(new URL("../../../../native/SolaraKit/Tests/SolaraStoreTests/Cases/multi-tab-menu.json", import.meta.url), "utf8"));
for (const c of multiFixture.cases) {
  test(`Multi tab menu (shared with Swift): ${c.name}`, async () => {
    const planner = await import("../components/sidebar/tabMenuPlan.ts");
    const before = JSON.stringify(c.state);
    assert.equal(typeof planner.multiTabMenuItems, "function");
    assert.deepEqual(canonical(planner.multiTabMenuItems(c.state, c.windowId, c.ids, { folders: c.folders })), c.items);
    for (const [choice, command] of Object.entries(c.commands)) {
      assert.deepEqual(planner.multiTabMenuCommand(choice, c.windowId, c.ids, c.state), command, choice);
    }
    assert.equal(JSON.stringify(c.state), before);
  });
}

test("Multi tab menu attaches all supplied shortcuts and refuses stale targets", async () => {
  const { multiTabMenuItems, multiTabMenuCommand } = await import("../components/sidebar/tabMenuPlan.ts");
  const c = multiFixture.cases[0];
  const shortcuts = Object.fromEntries(["copyUrl", "copyUrlAsMarkdown", "newGroupWithTabs", "closeTab"].map((name) => [name, { key: name, modifiers: ["command"] }]));
  const rows = multiTabMenuItems(c.state, c.windowId, c.ids, { folders: c.folders, shortcuts });
  for (const [id, name] of [["copy", "copyUrl"], ["copyMd", "copyUrlAsMarkdown"], ["newGroup", "newGroupWithTabs"], ["close", "closeTab"]]) {
    assert.equal(rows.find((item) => item.id === id).key, name);
    assert.deepEqual(rows.find((item) => item.id === id).modifiers, ["command"]);
  }
  assert.deepEqual(multiTabMenuItems(c.state, c.windowId, ["missing"], { folders: [] }), []);
  for (const ids of [[], ["missing"], ["a", "missing"]]) assert.equal(multiTabMenuCommand("pin", c.windowId, ids, c.state), null);
  assert.equal(multiTabMenuCommand("group:missing", c.windowId, c.ids, c.state), null);
  assert.equal(multiTabMenuCommand("window:missing", c.windowId, c.ids, c.state), null);
});
