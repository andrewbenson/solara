import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
const { LITTLE_SOLARA_PAGE_COMMANDS } = await import("./commandCatalog.ts");
const { commandRoute, INVOKER_COMMANDS, LITTLE_SOLARA_COMMANDS, UTILITY_WINDOW_IDS, WINDOW_LEVEL_COMMANDS } = await import("./commandRoute.ts");
const { SCENES, play, symbolic, withClosing } = await import("../../scripts/native/command-route-scenes.mjs");
const { useBrowser } = await import("../store/browser.ts");

const FIXTURE = new URL("../../../../native/SolaraKit/Tests/SolaraStoreTests/Cases/command-routes.json", import.meta.url);
const fixture = JSON.parse(readFileSync(FIXTURE, "utf8"));
const sorted = (set) => [...set].sort();

test("the fixture was recorded from the original runCommand", () => {
  assert.equal(fixture.provenance.recorder, "apps/browser/scripts/native/record-command-routes.mjs");
  assert.match(fixture.provenance.revision, /^[0-9a-f]{7,}$/);
});

test("the route's command sets equal the original runCommand's", () => {
  assert.deepEqual(sorted(LITTLE_SOLARA_PAGE_COMMANDS), fixture.littleSolaraPageCommands);
  assert.deepEqual(sorted(LITTLE_SOLARA_COMMANDS), fixture.littleSolaraCommands);
  assert.deepEqual(sorted(WINDOW_LEVEL_COMMANDS), fixture.windowLevelCommands);
  assert.deepEqual(sorted(INVOKER_COMMANDS), fixture.invokerCommands);
  assert.deepEqual(sorted(UTILITY_WINDOW_IDS), fixture.utilityWindowIds);
});

test("every scene was recorded, in order", () => {
  assert.deepEqual(fixture.cases.map((c) => c.name), SCENES.map((s) => s.name));
});

for (const scene of SCENES) {
  test(`route: ${scene.name}`, () => {
    const recorded = fixture.cases.find((c) => c.name === scene.name);
    assert.ok(recorded, "recorded");
    assert.deepEqual(symbolic(recorded.route, recorded.roles), scene.expect, "the original routed it as the scene says");
    const replayed = withClosing(recorded.closing, () => commandRoute(recorded.state, recorded.command, recorded.windowId));
    assert.deepEqual(replayed, recorded.route, "commandRoute on the recorded state equals the original's route");
    const live = play(scene, (s, windowId) => commandRoute(useBrowser.getState(), s.command, windowId));
    assert.deepEqual(symbolic(live.route, live.roles), scene.expect, "commandRoute on a fresh scene");
  });
}

test("the store never keeps a Peek in a small window or one with an empty tab id", () => {
  for (const [name, role] of [
    ["a Peek moved into a small window is dropped, and closeTab stays Little Solara's", "small"],
    ["a Peek moved into a small window is dropped, and a page command uses its own tab", "small"],
    ["a Peek with an empty tab id is dropped by the store", "w"],
  ]) {
    const recorded = fixture.cases.find((c) => c.name === name);
    assert.equal(recorded.state.peeks[recorded.roles[role]], undefined, name);
  }
});

test("an empty Peek tab id in a hand-made state is no tab, the way the original's || treats it", () => {
  const recorded = fixture.cases.find((c) => c.name === "Peek openFile promotes the Peek");
  const w = recorded.roles.w;
  const state = { ...recorded.state, peeks: { [w]: { ...recorded.state.peeks[w], tabId: "" } } };
  assert.deepEqual(commandRoute(state, "reload", w), { kind: "main", windowId: w, focusWindow: null, tabId: recorded.roles.a });
  assert.deepEqual(commandRoute(state, "openFile", w), { kind: "peekPromote", windowId: w, focusWindow: null, tabId: null });
  assert.deepEqual(commandRoute(state, "closeTab", w), { kind: "peekDismiss", windowId: w, focusWindow: null, tabId: null });
});

test("runCommand's own switches handle exactly the route's command sets", () => {
  const source = readFileSync(new URL("./commands.ts", import.meta.url), "utf8");
  const labels = (start) => {
    const a = source.indexOf(start);
    const b = source.indexOf("\n}\n", a);
    assert.ok(a >= 0 && b > a, start);
    return sorted(new Set([...source.slice(a, b).matchAll(/case "(\w+)":/g)].map((m) => m[1])));
  };
  const handledInSwift = new Set(["openFile", "focusCommandBar", "manageExtensions", "openProfileMenu"]);
  const routedInJs = (set) => sorted([...set].filter((command) => !handledInSwift.has(command)));
  assert.deepEqual(labels("function runWindowCommand("), routedInJs(WINDOW_LEVEL_COMMANDS));
  assert.deepEqual(labels("function runLittleSolaraCommand("), routedInJs(LITTLE_SOLARA_COMMANDS));
});

test("every route kind is covered", () => {
  const kinds = new Set(SCENES.map((s) => s.expect.kind));
  for (const kind of ["utilityClose", "settingsSearch", "littleSolara", "peekPromote", "peekCloseFind", "peekDismiss", "window", "invoker", "noWindow", "main"]) {
    assert.ok(kinds.has(kind), kind);
  }
});
