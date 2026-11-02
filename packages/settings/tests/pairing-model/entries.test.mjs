import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import test from 'node:test';

const rows = execFileSync(process.env.PAIRING_MODEL_ENTRY_BINARY, { encoding: 'utf8', timeout: 30000 }).trim().split('\n').map(JSON.parse);
for (const row of rows) {
  test(`Settings ${row.action} invalidates before blocked native cleanup`, () => {
    assert.equal(row.guarded, true, JSON.stringify(row.events));
    if (row.expectsInvalidation === false) assert.deepEqual(row.events, []);
    else assert.match(row.events[0], /^invalidate:/);
  });
}
