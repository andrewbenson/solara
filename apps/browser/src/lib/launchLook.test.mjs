import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";

globalThis.__DEV__ = false;

const { launchFavicons, resolveFavicon, seedFavicons, useFavicons } = await import("./favicons.ts");
const { useBrowser } = await import("../store/browser.ts");
const { engineProfile } = await import("../store/model.ts");

const LIMIT = 1024 * 1024;
const image = (i) => `data:image/png;base64,${String(i).padStart(4, "0")}${"A".repeat(16 * 1024 - 40)}`;

test("the launch favicons stay under 1 MiB serialized, each image stored once", () => {
  useBrowser.getState().hydrate({});
  const key = engineProfile("default");
  const pages = {};
  const srcs = {};
  const themes = {};
  const tabs = [];
  for (let i = 0; i < 66; i++) {
    const page = `https://site${i}.test/`;
    const src = `https://site${i}.test/favicon.ico`;
    pages[page] = image(i);
    srcs[src] = image(i);
    themes[image(i)] = { kind: "template", fill: "#000000", stroke: "#ffffff" };
    tabs.push({ url: page, favicon: src, profileId: "default" });
  }
  useFavicons.setState({ profiles: { [key]: { pages, srcs, appearances: {} } }, themes });

  const look = launchFavicons(tabs);
  const json = JSON.stringify(look);
  assert.ok(json.length <= LIMIT, `${json.length} characters`);
  assert.equal(new Set(look.images).size, look.images.length);
  assert.ok(look.images.length >= 50, `${look.images.length} icons kept`);

  useFavicons.setState({ profiles: {}, themes: {} });
  seedFavicons(JSON.parse(json));
  assert.equal(resolveFavicon("https://site0.test/", "https://site0.test/favicon.ico", "default")?.uri, image(0));
  assert.equal(useFavicons.getState().themes[image(0)]?.kind, "template");
  const dropped = tabs.find((t) => !look.images.includes(image(Number(t.url.match(/site(\d+)/)[1]))));
  if (dropped) assert.equal(resolveFavicon(dropped.url, null, "default"), null);
});


test("owned launch look restores favicons without writing native live themes", () => {
  const script = `
    import assert from "node:assert/strict";
    globalThis.__DEV__ = true;
    globalThis.acTestNativeModules = { SolaraStoreAdapter: { status: () => ({ active: true, scope: "everything" }), dispatch: () => JSON.stringify({ rev: 0, patches: [] }), addListener: () => ({ remove() {} }) } };
    const { useBrowser } = await import("./src/store/browser.ts");
    const { docs } = await import("./src/test-native/index.ts");
    const { startNativeStore, attachReplica } = await import("./src/store/nativeStore.ts");
    const { restoreLaunchLook, restoredThemeColor } = await import("./src/lib/launchLook.ts");
    const { resolveFavicon } = await import("./src/lib/favicons.ts");
    const w = useBrowser.getState().createWindow({ url: "https://saved.test/" });
    const tab = useBrowser.getState().windows[w].tabIds[0];
    const png = "data:image/png;base64,AAAA";
    docs.set("launch-look.json", JSON.stringify({ version: 2, themes: [{ tab, page: "https://saved.test/", color: "#ff0000" }], favicons: { images: [png], profiles: { "": { pages: { "https://saved.test/": 0 }, srcs: {} } }, themes: {} } }));
    startNativeStore();
    attachReplica(useBrowser);
    const before = useBrowser.getState().live;
    restoreLaunchLook();
    assert.equal(useBrowser.getState().live, before);
    assert.equal(restoredThemeColor(tab, "https://saved.test/", "#00ff00", false), "#00ff00");
    assert.equal(resolveFavicon("https://saved.test/", null, "default")?.uri, png);
  `;
  const result = spawnSync(process.execPath, ["--no-warnings", "--import", "./src/test-loader.mjs", "--input-type=module", "-e", script], {
    cwd: new URL("../..", import.meta.url), encoding: "utf8", timeout: 10000,
  });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
});
