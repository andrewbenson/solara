#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args[0];
const scratchIndex = args.indexOf("--scratch");
if (!appArg || !args.includes("--fixture") || scratchIndex < 1 || !args[scratchIndex + 1]) {
  throw new Error("usage: node sync-pairing-ui-test.mjs <Debug.app> --scratch <scratch> --fixture");
}
const appPath = realpathSync(resolve(appArg));
if (appPath.startsWith("/Applications/") || !appPath.endsWith(".app")) throw new Error("pass an isolated Debug build");
const scratch = resolve(args[scratchIndex + 1]);
if (!isAbsolute(scratch) || scratch === "/" || scratch.startsWith("/Applications/")) throw new Error("pass a scratch directory");
mkdirSync(scratch, { recursive: true, mode: 0o700 });
const data = join(scratch, `pairing-ui-${process.pid}-${Date.now()}`);
const folder = join(data, "sync-folder");
const evidence = join(data, "pairing-evidence");
mkdirSync(folder, { recursive: true, mode: 0o700 });
mkdirSync(evidence, { recursive: true, mode: 0o700 });
writeFileSync(join(data, ".solara-probe-scratch"), "");
const rep = reporter(join(scratch, "sync-pairing-ui-test.log"), { name: "pairing display fixture UI evidence" });
let app;
const dev = (action, argument) => app.eval(`return globalThis.expo.modules.SolaraSettings.devSettings(${JSON.stringify(action)}, ${JSON.stringify(argument ?? null)}).then(JSON.parse)`);
const fixture = async (action, argument) => {
  const state = await dev("pairingFixture", JSON.stringify({ action, argument }));
  assert.equal(state.error, undefined, `fixture ${action}: ${JSON.stringify(state)}`);
  assert.equal(state.fixture, true, `fixture ${action} unavailable: ${JSON.stringify(state)}`);
  if (action !== "destroy") {
    assert.equal(state.actionControlFound, true, `fixture ${action} did not find its target: ${JSON.stringify(state)}`);
  }
  for (const key of Object.keys(state)) {
    assert.ok(!["name", "code", "authorization", "salt", "payload", "phrase", "secret"].includes(key.toLowerCase()), `sensitive structural result key ${key}`);
  }
  return state;
};
const waitFor = async (predicate) => {
  const deadline = Date.now() + 5000;
  let state;
  do {
    state = await fixture("state");
    if (predicate(state)) return state;
    await sleep(30);
  } while (Date.now() < deadline);
  throw new Error(`fixture did not reach the structural state within five seconds: ${JSON.stringify(state)}`);
};
const mountReady = async (variant) => {
  await fixture("mount", variant);
  await fixture("select");
  await waitFor((state) => state.preparing);
  await fixture("ready");
  return waitFor((state) => state.comparisonPresent);
};
const takeSnapshot = async (label) => {
  const file = join(evidence, `${label}.png`);
  const inside = relative(data, file);
  assert.ok(inside && !inside.startsWith(`..${sep}`) && !isAbsolute(inside));
  const state = await fixture("snapshot", file);
  assert.equal(state.snapshotSaved, true, `snapshot failed: ${label}`);
};
try {
  app = await launch(appPath, {
    data, onboarded: true, keepData: true,
    env: { SOLARA_SYNC_DEFAULT_FOLDER: folder, SOLARA_SYNC_PAIRING_FIXTURE: "1" },
  });
  await app.ready({ timeout: 60000, test: "return !!globalThis.expo?.modules?.SolaraSettings?.devSettings" });
  await app.eval('ac.openSettings("sync"); return true');
  await sleep(1000);

  await rep.check("production pairing remains unavailable without the native coordinator", async () => {
    const state = await dev("pairingStatus");
    assert.equal(state.registered, false, "piece 5b has not registered a production coordinator");
    assert.equal(state.fixtureMounted, false);
    const absent = await dev("pairingFixture", JSON.stringify({ action: "allow" }));
    assert.ok(absent.error);
  });

  await rep.check("chooser and delayed comparison require deliberate fixture selection", async () => {
    const chooser = await fixture("mount");
    assert.equal(chooser.choosing, true);
    assert.equal(chooser.comparisonPresent, false);
    await fixture("ready");
    assert.equal((await fixture("state")).comparisonPresent, false);
    await fixture("select");
    await waitFor((state) => state.preparing);
    assert.equal((await fixture("state")).comparisonPresent, false);
    await fixture("ready");
    const state = await waitFor((value) => value.comparisonPresent);
    assert.equal(state.checked, false);
    assert.equal(state.allowEnabled, false);
    assert.equal(state.allowRequests, 0);
    await takeSnapshot("comparison-unchecked-light");
  });

  await rep.check("Allow refuses unchecked input and Return or keypad Enter with inherited default", async () => {
    await fixture("allow");
    await fixture("space");
    assert.equal((await fixture("state")).allowRequests, 0);
    await fixture("check");
    assert.equal((await fixture("state")).allowEnabled, true);
    await fixture("return");
    await fixture("enter");
    assert.equal((await fixture("state")).allowRequests, 0);
    await fixture("destroy");
  });

  await rep.check("old AX targets stay revoked through uncheck and recheck", async () => {
    await mountReady();
    await fixture("check");
    await fixture("saveTarget");
    await fixture("uncheck");
    await fixture("check");
    await fixture("pressSaved");
    assert.equal((await fixture("state")).allowRequests, 0);
    await fixture("allow");
    const state = await waitFor((value) => value.allowRequests === 1);
    assert.equal(state.realAuthenticationRequests, 0);
    assert.equal(state.releaseRequests, 0);
    await fixture("allow");
    assert.equal((await fixture("state")).allowRequests, 1);
    await fixture("destroy");
  });

  await rep.check("Space and current AX are deliberate positive UI controls", async () => {
    for (const action of ["space", "allow"]) {
      await mountReady();
      await fixture("check");
      await fixture(action);
      const state = await waitFor((value) => value.allowRequests === 1);
      assert.equal(state.realAuthenticationRequests, 0);
      assert.equal(state.releaseRequests, 0);
      await fixture("destroy");
    }
  });

  await rep.check("hidden readiness and remount never restore acknowledgment or presentation", async () => {
    for (const transition of ["hide", "remount"]) {
      await mountReady();
      await fixture("check");
      await fixture("saveTarget");
      await fixture(transition);
      await fixture("ready");
      await fixture("show");
      await fixture("pressSaved");
      let state = await fixture("state");
      assert.equal(state.comparisonPresent, false);
      assert.equal(state.allowRequests, 0);
      await fixture("present");
      state = await waitFor((value) => value.comparisonPresent);
      assert.equal(state.checked, false);
      assert.equal(state.allowEnabled, false);
      await fixture("destroy");
    }
  });

  await rep.check("full name and character inspection remain bounded in light and dark fixtures", async () => {
    for (const variant of ["longName", "confusable"]) {
      await mountReady(variant);
      await fixture("inspect");
      for (const appearance of ["light", "dark"]) {
        await fixture(appearance);
        const state = await fixture("state");
        assert.equal(state.nameFullyRendered, true, JSON.stringify(state));
        assert.equal(state.inspectionComplete, true, JSON.stringify(state));
        assert.equal(state.controlsVisible, true, JSON.stringify(state));
        assert.equal(state.checked, false);
        await takeSnapshot(`${variant}-${appearance}`);
      }
      await fixture("destroy");
    }
    const capture = await dev("capture");
    const text = JSON.stringify(capture);
    assert.ok(!text.includes("Fixture Studio") && !text.includes("ABCD23"));
  });

  await rep.check("Escape, close and prebuilt Settings reopen never leave a live fixture", async () => {
    await mountReady();
    await fixture("escape");
    assert.equal((await fixture("state")).comparisonPresent, false);
    await fixture("destroy");
    await mountReady();
    await dev("close");
    const absent = await dev("pairingFixture", JSON.stringify({ action: "allow" }));
    assert.ok(absent.error);
    await app.eval('ac.openSettings("sync"); return true');
    await sleep(500);
    assert.equal((await dev("pairingStatus")).fixtureMounted, false);
  });

  rep.say("Fixture results establish native display and input structure only; they do not establish production admission or real authentication.");
  rep.say("Needs unlocked real Mac: key/occlusion/Spaces, foreground attention, VoiceOver announcements, Touch ID/login-password provenance, human comparison, and two-Mac iCloud propagation.");
} finally {
  await app?.quit();
}
process.exit(rep.summary() ? 0 : 1);
