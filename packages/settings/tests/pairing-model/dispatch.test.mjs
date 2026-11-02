import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import test from 'node:test';

const panes = process.env.PAIRING_SETTINGS_VIEW_ROOT ?? new URL('../../../../native/SolaraKit/Sources/SolaraUI/Settings/Panes/', import.meta.url).pathname;
const contents = (name) => readFileSync(resolve(panes, name), 'utf8');
for (const [file, action, reason, count] of [
  ['SyncPane.swift', 'model.turnOn()', 'rekey', 2],
  ['SyncPane.swift', 'model.chooseFolder()', 'folder', 1],
  ['SyncSheets.swift', 'model.changeFolderForPhrase()', 'folder', 1],
  ['SyncSheets.swift', 'submit()', 'rekey', 1],
  ['SyncSheets.swift', 'finish(deleteData:', 'stop', 2],
]) {
  test(`Settings ${action} invalidates before creating its action Task`, () => {
    const lines = contents(file).split('\n').filter((line) => line.includes(`Task { await ${action}`));
    assert.equal(lines.length, count);
    for (const line of lines) {
      const guard = line.indexOf(`model.invalidatePairing("${reason}")`);
      assert.ok(guard >= 0 && guard < line.indexOf('Task {'), line);
    }
  });
}
test('Settings separate-sync confirmation invalidates before action dispatch', () => {
  assert.match(contents('SyncSheets.swift'), /invoke: \{\s*model\.invalidatePairing\("rekey"\)\s*let captured = inspectionID\s*Task \{ await model\.confirmSeparateSync/);
});
