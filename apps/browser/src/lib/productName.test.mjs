import assert from "node:assert/strict";
import { test } from "node:test";
const { appInfo } = await import("../test-native/index.ts");

appInfo.appName = "Solara";
appInfo.switchesURL = "https://stats.example.com/flags.json";
appInfo.updateFeedURL = "https://github.com/example/solara/releases/latest/download/appcast.xml";

const { PRODUCT, SERVICES } = await import("./productName.ts");
const { SETTINGS, setting } = await import("../components/settings/settingsIndex.ts");

test("the bundle's product name names the app everywhere", () => {
  assert.equal(PRODUCT, "Solara");
  assert.equal(setting("general.openAtLogin").title, "Open Solara at login");
  assert.equal(setting("general.autoUpdate").title, "Automatically update Solara");
  assert.equal(SETTINGS.find((e) => e.id.endsWith(".cliControl")).title, "Let the solara command control Solara");
  assert.equal(SETTINGS.find((e) => e.id.endsWith(".cliInstall")).title, "The solara command");
});

test("service copy names the servers this build talks to", () => {
  assert.deepEqual(SERVICES, { updateHost: "github.com", switchFile: "stats.example.com/flags.json" });
});

test("the product scheme recognizes its internal page URLs", async () => {
  const { APP_SCHEME } = await import("./productName.ts");
  const { internalPageOf } = await import("../components/pages/internalUrls.ts");
  const { urlForDisplay } = await import("@solara/core");
  assert.equal(APP_SCHEME, "solara");
  assert.equal(internalPageOf("solara://history?q=x"), "history");
  assert.equal(internalPageOf("solara://bookmarks"), "bookmarks");
  assert.equal(internalPageOf("SOLARA://Downloads/"), "downloads");
  assert.equal(internalPageOf("chrome://history"), null);
  assert.equal(internalPageOf("solara://version"), null);
  assert.equal(internalPageOf("https://solara.example/history"), null);
  assert.equal(urlForDisplay("chrome://version/"), "solara://version");
});
