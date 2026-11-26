import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, test } from "node:test";

const componentURL = new URL("./frozenPage.tsx", import.meta.url).href;
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `export const SolaraHostedView = "HostedView";`,
  react: `export const useEffect = () => {};`,
  "react-native": `export const StyleSheet = { absoluteFill: { position: "absolute" } };`,
  "./pinHandoff": `export const startPinHandoff = () => {};`,
};
const hooks = registerHooks({
  resolve(specifier, context, next) {
    return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context);
  },
});
const { FrozenPage } = await import("./frozenPage.tsx");
after(() => hooks.deregister());

test("the frozen adapter gives the native host its tab and original page inset", () => {
  const host = FrozenPage({ windowId: "w", tabId: "copy", top: 42 });
  assert.equal(host.props.kind, "frozenPage");
  assert.equal(host.props.windowId, "w");
  assert.deepEqual(host.props.style, [{ position: "absolute" }, { top: 42 }]);
  assert.deepEqual(JSON.parse(host.props.state), { tabId: "copy" });
});

test("native layout owns the frozen presentation without an RN host", () => {
  assert.equal(FrozenPage({ windowId: "w", tabId: "copy", headless: true }), null);
});

test("a missing tab mounts no frozen host", () => {
  assert.equal(FrozenPage({ windowId: "w", tabId: undefined }), null);
});
