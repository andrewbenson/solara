import { readFileSync } from "node:fs";
import { registerHooks, stripTypeScriptTypes } from "node:module";
import { pathToFileURL } from "node:url";

const root = process.env.SOLARA_REPO_ROOT ? pathToFileURL(`${process.env.SOLARA_REPO_ROOT}/`) : new URL("../../../", import.meta.url);
const modules = new Map([
  "apps/browser/src/lib/bookmarks.ts",
  "apps/browser/src/lib/bookmarkWriter.ts",
  "apps/browser/src/store/bookmarks.ts",
  "apps/browser/src/sync/adapters.ts",
  "packages/settings/src/index.ts",
  "apps/browser/src/store/bookmarkProjection.ts",
].map(path => [new URL(path, root).href, new URL(`legacy-bookmarks/${path}`, import.meta.url)]));
registerHooks({
  load(url, context, next) {
    const snapshot = modules.get(url);
    if (snapshot) return { format: "module", source: stripTypeScriptTypes(readFileSync(snapshot, "utf8")), shortCircuit: true };
    return next(url, context);
  },
});
