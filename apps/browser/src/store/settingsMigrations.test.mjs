import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const { DEFAULT_SETTINGS, migrateSavedSettings } = await import("./settings.ts");

const S = () => useBrowser.getState();

test("the toolbar stays put while scrolling by default", () => {
  assert.equal(DEFAULT_SETTINGS.hideToolbarWhileScrolling, false);
  S().hydrate({});
  assert.equal(S().settings.hideToolbarWhileScrolling, false);
});

test("a profile saved with the old default is turned off once", () => {
  const saved = { ...DEFAULT_SETTINGS, hideToolbarWhileScrolling: true, chosen: ["hideToolbarWhileScrolling"], inferred: [], migrations: undefined };
  S().hydrate({ settings: saved });
  assert.equal(S().settings.hideToolbarWhileScrolling, false);
  assert.ok(S().settings.migrations.includes("toolbarStaysOnScroll"));
  assert.ok(S().settings.chosen.includes("hideToolbarWhileScrolling"), "stays chosen so sync carries the change");
});

test("turning it back on survives the next launch", () => {
  S().hydrate({ settings: { ...DEFAULT_SETTINGS, hideToolbarWhileScrolling: true, migrations: undefined } });
  S().updateSettings({ hideToolbarWhileScrolling: true });
  const relaunched = JSON.parse(JSON.stringify(S().settings));
  S().hydrate({ settings: relaunched });
  assert.equal(S().settings.hideToolbarWhileScrolling, true);
});

test("a new profile that turns it on keeps it on", () => {
  S().hydrate({});
  S().updateSettings({ hideToolbarWhileScrolling: true });
  S().hydrate({ settings: JSON.parse(JSON.stringify(S().settings)) });
  assert.equal(S().settings.hideToolbarWhileScrolling, true);
});

test("the battery saver migration still runs alongside it", () => {
  const migrated = migrateSavedSettings({ batterySaver: false, hideToolbarWhileScrolling: true, chosen: ["batterySaver"] });
  assert.equal(migrated.batterySaverWhen, "never");
  assert.equal("batterySaver" in migrated, false);
  assert.equal(migrated.hideToolbarWhileScrolling, false);
  assert.deepEqual(migrated.migrations, ["toolbarStaysOnScroll"]);
  assert.equal(migrateSavedSettings(undefined), undefined);
});

test("pinned tabs stand out unless someone picks the classic look, and that choice survives a relaunch", () => {
  S().hydrate({});
  assert.equal(S().settings.classicPinnedTabs ?? false, false);
  S().updateSettings({ classicPinnedTabs: true });
  S().hydrate({ settings: JSON.parse(JSON.stringify(S().settings)) });
  assert.equal(S().settings.classicPinnedTabs, true);
  assert.ok(S().settings.chosen.includes("classicPinnedTabs"));
});
