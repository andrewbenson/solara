import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { flatten } from "./ratchet.mjs";

const ratchet = fileURLToPath(new URL("./ratchet.mjs", import.meta.url));
const hover = { steps: [1], stats: { timers: { "setImmediate:anonymous": 900 }, commits: 40 } };
const typing = { stats: { commits: 1 } };

test("a run whose hover saw a locked screen leaves hover out of its counts", () => {
  const unlocked = flatten({ hover, typing });
  assert.ok(unlocked.ran.has("hover"));
  assert.equal(unlocked.counts["hover.timers"], 900);
  const locked = flatten({ hover, typing, screenLocked: ["hover"] });
  assert.ok(!locked.ran.has("hover"));
  assert.ok(locked.ran.has("typing"));
  assert.equal(locked.counts["hover.timers"], undefined);
  assert.equal(locked.counts["typing.commits"], 1);
});

test("check reports hover pending when a run's screen was locked, instead of judging it", () => {
  const dir = mkdtempSync(join(tmpdir(), "ratchet-locked-"));
  try {
    const report = (results) => {
      const file = join(dir, `r${Math.random()}.json`);
      writeFileSync(file, JSON.stringify({ seed: "big", probeRevision: 3, benchRevision: 6, results }));
      return file;
    };
    const lockedRun = spawnSync(process.execPath, [ratchet, "check", report([{ hover, screenLocked: ["hover"] }, { hover }])], { encoding: "utf8" });
    assert.match(lockedRun.stdout, /pending: hover \(the screen was locked during 1 of 2 runs/);
    assert.doesNotMatch(lockedRun.stdout, /hover\.timers/);
    const unlockedRun = spawnSync(process.execPath, [ratchet, "check", report([{ hover }, { hover }])], { encoding: "utf8" });
    assert.match(unlockedRun.stdout, /hover\.timers/);
    assert.doesNotMatch(unlockedRun.stdout, /pending: hover/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
