import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { deflateRawSync, constants } from 'node:zlib';
import { verify } from './ubol-verify.mjs';

export const encoding = 'deflate';

export async function pack(source, target) {
  const manifest = await verify(source);
  if (manifest.encoding) throw new Error('the WebKit lists are already packed');
  await mkdir(target, { recursive: true });
  const packed = new Map();
  async function packAsset(asset) {
    const bytes = await readFile(join(source, asset.file));
    const file = `${asset.file}.${encoding}`;
    if (!packed.has(file)) {
      await writeFile(join(target, file), deflateRawSync(bytes, { level: constants.Z_BEST_COMPRESSION }));
      packed.set(file, bytes.length);
    }
    return { ...asset, file, bytes: bytes.length };
  }
  const lists = [];
  for (const group of manifest.lists) {
    lists.push({
      ...group,
      decisions: await packAsset(group.decisions),
      chunks: await Promise.all(group.chunks.map(packAsset)),
      scriptlets: await Promise.all(group.scriptlets.map(packAsset)),
    });
  }
  for (const name of ['UPSTREAM-LICENSE.txt', 'coverage.json']) await copyFile(join(source, name), join(target, name));
  const result = { ...manifest, encoding, lists };
  await writeFile(join(target, 'manifest.json'), JSON.stringify(result));
  await verify(target);
  return result;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2] || !process.argv[3]) throw new Error('usage: node ubol-pack.mjs <verified-lists> <packed-output>');
  await pack(process.argv[2], process.argv[3]);
}
