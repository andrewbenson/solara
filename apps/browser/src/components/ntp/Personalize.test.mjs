import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, test } from "node:test";

const target = new URL("./Personalize.tsx", import.meta.url).href;
const sources = {
  "@solara/settings": `export const SolaraHostedView = "HostedView";`,
  react: `export const useEffect = () => {};`,
  zustand: `export const create = initial => select => select(initial());`,
  "react-native": `export const StyleSheet = { absoluteFill: { position: "absolute" } };`,
  "../../lib/theme": `export const useTheme = () => ({ dark: true, panel: "panel", panelBorder: "border", panelShadowOpacity: 0.5, textPrimary: "title", textSecondary: "subtitle", textTertiary: "dim", icon: "icon", toolbarHover: "hover", toolbarPressed: "pressed" }); export const hex = v => v; export const PROFILE_COLORS = {};`,
  "../../store/browser": `export const useBrowser = () => { throw new Error("Personalize must not read the browser mirror"); };`,
};
const hook = registerHooks({ resolve(specifier, context, next) {
  return context.parentURL === target && specifier in sources
    ? { url: `data:text/javascript,${encodeURIComponent(sources[specifier])}`, shortCircuit: true }
    : next(specifier, context);
} });
const { PersonalizeButton } = await import("./Personalize.tsx");
after(() => hook.deregister());

test("Personalize mounts appearance only; native code owns eligibility profile layout and open state", () => {
  const host = PersonalizeButton({ windowId: "w" });
  assert.equal(host.type, "HostedView");
  assert.equal(host.props.kind, "personalize");
  assert.equal(host.props.windowId, "w");
  assert.deepEqual(host.props.style, { position: "absolute" });
  assert.deepEqual(JSON.parse(host.props.state), { dark: true, tokens: { panel: "panel", panelBorder: "border", panelShadowOpacity: "0.5", textPrimary: "title", textSecondary: "subtitle", textTertiary: "dim", icon: "icon", toolbarHover: "hover", toolbarPressed: "pressed" } });
});
