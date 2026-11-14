import assert from "node:assert/strict";
import { sleep } from "../../../scripts/lib/instance.mjs";

export const sidebarPosition = process.env.SOLARA_TEST_SIDEBAR_POSITION ?? "left";
assert.ok(["left", "right"].includes(sidebarPosition), "SOLARA_TEST_SIDEBAR_POSITION must be left or right");
export const sidebarPositionSpecified = process.env.SOLARA_TEST_SIDEBAR_POSITION !== undefined;
export const sidebarDirection = sidebarPosition === "right" ? -1 : 1;
const storedSidebarPosition = process.env.SOLARA_TEST_SAVED_SIDEBAR_POSITION ?? sidebarPosition;
assert.ok(["left", "right"].includes(storedSidebarPosition), "SOLARA_TEST_SAVED_SIDEBAR_POSITION must be left or right");
export const sidebarSession = (fixture) => sidebarPositionSpecified ? { ...fixture, settings: { ...fixture.settings, sidebarPosition: storedSidebarPosition } } : fixture;
export const sidebarEdgeX = (width, inward = 0) => sidebarPosition === "right" ? width - inward : inward;
export const sidebarPointX = (column, fraction = 0.5) => Math.round(column.frame[0] + column.frame[2] * fraction);
export const assertSidebarPosition = async (app, windowId = "w1") => {
  if (!sidebarPositionSpecified) return null;
  const deadline = Date.now() + 5000;
  let last;
  while (deadline - Date.now() >= 1000) {
    assert.ok(app.alive, "the owned instance is alive while checking sidebar side");
    last = await app.eval(`return globalThis.expo.modules.SolaraWindowShell.describe(${JSON.stringify(windowId)}).then(JSON.parse).then((state) => state && ({ ...state, sidebarPositionCapability: globalThis.expo.modules.SolaraApp.sidebarPosition }));`, { timeout: 1000 });
    const side = last?.layout?.sidebarPosition ?? last?.sidebarDock?.side;
    if (side === sidebarPosition) {
      if (["0", "1"].includes(process.env.SOLARA_NATIVE_WINDOW_LAYOUT)) {
        const expectedCapability = process.env.SOLARA_NATIVE_WINDOW_LAYOUT === "1";
        assert.equal(last.sidebarPositionCapability, expectedCapability, "the native sidebar-position menu capability matches window layout ownership");
        assert.equal(last.nativeLayout, expectedCapability, "the actual window layout owner matches the requested capability");
      }
      const frame = last.layout?.actual?.sidebar ?? last.layout?.sidebar ?? last.sidebar;
      const bounds = last.bounds;
      if (frame && bounds && !last.layout?.topTabs && !last.sidebarDock?.live && frame[0] >= 0 && frame[0] + frame[2] <= bounds[2] + 0.5) {
        assert.ok(sidebarPosition === "right" ? frame[0] > bounds[2] / 2 : frame[0] < bounds[2] / 2, `the actual sidebar is on ${sidebarPosition}: ${JSON.stringify(frame)}`);
      }
      return last;
    }
    await sleep(100);
  }
  assert.fail(`native effective sidebar side never became ${sidebarPosition}: ${JSON.stringify(last)}`);
};
export const assertSidebarPeekCoverage = async (app, windowId, point) => {
  if (!sidebarPositionSpecified) return null;
  const state = await assertSidebarPosition(app, windowId);
  const rect = state?.sidebarDock?.coverage;
  assert.ok(Array.isArray(rect) && rect.length === 4 && rect[2] > 0 && rect[3] > 0, `native peek coverage exists: ${JSON.stringify(state?.sidebarDock)}`);
  assert.ok(point[0] >= rect[0] && point[0] < rect[0] + rect[2] && point[1] >= rect[1] && point[1] < rect[1] + rect[3], `the actual row pointer is inside native peek coverage: ${JSON.stringify({ point, rect })}`);
  assert.ok(sidebarPosition === "right" ? rect[0] > state.bounds[2] / 2 : rect[0] < state.bounds[2] / 2, `native peek coverage stays at ${sidebarPosition}: ${JSON.stringify(rect)}`);
  return rect;
};
export const assertSidebarTrafficLights = async (app, windowId = "w1") => {
  if (!sidebarPositionSpecified) return null;
  const state = await assertSidebarPosition(app, windowId);
  const lights = state?.trafficLights;
  assert.equal(lights?.length, 3, "all three actual traffic-light controls exist");
  for (const light of lights) {
    assert.ok(light.rect?.[2] > 0 && light.rect?.[3] > 0, `the traffic light has a real control frame: ${JSON.stringify(light)}`);
    if (!light.hidden) assert.ok(light.rect[0] >= 0 && light.rect[0] + light.rect[2] <= 84, `visible traffic lights stay physically left on ${sidebarPosition}: ${JSON.stringify(lights)}`);
  }
  assert.ok(lights.every((light, index) => !index || light.rect[0] > lights[index - 1].rect[0]), "traffic-light control order remains left to right");
  return lights;
};
