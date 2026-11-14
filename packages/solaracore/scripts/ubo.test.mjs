import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';

const installer = await readFile(new URL('./ubo.sh', import.meta.url), 'utf8');
const python = installer.match(/<<'PY'\n([\s\S]*?)\nPY/)[1].split('\ndef patch(')[0];
const patch = installer.match(/^UBO_PATCH="(\d+)"$/m)[1];

async function fixture(run) {
  const directory = await mkdtemp(join(tmpdir(), 'ubo-manifest-'));
  const manifest = {
    name: '__MSG_extName__',
    description: '__MSG_extShortDesc__',
    default_locale: 'fr',
    version: '1.76.0',
    permissions: ['storage', '<all_urls>'],
    content_scripts: [
      { js: ['/js/scriptlets/subscriber.js'] },
      { js: ['/js/scriptlets/updater.js'] },
      { js: ['/js/contentscript.js'], matches: ['<all_urls>'] },
    ],
    storage: { managed_schema: 'managed_storage.json' },
  };
  const messages = {
    extName: { message: 'Bloqueur « sûr » \\ "privé"' },
    extShortDesc: { message: 'Élimine les pubs.\n日本語 aussi.' },
    popupPowerSwitchInfo: { message: 'Message pour le popup' },
  };
  try {
    for (const [locale, entries] of Object.entries({ fr: messages, en: { extName: { message: 'Wrong locale' } } })) {
      await mkdir(join(directory, '_locales', locale), { recursive: true });
      await writeFile(join(directory, '_locales', locale, 'messages.json'), JSON.stringify(entries));
    }
    await writeFile(join(directory, 'manifest.json'), JSON.stringify(manifest));
    await run({ directory, manifest, messages });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function transform(directory) {
  return execFileSync('python3', ['-I', '-', directory, 'fixture-key', patch], { input: python, encoding: 'utf8' });
}

test('installer resolves both manifest strings from default_locale and preserves runtime messages', () => fixture(async ({ directory, messages }) => {
  transform(directory);
  const manifest = JSON.parse(await readFile(join(directory, 'manifest.json'), 'utf8'));
  assert.equal(manifest.name, 'Bloqueur « sûr » \\ "privé"');
  assert.equal(manifest.description, 'Élimine les pubs.\n日本語 aussi.');
  assert.equal(manifest.default_locale, 'fr');
  assert.deepEqual(JSON.parse(await readFile(join(directory, '_locales/fr/messages.json'), 'utf8')), messages);
  assert.deepEqual(JSON.parse(await readFile(join(directory, '_locales/en/messages.json'), 'utf8')), { extName: { message: 'Wrong locale' } });
  assert.equal(manifest.version_name, '1.76.0');
  assert.equal(manifest.version, `1.76.0.${patch}`);
  assert.equal(manifest.key, 'fixture-key');
}));

for (const missing of ['locale', 'extName', 'extShortDesc']) {
  test(`installer fails before writing the manifest when ${missing} is missing`, () => fixture(async ({ directory, manifest, messages }) => {
    if (missing === 'locale') {
      await rm(join(directory, '_locales/fr/messages.json'));
    } else {
      delete messages[missing];
      await writeFile(join(directory, '_locales/fr/messages.json'), JSON.stringify(messages));
    }
    const result = spawnSync('python3', ['-I', '-', directory, 'fixture-key', patch], { input: python, encoding: 'utf8' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, missing === 'locale' ? /FileNotFoundError/ : new RegExp(`KeyError: '${missing}'`));
    assert.deepEqual(JSON.parse(await readFile(join(directory, 'manifest.json'), 'utf8')), manifest);
  }));
}
