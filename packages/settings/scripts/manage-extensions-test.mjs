#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = `usage: node manage-extensions-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]

Search's Manage Extensions action in a hidden instance, driven through SolaraSettings.devSettingsWrites: the
engine profile resolves in Swift to the first profile in the native profile order that uses it (a profile of its
own, then two profiles sharing one engine before and after a reorder), an unknown engine falls back to the focused
window's profile, the Settings window lands on the Extensions pane each time, and the retired JavaScript route
answers with an error at once.
`;

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (args.includes("--help") || !appArg || resolve(appArg).startsWith("/Applications/")) {
  console.log(HELP);
  process.exit(args.includes("--help") ? 0 : 2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-manage-extensions-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "manage-extensions-test.log"), { name: "manage-extensions-test" });
let app = null;

const writes = (action, argument) =>
  app.eval(
    `return globalThis.expo.modules.SolaraSettings.devSettingsWrites(${JSON.stringify(action)}, ${JSON.stringify(JSON.stringify(argument ?? {}))}).then(JSON.parse)`,
  );
const engineOf = (profile) => (profile.dataId ?? profile.id) === "default" ? "" : (profile.dataId ?? profile.id);
const manage = async (engine) => {
  await app.eval(`globalThis.expo.modules.SolaraSettings.devSettings("close", null); return true`).catch(() => {});
  await sleep(500);
  return writes("manageExtensions", { engine });
};

try {
  app = await launch(resolve(appArg), { data, onboarded: true });
  await app.ready({ test: "return !!globalThis.expo?.modules?.SolaraSettings?.devSettingsWrites" });
  await sleep(7000);

  const own = await writes("create", { name: "Own", color: "green" });
  assert.ok(own.id, `create: ${JSON.stringify(own)}`);
  const first = await writes("create", { name: "Shared A", color: "red" });
  const second = await writes("create", { name: "Shared B", color: "blue", shareWith: first.id });
  assert.ok(first.id && second.id, `shared create: ${JSON.stringify(second)}`);
  const profiles = new Map(second.profiles.map((p) => [p.id, p]));
  const defaultId = second.profileOrder.find((id) => ![own.id, first.id, second.id].includes(id));

  await rep.check("a profile's own engine opens Extensions for that profile, in Swift", async () => {
    const out = await manage(engineOf(profiles.get(own.id)));
    assert.equal(out.error, undefined, out.error);
    assert.equal(out.direct, true, "direct");
    assert.equal(out.settingsPane, "extensions");
    assert.equal(out.settingsProfile, own.id);
    return out.settingsProfile;
  });

  await rep.check("a shared engine opens the first sharing profile in the native order, before and after a reorder", async () => {
    const engine = engineOf(profiles.get(second.id));
    assert.equal(engine, engineOf(profiles.get(first.id)), "the two profiles share an engine");
    const before = await manage(engine);
    const firstInOrder = before.profileOrder.find((id) => id === first.id || id === second.id);
    assert.equal(before.settingsProfile, firstInOrder);
    const order = [...before.profileOrder];
    const [a, b] = [order.indexOf(first.id), order.indexOf(second.id)];
    [order[a], order[b]] = [order[b], order[a]];
    const reordered = await writes("reorder", { ids: order });
    assert.deepEqual(reordered.profileOrder, order, "reorder applied");
    const after = await manage(engine);
    const nowFirst = after.profileOrder.find((id) => id === first.id || id === second.id);
    assert.notEqual(nowFirst, firstInOrder, "the order changed");
    assert.equal(after.settingsPane, "extensions");
    assert.equal(after.settingsProfile, nowFirst);
    return `${before.settingsProfile} -> ${after.settingsProfile}`;
  });

  await rep.check("an unknown engine falls back to the focused window's profile", async () => {
    const out = await manage("no-such-engine");
    assert.equal(out.settingsPane, "extensions");
    assert.equal(out.settingsProfile, defaultId);
    return out.settingsProfile;
  });

  await rep.check("the JavaScript route is retired and answers at once", async () => {
    const started = Date.now();
    const out = await writes("manageExtensions", { engine: "", viaJS: true });
    assert.equal(out.error, "Manage Extensions is native only");
    assert.ok(Date.now() - started < 2000, `took ${Date.now() - started} ms`);
    return `${Date.now() - started} ms`;
  });
} finally {
  await app?.quit();
  if (!keep) rmSync(data, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);
