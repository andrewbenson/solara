import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "./switchOn.mjs";
const { S, shell, settle, launch, reset, onAndSynced, files } = await import('./harness.mjs');

const relaunchWith = async (syncJson) => {
  shell.docs.set("sync.json", syncJson);
  const again = await launch();
  again.startSync();
  await settle();
  for (let i = 0; i < 2; i++) await again.syncNow();
  await settle();
  return again;
};

test("AUDIT-syncjson-profile: sync.json rolled back to before a profile was linked doesn't publish that profile a second time", { todo: "step 10" }, async () => {
  reset();
  const engine = await onAndSynced();
  const backup = shell.docs.get("sync.json");
  S().createProfile({ name: "Work" });
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  const workKeys = () => new Set(files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k.startsWith("prof:") && op.v?.n === "Work").map((op) => op.k));
  assert.equal(workKeys().size, 1, "control: Work is published once");
  await relaunchWith(backup);
  assert.equal(workKeys().size, 1, `Work is still one profile everywhere (${[...workKeys()]})`);
});

async function typeOff(rolledBack) {
  reset();
  const engine = await onAndSynced();
  const backup = shell.docs.get("sync.json");
  engine.setTypeSynced("bookmarks", false);
  await engine.syncNow();
  await settle();
  const again = await relaunchWith(rolledBack ? backup : shell.docs.get("sync.json"));
  S().addBookmark({ profileId: "default", url: "https://private.example/", title: "Private" });
  for (let i = 0; i < 2; i++) await again.syncNow();
  await settle();
  return files().flatMap(({ file }) => file.ops ?? []).filter((op) => op.v?.u === "https://private.example/").length;
}

test("AUDIT-syncjson-type-off-control: with sync.json current, a bookmark made after turning bookmarks off isn't published", async () => {
  assert.equal(await typeOff(false), 0);
});

test("AUDIT-syncjson-type-off: a data type turned off after sync.json's backup stays off when it's rolled back", { todo: "step 10" }, async () => {
  assert.equal(await typeOff(true), 0, "a bookmark made after turning bookmarks off isn't published");
});

async function profileOff(rolledBack) {
  reset();
  const engine = await onAndSynced();
  const backup = shell.docs.get("sync.json");
  engine.setProfileSynced("default", false);
  await engine.syncNow();
  await settle();
  S().addBookmark({ profileId: "default", url: "https://kept-out.example/", title: "Kept out" });
  await relaunchWith(rolledBack ? backup : shell.docs.get("sync.json"));
  return files().flatMap(({ file }) => file.ops ?? []).filter((op) => op.v?.u === "https://kept-out.example/").length;
}

test("AUDIT-syncjson-profile-off-control: with sync.json current, a bookmark made while the profile is kept out isn't published", async () => {
  assert.equal(await profileOff(false), 0);
});

test("AUDIT-syncjson-profile-off: a profile kept out of sync after sync.json's backup stays out when it's rolled back", { todo: "step 10" }, async () => {
  assert.equal(await profileOff(true), 0, "a bookmark made while the profile was kept out isn't published");
});
