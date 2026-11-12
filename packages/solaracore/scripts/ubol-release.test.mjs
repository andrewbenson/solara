import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { convertRelease, version } from './ubol-converter.mjs';
import { verify } from './ubol-verify.mjs';
import { pack } from './ubol-pack.mjs';
import { inflateRawSync } from 'node:zlib';

async function fixture(run) {
  const directory = await mkdtemp(fileURLToPath(new URL('.ubol-fixture-', import.meta.url)));
  try {
    const source = join(directory, 'release');
    const output = join(directory, 'output');
    await mkdir(join(source, 'rulesets/main'), { recursive: true });
    await mkdir(join(source, 'rulesets/regex'), { recursive: true });
    const manifest = { version, manifest_version: 3, declarative_net_request: { rule_resources: [{ id: 'ublock-filters', path: 'rulesets/main/ublock-filters.json' }] } };
    await writeFile(join(source, 'manifest.json'), JSON.stringify(manifest));
    await writeFile(join(source, 'LICENSE.txt'), 'Synthetic fixture license');
    const main = [
      { id: 1, action: { type: 'block' }, condition: { urlFilter: 'ad', resourceTypes: ['script'] } },
      { id: 2, priority: 2, action: { type: 'allow' }, condition: { urlFilter: 'safe', resourceTypes: ['script'] } },
      { id: 3, action: { type: 'redirect', redirect: { url: 'https://x.test/' } }, condition: { urlFilter: 'track' } },
    ];
    await writeFile(join(source, manifest.declarative_net_request.rule_resources[0].path), JSON.stringify(main));
    await writeFile(join(source, 'rulesets/regex/ublock-filters.json'), JSON.stringify([{ id: 4, action: { type: 'block' }, condition: { regexFilter: '(?=unsafe)' } }]));
    await run({ source, output, manifest, directory });
  } finally { await rm(directory, { recursive: true, force: true }); }
}

test('release conversion emits per-list accounting, priority metadata and verified offline assets', () => fixture(async ({ source, output }) => {
  const coverage = await convertRelease(source, output);
  assert.deepEqual({ input: coverage.lists[0].input, converted: coverage.lists[0].converted, dropped: coverage.lists[0].dropped }, { input: 4, converted: 2, dropped: 2 });
  assert.equal(coverage.lists[0].reasons['action:redirect'], 1);
  assert.equal(coverage.lists[0].reasons.regex, 1);
  const manifest = await verify(output);
  const group = manifest.lists[0];
  assert.deepEqual(group.uboIds, ['ublock-filters', 'ublock-unbreak', 'ublock-quick-fixes']);
  assert.equal(group.defaultEnabled, true);
  assert.equal(group.chunks[0].kind, 'block');
  assert.equal(group.chunks[0].priority, 1);
  assert.equal(group.chunks.length, 1);
  const decisions = JSON.parse(await readFile(join(output, group.decisions.file), 'utf8'));
  assert(decisions.some(decision => decision.action === 'allow' && decision.priority === 2));
  await writeFile(join(output, group.chunks[0].file), '[]');
  await assert.rejects(verify(output), /hash mismatch/);
}));

test('release accepts extension-root paths and rejects traversal below that root', () => fixture(async ({ source, output, manifest }) => {
  manifest.declarative_net_request.rule_resources[0].path = '/rulesets/main/ublock-filters.json';
  await writeFile(join(source, 'manifest.json'), JSON.stringify(manifest));
  assert.equal((await convertRelease(source, output)).lists[0].input, 4);
  for (const path of ['/../outside.json', '/rulesets/../../outside.json', '//outside.json', '/rulesets/../main/ublock-filters.json']) {
    manifest.declarative_net_request.rule_resources[0].path = path;
    await writeFile(join(source, 'manifest.json'), JSON.stringify(manifest));
    await assert.rejects(convertRelease(source, output), /invalid asset path/);
  }
}));

test('pinned manifest mismatch and path traversal fail conversion', () => fixture(async ({ source, output, manifest }) => {
  await writeFile(join(source, 'manifest.json'), JSON.stringify({ ...manifest, version: '0.0.0' }));
  await assert.rejects(convertRelease(source, output), /manifest mismatch/);
  manifest.declarative_net_request.rule_resources[0].path = '../outside.json';
  await writeFile(join(source, 'manifest.json'), JSON.stringify(manifest));
  await assert.rejects(convertRelease(source, output), /invalid asset path/);
}));

test('offline verifier rejects forged pin and empty inventories', () => fixture(async ({ source, output }) => {
  await convertRelease(source, output);
  const path = join(output, 'manifest.json');
  const manifest = JSON.parse(await readFile(path, 'utf8'));
  await writeFile(path, JSON.stringify({ ...manifest, archiveSHA256: '0'.repeat(64) }));
  await assert.rejects(verify(output), /invalid pinned/);
  await writeFile(path, JSON.stringify({ ...manifest, lists: [] }));
  await assert.rejects(verify(output), /invalid pinned/);
}));

test('verifier CLI executes validation when its checkout path contains spaces', async () => {
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const { copyFile } = await import('node:fs/promises');
  const run = promisify(execFile);
  const directory = await mkdtemp(fileURLToPath(new URL('.ubol path ', import.meta.url)));
  try {
    for (const name of ['ubol-verify.mjs', 'ubol-converter.mjs']) await copyFile(fileURLToPath(new URL(name, import.meta.url)), join(directory, name));
    await assert.rejects(run(process.execPath, [join(directory, 'ubol-verify.mjs'), join(directory, 'missing')]), error => error.code !== 0 && /ENOENT/.test(error.stderr));
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('non-DNR urlskip records remain separately accounted from DNR rejection totals', () => fixture(async ({ source, output }) => {
  await mkdir(join(source, 'rulesets/urlskip'), { recursive: true });
  await writeFile(join(source, 'rulesets/urlskip/ublock-filters.json'), JSON.stringify([{ re: '^https:', steps: ['?url'] }]));
  const coverage = await convertRelease(source, output);
  assert.equal(coverage.lists[0].input, 4);
  assert.equal(coverage.lists[0].reasons.shape, undefined);
  assert(coverage.unsupportedFiles.some(file => file.reason === 'unsupported-urlskip' && file.entries === 1));
  assert.deepEqual(coverage.decisions, { input: 2, retained: 1 });
}));

test('packed lists are deflated, keep their digests and fail verification when damaged', () => fixture(async ({ source, output, directory }) => {
  await convertRelease(source, output);
  const packed = join(directory, 'packed');
  const manifest = await pack(output, packed);
  assert.equal(manifest.encoding, 'deflate');
  const plain = await verify(output);
  const chunk = manifest.lists[0].chunks[0];
  assert.equal(chunk.file, `${plain.lists[0].chunks[0].file}.deflate`);
  assert.equal(chunk.sha256, plain.lists[0].chunks[0].sha256);
  const original = await readFile(join(output, plain.lists[0].chunks[0].file));
  assert.equal(chunk.bytes, original.length);
  assert.deepEqual(inflateRawSync(await readFile(join(packed, chunk.file))), original);
  await verify(packed);
  await assert.rejects(pack(packed, join(directory, 'twice')), /already packed/);
  await writeFile(join(packed, chunk.file), 'not deflate');
  await assert.rejects(verify(packed));
}));
