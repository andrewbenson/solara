import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

globalThis.__DEV__ = false;
const { appInfo, docs } = await import("../test-native/index.ts");
const ks = await import("./killSwitches.ts");

const names = Object.keys(ks.SWITCHES);
const reset = () => {
  docs.clear();
  ks.reloadSwitches();
};
const file = (switches) => ({ version: 1, switches });

test("at most 8 live switches, each on by default with an owner and a removal date still ahead", () => {
  assert.ok(names.length <= ks.MAX_SWITCHES, `${names.length} switches: delete one before adding another (cap ${ks.MAX_SWITCHES})`);
  const today = new Date().toISOString().slice(0, 10);
  for (const name of names) {
    const def = ks.SWITCHES[name];
    assert.match(def.removeBy, /^\d{4}-\d{2}-\d{2}$/, name);
    assert.ok(def.removeBy >= today, `${name} is past its removal date (${def.removeBy}): delete it and its old path, or move the date with a reason`);
    assert.ok(def.owner.trim() && def.about.trim(), name);
    assert.equal(typeof def.live, "boolean", name);
  }
  reset();
  for (const name of names) assert.equal(ks.switchOn(name), true, `${name} defaults on`);
});

test("a cached value is read synchronously; unknown names and non-booleans are ignored", () => {
  reset();
  docs.set("switches-cache.json", JSON.stringify(file({ sidebarSlide: false, newTabPrewarm: "no", gone: false, launchTab: 0 })));
  assert.equal(ks.switchOn("sidebarSlide"), false);
  assert.equal(ks.switchOn("newTabPrewarm"), true);
  assert.equal(ks.switchOn("launchTab"), true);
  reset();
  docs.set("switches-cache.json", "not json");
  assert.equal(ks.switchOn("sidebarSlide"), true);
});

test("SOLARA_SWITCHES text parses to values, and ignores what it doesn't know", () => {
  assert.deepEqual(ks.parseOverride("sidebarSlide=off, launchTab=on,nope=off,newTabPrewarm=maybe,=1"), {
    sidebarSlide: false,
    launchTab: true,
  });
  assert.deepEqual(ks.parseOverride(null), {});
});

test("the app never fetches a switch file: values come only from the environment and the cache", () => {
  assert.equal(ks.refreshSwitches, undefined);
  const source = readFileSync(new URL("./killSwitches.ts", import.meta.url), "utf8");
  assert.doesNotMatch(source, /\bfetch\b|writeDocument|switchesURL/);
  assert.doesNotMatch(readFileSync(new URL("../main.tsx", import.meta.url), "utf8"), /killSwitchesLaunch|startKillSwitches/);
});
