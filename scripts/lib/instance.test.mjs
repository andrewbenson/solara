import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { binaryPids, binaryOf, commandIsBinary, isAlive, keepCrashReports, launch, realPath } from "./instance.mjs";

const lowerHome = (path) => path.replace(/^\/Users\/([^/]+)\/Developer\/Personal\//, "/Users/$1/Developer/personal/");

test("a binary matches its command line whatever the path's case", () => {
  const binary = "/Users/me/Developer/Personal/solara/apps/browser/build-x/Solara.app/Contents/MacOS/Solara";
  assert.ok(commandIsBinary(binary, binary.toLowerCase()));
  assert.ok(commandIsBinary(`${binary} --flag`, binary.replace("Personal", "personal")));
  assert.ok(!commandIsBinary(`${binary}Helper --type=renderer`, binary));
  assert.ok(!commandIsBinary("/Applications/Solara.app/Contents/MacOS/Solara", binary));
});

test("realPath gives the spelling on disk", () => {
  const dir = mkdtempSync(join(tmpdir(), "instance-case-"));
  try {
    assert.equal(realPath(dir.toUpperCase().replace(/^\/PRIVATE/, "/private")), realPath(dir));
  } finally {
    rmSync(dir, { recursive: true });
  }
});

const app = process.env.INSTANCE_TEST_APP;
test("an instance launched by a differently cased path is recorded and quits", { skip: !app && "set INSTANCE_TEST_APP to a Debug Solara.app" }, async () => {
  const data = mkdtempSync(join(tmpdir(), "instance-case-data-"));
  const binary = realPath(binaryOf(app));
  const before = binaryPids(binary);
  let instance = null;
  try {
    instance = await launch(lowerHome(realPath(app)), { data, onboarded: true });
    assert.ok(instance.stillOwned(), "the launched app is the one recorded");
    assert.equal((await instance.quit()).how, "quit");
    assert.ok(!isAlive(instance.pid));
  } finally {
    if (instance?.stillOwned()) await instance.quit({ graceful: false });
    const left = [...binaryPids(binary)].filter((pid) => !before.has(pid));
    rmSync(data, { recursive: true, force: true });
    assert.deepEqual(left, [], "no instance left running");
  }
});

test("crash reports outlive the instance's data dir, and folders without one keep nothing", () => {
  const root = mkdtempSync(join(tmpdir(), "instance-crash-"));
  try {
    const data = join(root, "data");
    mkdirSync(join(data, "Crashpad", "pending"), { recursive: true });
    mkdirSync(join(data, "crashes"), { recursive: true });
    writeFileSync(join(data, "Crashpad", "settings.dat"), "");
    assert.equal(keepCrashReports(data, 7, root), null);
    writeFileSync(join(data, "Crashpad", "pending", "a.dmp"), "dump");
    writeFileSync(join(data, "crashes", "crash-7.txt"), "signal 11 (segv)\n");
    const kept = keepCrashReports(data, 7, root);
    assert.ok(kept?.startsWith(join(root, "solara-crash-7-")));
    rmSync(data, { recursive: true, force: true });
    assert.deepEqual(readdirSync(join(kept, "Crashpad", "pending")), ["a.dmp"]);
    assert.deepEqual(readdirSync(join(kept, "crashes")), ["crash-7.txt"]);
    assert.equal(keepCrashReports(join(root, "missing"), 8, root), null);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
