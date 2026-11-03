import fs from "node:fs";
import path from "node:path";

function walk(folder, filesOnly) {
  return fs.readdirSync(folder, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(folder, entry.name);
    const current = filesOnly ? entry.isFile() && entry.name.endsWith(".nns") : true;
    return [...(current ? [file] : []), ...(entry.isDirectory() ? walk(file, filesOnly) : [])];
  });
}

export const listSyncFiles = (folder) => walk(folder, true);
export const listFolderEntries = (folder) => walk(folder, false);
export const folderIsEmpty = (folder) => fs.readdirSync(folder, { withFileTypes: true }).length === 0;
