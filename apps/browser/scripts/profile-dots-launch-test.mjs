import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appPath, outputPath] = process.argv.slice(2);
if (!appPath || !outputPath) throw new Error("usage: node profile-dots-launch-test.mjs <Debug app> <scratch directory>");
const scratch = resolve(outputPath);
mkdirSync(scratch, { recursive: true });
const fixture = session({
  profiles: [{ id: "default", name: "Personal" }, { id: "p-work", name: "Work" }, { id: "p-third", name: "Third" }, { id: "p-fourth", name: "Fourth" }],
  windows: [{ id: "w-smoke", profileId: "p-work", activeTabIds: { "p-work": "t-work" } }],
  tabs: [{ id: "t-work", profileId: "p-work", url: "about:blank", title: "Work" }],
  settings: { warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false, sleepInactiveTabs: false, sidebarIconsOnly: false },
});
let instance;
try {
  instance = await launch(resolve(appPath), {
    data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true,
    ready: 'return !!ac.store.getState().windows["w-smoke"]',
  });
  let evidence;
  const deadline = Date.now() + 10000;
  while (deadline - Date.now() >= 1000) {
    assert.ok(instance.alive, "hidden instance exited");
    evidence = await instance.eval(`
      const modules = globalThis.expo.modules;
      return Promise.all([modules.SolaraWindowShell.describe("w-smoke"), modules.SolaraHosted.sidebarShell("w-smoke")])
        .then(([shell, column]) => ({ shell: JSON.parse(shell), column: JSON.parse(column), profileId: ac.store.getState().windows["w-smoke"].profileId }));
    `, { timeout: 1000 });
    if (evidence?.column?.chrome?.dots?.length === 4) break;
    await sleep(100);
  }
  writeFileSync(join(scratch, "launch.json"), JSON.stringify(evidence, null, 2));
  assert.equal(evidence?.shell?.nativeLayout, true, "default native window layout");
  assert.equal(evidence?.profileId, "p-work", "restored second profile");
  const dots = evidence?.column?.chrome?.dots;
  assert.deepEqual(dots?.map((dot) => dot.id), fixture.profileOrder);
  for (const dot of dots) {
    assert.ok(Math.abs(dot.opacity - (dot.id === "p-work" ? 0.85 : 0.2)) < 1e-6, `${dot.id}: ${dot.opacity}`);
  }
  assert.equal(await instance.eval(`return ac.shell.devSnapshotWindow("w-smoke", ${JSON.stringify(join(scratch, "launch.png"))});`), true);
  console.log(`PASS restored second-profile dots before any swipe (${scratch})`);
} finally {
  await instance?.quit();
}
