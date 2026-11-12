import { readFile, realpath } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, sep } from 'node:path';
import { inflateRawSync } from 'node:zlib';
import { digest, version, archiveSHA256 } from './ubol-converter.mjs';

export async function verify(root) {
  root = await realpath(root);
  const manifest = JSON.parse(await readFile(resolve(root, 'manifest.json'), 'utf8'));
  if (manifest.schema !== 1 || manifest.version !== version || manifest.archiveSHA256 !== archiveSHA256 || !Array.isArray(manifest.lists) || !manifest.lists.length) throw new Error('invalid pinned WebKit blocker manifest');
  if (manifest.encoding !== undefined && manifest.encoding !== 'deflate') throw new Error('unsupported WebKit blocker encoding');
  const contents = (bytes) => (manifest.encoding === 'deflate' ? inflateRawSync(bytes) : bytes);
  const ids = new Set();
  for (const group of manifest.lists) {
    if (typeof group.id !== 'string' || ids.has(group.id) || !Array.isArray(group.uboIds) || !group.uboIds.length || !Array.isArray(group.chunks) || !Array.isArray(group.scriptlets)) throw new Error('invalid blocker group');
    ids.add(group.id);
    for (const asset of [group.decisions, ...group.chunks, ...group.scriptlets]) {
      if (typeof asset?.file !== 'string' || !/^[a-zA-Z0-9_.-]+$/.test(asset.file) || !/^[a-f0-9]{64}$/.test(asset.sha256)) throw new Error('invalid blocker asset');
      const path = await realpath(resolve(root, asset.file));
      if (!path.startsWith(root + sep)) throw new Error(`blocker asset outside its folder: ${asset.file}`);
      const bytes = contents(await readFile(path));
      if (digest(bytes) !== asset.sha256 || (asset.bytes !== undefined && asset.bytes !== bytes.length)) throw new Error(`blocker asset hash mismatch: ${asset.file}`);
    }
  }
  return manifest;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) throw new Error('usage: node ubol-verify.mjs <compiled-input-directory>');
  await verify(process.argv[2]);
}
