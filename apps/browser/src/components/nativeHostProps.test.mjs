import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
const { sidebarHostProps, stripHostProps } = await import("./nativeHostProps.ts");

const swift = (path) => readFileSync(new URL(`../../../../native/SolaraKit/Sources/SolaraUI/${path}`, import.meta.url), "utf8");

function requiredKeys(source, struct) {
  const body = source.match(new RegExp(`public struct ${struct}: Decodable[^{]*\\{\\n([\\s\\S]*?)\\n\\}`))?.[1];
  assert.ok(body, `${struct} is a Decodable struct`);
  const keys = [...body.matchAll(/^ {2}public var (\w+): ([^=\n]+?)\s*(?:=.*)?$/gm)].filter(([, , type]) => !type.endsWith("?")).map(([, name]) => name);
  assert.ok(keys.length > 5, `${struct} declares its fields`);
  return keys;
}

const glow = { color: "#FFFFFF26", opacity: 1, radius: 15 };
const live = { loading: ["a"], playing: ["b"], sleeping: ["c"] };

const strip = (ownsLive) =>
  stripHostProps({
    profileId: "default", dark: true, theme: {}, border: [], glow, floating: false, pageWidth: 0, engines: {}, capture: {}, bands: {},
    closeHint: null, newTabMark: null, pages: [], selection: [], ownsLive, live: { playing: live.playing, sleeping: live.sleeping },
  });

const sidebar = (ownsLive) =>
  sidebarHostProps({
    profileId: "default", dark: true, theme: {}, border: [], glow, selection: [], closeHint: null, backHint: null, renaming: null,
    addressBar: false, tidy: false, clear: false, iconRing: false, newTabAtTop: false, incognito: false, cleaned: 0, upsell: null,
    product: "Solara", engines: {}, developer: [], newTabMark: null, pages: [], player: null, pip: [], capture: {}, badge: [], ownsLive, live,
  });

for (const [name, struct, path, build] of [
  ["strip", "StripHostState", "TopStrip/StripHostState.swift", strip],
  ["sidebar", "SidebarHostState", "Sidebar/SidebarHostState.swift", sidebar],
]) {
  const keys = requiredKeys(swift(path), struct);
  for (const ownsLive of [false, true]) {
    test(`the ${name} props carry every non-optional ${struct} key when native ${ownsLive ? "owns" : "doesn't own"} live`, () => {
      const props = JSON.parse(JSON.stringify(build(ownsLive)));
      const missing = keys.filter((key) => props[key] === undefined || props[key] === null);
      assert.deepEqual(missing, [], `${struct} can't decode without ${missing.join(", ")}`);
    });
  }
}

test("native-owned live sends empty lists, not JS's stale ones", () => {
  assert.deepEqual([strip(true).playing, strip(true).sleeping], [[], []]);
  assert.deepEqual([sidebar(true).loading, sidebar(true).playing, sidebar(true).sleeping], [[], [], []]);
  assert.deepEqual([sidebar(false).loading, sidebar(false).playing, sidebar(false).sleeping], [["a"], ["b"], ["c"]]);
});
