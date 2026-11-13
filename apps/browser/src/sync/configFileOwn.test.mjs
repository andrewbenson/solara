import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const adapters = await import("./adapters.ts");
const { ownSetting } = await import("../store/settings.ts");
const { ownTheme } = await import("../store/profiles.ts");
const engine = await import("./engine.ts");

const S = () => useBrowser.getState();
const fileLook = { stops: [], mode: "dark", intensity: 1, grain: 0, texture: "grain", translucency: 1, angle: 90 };
const ownLook = { stops: [], mode: "light", intensity: 0.5, grain: 0, texture: "sand", translucency: 1 };

function withConfigFile() {
  const settings = S().settings;
  useBrowser.setState({
    settings: {
      ...settings,
      appearance: "dark",
      showFullUrl: true,
      bookmarksBar: "always",
      chosen: [...(settings.chosen ?? []).filter((name) => name !== "bookmarksBar"), "appearance", "showFullUrl"],
      fileOwn: { covered: ["appearance", "showFullUrl", "bookmarksBar"], own: { appearance: "light", bookmarksBar: "never" } },
    },
  });
  const profile = S().profiles.default;
  useBrowser.setState({ profiles: { ...S().profiles, default: { ...profile, theme: fileLook, fileTheme: { name: "ocean", source: "~/.config/solara/config.json", own: ownLook } } } });
}

test("config files: the sync adapters publish the user's own values, never the file's", () => {
  withConfigFile();
  const settings = adapters.settingsAdapter.extract(() => undefined);
  assert.deepEqual(settings.values.get("set:appearance"), { v: "light" }, "the own value, not the file's dark");
  assert.ok(!settings.values.has("set:showFullUrl"), "no own value means no say");
  const links = () => ({ default: { syncId: "s1" } });
  const themes = adapters.profileThemesAdapter(links, () => ({})).extract(() => undefined, new Set(), Date.now(), () => false);
  assert.deepEqual(themes.values.get("pth:s1"), { t: ownLook }, "the own theme, not the file's");
});

test("config files: pairing bootstrap compares the user's own values, never the file's", () => {
  withConfigFile();
  const links = { default: { syncId: "s1" } };
  assert.deepEqual(engine.localBootstrapValue("set:appearance", { v: "light" }, links), { v: "light" });
  assert.deepEqual(engine.localBootstrapValue("set:showFullUrl", { v: true }, links), { v: undefined });
  assert.deepEqual(engine.localBootstrapValue("pth:s1", { t: ownLook }, links), { theme: ownLook });
  assert.deepEqual(engine.localBootstrapValue(adapters.themeAngleKey("s1"), {}, links), { a: null, d: null });
  assert.deepEqual(engine.localBootstrapValue("prof:s1", { n: "Personal", theme: null }, links).theme, ownLook);
});

test("config files: a synced value matching the own value isn't reapplied", () => {
  withConfigFile();
  assert.deepEqual(adapters.settingsToReapply({ "set:bookmarksBar": { v: { v: "never" } } }), [], "the own value already matches");
  assert.deepEqual(adapters.settingsToReapply({ "set:bookmarksBar": { v: { v: "newTab" } } }), ["set:bookmarksBar"]);
});

test("config files: without a config file the own accessors are the plain values", () => {
  const settings = { ...S().settings, fileOwn: undefined };
  assert.equal(ownSetting(settings, "appearance"), settings.appearance);
  const profile = { ...S().profiles.default, theme: ownLook, fileTheme: undefined };
  assert.equal(ownTheme(profile), ownLook);
  assert.equal(ownTheme({ ...profile, theme: undefined }), undefined);
  assert.equal(ownTheme({ ...profile, fileTheme: { name: "x", source: "y" } }), undefined, "a file theme over no own theme is no own theme");
});
