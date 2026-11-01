import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { runInThisContext } from "node:vm";

const ts = createRequire(import.meta.url)("typescript");

export async function startProfileConfirmation() {
  const { useBrowser } = await import("../store/browser.ts");
  const imports = {
    "@solara/shell": await import("@solara/shell"),
    "./bookmarks": await import("../store/bookmarks.ts"),
    "./model": await import("../store/model.ts"),
    "./settings": await import("../store/settings.ts"),
    "./nativeStore": { ...await import("../store/nativeStore.ts"), confirmNativeProfileDeletion: () => {} },
    "./tabs": await import("../store/tabs.ts"),
  };
  const path = new URL("../store/profiles.ts", import.meta.url);
  const source = ts.transpileModule(readFileSync(path, "utf8"), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const module = { exports: {} };
  runInThisContext(`(function(exports, require) {${source}\n})`, { filename: path.pathname })(module.exports, (name) => {
    if (name in imports) return imports[name];
    throw new Error(`Unexpected profile deletion import ${name}`);
  });
  const slice = module.exports.createProfilesSlice(useBrowser.setState, useBrowser.getState, { subscribe: () => {} });
  useBrowser.setState({ deleteProfile: slice.deleteProfile });
}
