import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const fixtures = JSON.parse(readFileSync(new URL("./session-fixtures.json", import.meta.url), "utf8"));

test("fixed-input harvest preserves declarations and replaces stale inputs on reuse", () => {
  const root = mkdtempSync(join(tmpdir(), "session-harvest-"));
  try {
    const harvest = () => {
      const run = spawnSync(process.execPath, ["--no-warnings", new URL("./replay.mjs", import.meta.url).pathname, "--harvest", join(root, "corpus"), "--out", join(root, "replay"), new URL("../../src/store/fullScreenWindows.test.mjs", import.meta.url).pathname], { encoding: "utf8", timeout: 60_000 });
      assert.equal(run.status, 0, run.stderr);
    };
    const verify = () => {
      for (const fixture of fixtures) {
        const dir = join(root, "corpus", fixture.name);
        for (const name of ["session.json", "downloads.json"]) {
          assert.equal(existsSync(join(dir, name)), name in fixture.inputs, `${fixture.name}/${name}`);
          if (name in fixture.inputs) assert.equal(readFileSync(join(dir, name), "utf8"), fixture.inputs[name]);
        }
        assert.equal(existsSync(join(dir, "oracle.json")), !!fixture.oracle, fixture.name);
        if (fixture.oracle) assert.deepEqual(JSON.parse(readFileSync(join(dir, "oracle.json"), "utf8")), fixture.oracle);
        if (fixture.failure) assert.ok(fixture.oracle.jsFails, fixture.name);
      }
      assert.ok(fixtures.some((fixture) => fixture.oracle?.wellFormed));
      assert.ok(fixtures.some((fixture) => fixture.oracle?.normalizes));
    };
    harvest();
    verify();
    for (const fixture of fixtures) {
      for (const name of ["session.json", "downloads.json", "oracle.json"]) writeFileSync(join(root, "corpus", fixture.name, name), "stale");
    }
    harvest();
    verify();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
