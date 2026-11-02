import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";

for (const action of ["outer", "stop", "folder", "rekey", "create"]) {
  test(`actual Settings ${action} invalidates native pairing before held JS`, () => {
    const result = spawnSync(process.env.PAIRING_SETTINGS_ENTRY_BINARY, [action, process.env.PAIRING_SETTINGS_ENTRY_SCRATCH], { encoding: "utf8", timeout: 10000 });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /Completed Settings native entry: 1 test, 3 assertions, 0 failures/);
  });
}
