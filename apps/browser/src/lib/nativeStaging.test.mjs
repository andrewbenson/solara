import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

test("owned-snapshot staging cleanup keeps retry metadata until removal succeeds", async () => {
  const source = readFileSync(new URL("./persist.ts", import.meta.url), "utf8");
  const cleanup = stripTypeScriptTypes(source.slice(source.indexOf("function forgetStaging("), source.indexOf("let frozen =")));
  let download = { id: "saved-0", staging: "/downloads/.solara-download-retry", stagingId: "retry", destination: "/downloads/file" };
  const calls = [];
  let succeeds = false;
  const api = runInNewContext(`${cleanup}\n({cleanStaging});`, {
    useBrowser: { getState: () => ({ downloads: [download], upsertDownload: (d) => { download = d; } }) },
    removeLeftDownloadStaging: async (d) => { calls.push(d.stagingId); return succeeds; },
  });
  api.cleanStaging([download]);
  await Promise.resolve();
  assert.equal(download.stagingId, "retry");
  succeeds = true;
  api.cleanStaging([download]);
  await Promise.resolve();
  assert.deepEqual(calls, ["retry", "retry"]);
  assert.deepEqual(Object.keys(download), ["id"]);
});
