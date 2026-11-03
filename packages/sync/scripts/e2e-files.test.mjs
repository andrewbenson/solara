import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { folderIsEmpty, listFolderEntries, listSyncFiles } from "./e2e-files.mjs";

for (const [name, list] of Object.entries({ listSyncFiles, listFolderEntries, folderIsEmpty })) {
  test(`${name} treats spaces, quotes and shell metacharacters as literal paths`, (t) => {
    const work = fs.mkdtempSync(path.join(os.tmpdir(), "sync-files-"));
    t.after(() => fs.rmSync(work, { recursive: true, force: true }));
    const marker = path.join(work, "injected");
    const folder = path.join(work, `folder;touch '${marker}';# spaces ' " $()`);
    fs.mkdirSync(folder, { recursive: true });
    const nested = path.join(folder, "nested");
    fs.mkdirSync(nested);
    fs.writeFileSync(path.join(nested, "record.nns"), "fixture");
    fs.writeFileSync(path.join(folder, "other"), "fixture");
    fs.symlinkSync(nested, path.join(folder, "link"));
    let result;
    try {
      result = list(folder);
    } finally {
      assert.equal(fs.existsSync(marker), false, "no shell command executed");
    }
    if (name === "listSyncFiles") assert.deepEqual(result, [path.join(nested, "record.nns")]);
    else if (name === "listFolderEntries") assert.deepEqual(result.sort(), [nested, path.join(nested, "record.nns"), path.join(folder, "other"), path.join(folder, "link")].sort());
    else assert.equal(result, false);
  });
}

test("empty folders have no entries or sync files", (t) => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "sync-empty-"));
  t.after(() => fs.rmSync(folder, { recursive: true, force: true }));
  assert.deepEqual(listFolderEntries(folder), []);
  assert.deepEqual(listSyncFiles(folder), []);
  assert.equal(folderIsEmpty(folder), true);
});


test("filenames containing newlines stay whole and file symlinks are excluded", (t) => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "sync-newlines-"));
  t.after(() => fs.rmSync(folder, { recursive: true, force: true }));
  const file = path.join(folder, "record\npart.nns");
  const link = path.join(folder, "alias.nns");
  fs.writeFileSync(file, "fixture");
  fs.symlinkSync(file, link);
  assert.deepEqual(listSyncFiles(folder), [file]);
  assert.deepEqual(listFolderEntries(folder).sort(), [file, link].sort());
});
