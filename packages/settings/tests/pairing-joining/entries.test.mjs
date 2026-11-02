import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

test('landed onboarding bridge forwards the selected folder, state and cancellation without restarting recovery', () => {
  const result = spawnSync(process.env.PAIRING_JOINING_BINARY, [], { encoding: 'utf8', timeout: 20000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /Completed onboarding bridge: 1 test, 11 assertions, 0 failures/);
});
