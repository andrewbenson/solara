import assert from "node:assert/strict";
import { test } from "node:test";

const commands = [];
globalThis.acTestNativeModules = {
  SolaraToolbar: {
    extensionCommand: async (json) => { commands.push(JSON.parse(json)); },
    closeExtensionPopup: async () => {},
  },
};
const { activateExtension } = await import("./state.ts");
const { useBrowser } = await import("../../store/browser.ts");
const { useExtensions } = await import("./store.ts");

test("popup activation sends an ID to native without consulting JS window, page or catalog mirrors", async () => {
  useBrowser.getState().hydrate({});
  useExtensions.setState({ lists: {} });
  const anchor = { x: 700, y: 20, width: 24, height: 24 };
  await activateExtension("native-window", { id: "native-extension" }, anchor, null, "native-tab");
  assert.deepEqual(commands, [{ command: "openExtension", windowId: "native-window", id: "native-extension", tabId: "native-tab", anchor, requiresActive: false }]);
  assert.equal(Object.keys(useBrowser.getState().windows).length, 0);
});
