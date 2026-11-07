import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, test } from "node:test";

const policyURL = new URL("./bookmarksBarPolicy.ts", import.meta.url).href;
const f = globalThis.bookmarksBarPolicyTest = {
  kinds: ["bookmarksBar"],
  state: { settings: { bookmarksBar: "always" }, windows: { plain: {}, private: { incognito: true } } },
};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": "export const hostedKinds = () => globalThis.bookmarksBarPolicyTest.kinds;",
  "../../store/browser": "export const useBrowser = (fn) => fn(globalThis.bookmarksBarPolicyTest.state);",
};
const hooks = registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === policyURL && specifier in sources) return fake(sources[specifier]);
    return next(specifier, context);
  },
});
const { bookmarksBarShown, nativeBookmarksBarAvailable, useBookmarksBarMode } = await import("./bookmarksBarPolicy.ts");
after(() => { hooks.deregister(); delete globalThis.bookmarksBarPolicyTest; });

test("the bar follows the setting while the native bar is available, and never shows in a private window", () => {
  f.kinds = ["bookmarksBar"];
  assert.equal(nativeBookmarksBarAvailable(), true);
  assert.equal(useBookmarksBarMode("plain"), "always");
  assert.equal(useBookmarksBarMode("private"), "never");
  assert.equal(bookmarksBarShown(useBookmarksBarMode("plain"), { url: "https://a.example/" }), true);
});

test("without the native bar no window shows a bar or reserves its height", () => {
  f.kinds = [];
  assert.equal(nativeBookmarksBarAvailable(), false);
  assert.equal(useBookmarksBarMode("plain"), "never");
  assert.equal(bookmarksBarShown(useBookmarksBarMode("plain"), { url: "" }), false);
});
