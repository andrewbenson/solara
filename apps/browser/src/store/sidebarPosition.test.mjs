import assert from "node:assert/strict";
import { test } from "node:test";

const sent = [];
const app = { apiVersion: 50, sidebarPosition: true };
let layoutActive = true;
globalThis.acTestNativeModules = {
  SolaraApp: app,
  SolaraWindowShell: { nativeLayout: () => layoutActive },
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "everything" }),
    dispatch: (json) => {
      sent.push(...[JSON.parse(json)].flat());
      return JSON.stringify({ rev: 0, patches: [] });
    },
  },
};
const { startNativeStore, standDown } = await import("./nativeStore.ts");
const side = await import("./sidebarRail.ts");

test("side choices use one native command for Settings and the window menu", () => {
  startNativeStore();
  side.setSidebarPosition("window", "right");
  side.setSidebarPosition(null, "left");
  assert.deepEqual(sent.splice(0), [
    { name: "setSidebarPosition", args: ["window", "right"] },
    { name: "setSidebarPosition", args: [null, "left"] },
  ]);
  standDown();
});

test("side choices refuse invalid values and require the development capability and native workspace", () => {
  startNativeStore();
  assert.throws(() => side.setSidebarPosition("window", "top"), /invalid sidebar position/);
  app.sidebarPosition = false;
  side.setSidebarPosition("window", "right");
  app.sidebarPosition = true;
  standDown();
  side.setSidebarPosition("window", "right");
  assert.deepEqual(sent, []);
});

test("the typed replica resolves configuration before the window and defaults old windows to left", () => {
  assert.equal(side.sidebarPositionOf(undefined, {}), "left");
  assert.equal(side.sidebarPositionOf({ sidebarPosition: "right" }, { sidebarPosition: "left" }), "right");
  assert.equal(side.sidebarPositionOf({ sidebarPosition: "right" }, { sidebarPosition: "left", fileOwn: { covered: ["sidebarPosition"], own: {} } }), "left");
});

test("window choices require an adopted native layout even when the process capability is enabled", () => {
  startNativeStore();
  layoutActive = false;
  side.setSidebarPosition("window", "right");
  assert.equal(side.sidebarPositionSupported("window"), false);
  assert.deepEqual(sent, []);
  layoutActive = true;
  standDown();
});
