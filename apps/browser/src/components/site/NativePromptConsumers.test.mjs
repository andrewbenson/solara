import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const urls = new Set(["Prompts", "NativePromptBody"].map((name) => new URL(`./${name}.tsx`, import.meta.url).href));
const bodyURL = new URL("./NativePromptBody.tsx", import.meta.url).href;
const f = globalThis.nativePromptConsumersTest = {};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `export const nativeToolbarAvailable = () => false, nativePagesAvailable = () => false; export const NativePromptView = "NativePromptView";`,
  "@solara/shell": `export const Symbol = "Symbol";`,
  react: `
    export const useState = initial => {
      const f = globalThis.nativePromptConsumersTest, i = f.index++;
      if (!(i in f.states)) f.states[i] = typeof initial === "function" ? initial() : initial;
      return [f.states[i], value => { f.states[i] = value; }];
    };
    export const useEffect = () => {};
    export const createContext = () => ({Provider:"PlacementProvider"});
    export const useContext = () => globalThis.nativePromptConsumersTest.placement;`,
  "react-native": `export const Image = "Image", Pressable = "Pressable", ScrollView = "ScrollView", ActivityIndicator = "ActivityIndicator", Text = "Text", View = "View", StyleSheet = {absoluteFill:{position:"absolute"}};`,
  "../../lib/theme": `export const useTheme = () => globalThis.nativePromptConsumersTest.theme;`,
  "../../lib/productName": `export const PRODUCT = "Solara";`,
  "../../lib/webviews": `export const webviews = new Map([["a", {
    resolvePasswordPrompt: (...args) => globalThis.nativePromptConsumersTest.actions.push(["password", ...args]),
    resolveAutofillPrompt: (...args) => globalThis.nativePromptConsumersTest.actions.push(["autofill", ...args]),
  }]]);`,
  "../primitives": `export const useHover = () => ({hovered:false,hoverProps:{}});`,
  "../settings/controls": `export const Checkbox = "Checkbox", useFormColors = () => ({accent:"accent",control:"control",controlBorder:"border"});`,
  "../layout/controls": `export const PANEL = {}, Popover = "RNPopover", PromptButton = "RNButton", PanelCloseButton = "RNClose", PopoverRow = "RNRow", PopoverSeparator = "RNSeparator";`,
  "../layout/pageState": `
    export const usePage = (id, select) => select(globalThis.nativePromptConsumersTest.page);
    export const pageOf = () => globalThis.nativePromptConsumersTest.page;
    export const patchPage = (id, patch) => Object.assign(globalThis.nativePromptConsumersTest.page, patch);`,
  "./promptGuard": `export const usePromptInputGuard = key => action => (...args) => { if (globalThis.nativePromptConsumersTest.allow) action(...args); };`,
};
const nativeBodyStub = `export const NativePromptBody = "NativePromptBody", PromptPopover = "PromptPopover", nativePromptFrames = () => false, usePromptPlacement = () => globalThis.nativePromptConsumersTest.placement;`;
const hooks = registerHooks({ resolve(specifier, context, next) {
  if (!urls.has(context.parentURL)) return next(specifier, context);
  if (specifier === "./NativePromptBody") return fake(nativeBodyStub);
  return specifier in sources ? fake(sources[specifier]) : next(specifier, context);
} });
const prompts = await import("./Prompts.tsx");
const nativeBody = await import(bodyURL);
after(() => { hooks.deregister(); delete globalThis.nativePromptConsumersTest; });
const render = (fn, props = {}) => { f.index = 0; return fn({tabId:"a",left:12,right:8,top:8,...props}); };
const promptChild = (element) => {
  assert.equal(element.type, "PromptPopover");
  assert.equal(element.props.children.type, "NativePromptBody");
  return element.props.children.props;
};
beforeEach(() => Object.assign(f, {
  index:0, states:[], actions:[], allow:true, placement:null, page:{},
  theme:{dark:false,textPrimary:"ink",textSecondary:"dim",toolbarHover:"hover",rowHover:"row",icon:"icon",accent:"accent",goButton:"go",goButtonText:"goText"},
}));

test("native password updates retain the selected username and dismissal behavior", () => {
  f.page.passwordPrompt = {origin:"https://login.test",username:"Ada",state:"update",usernames:["Ada","Grace"],passwordLength:12};
  let body = promptChild(render(prompts.PasswordPrompt));
  body.onChoice("Grace");
  body = promptChild(render(prompts.PasswordPrompt));
  body.onButton("update");
  assert.deepEqual(f.actions[0],["password","update",{username:"Grace"}]);
  assert.equal(f.page.passwordPrompt,null);
});

test("native autofill prompts forward the prompt id and answer", () => {
  f.page.autofillPrompt = {id:41,kind:"saveCard",title:"Save card?",message:"Card",lines:["Ada","1234"],accept:"Save",decline:"No"};
  const body = promptChild(render(prompts.AutofillPrompt));
  body.onButton("accept");
  assert.deepEqual(f.actions[0],["autofill",41,"accept"]);
  assert.equal(f.page.autofillPrompt,null);
});

test("prompt placement always supplies the native frame independently of other surface capabilities", () => {
  const host = nativeBody.PromptPopover({width:340,top:8,left:12,modal:false,children:"body"});
  assert.equal(host.type,"PlacementProvider");
  assert.deepEqual(host.props.value.placement,{width:340,top:8,left:12,right:null,modal:false});
});

test("native prompt body forwards all native events and retains protection and placement state", () => {
  f.placement = {placement:{width:300,top:8,left:12,right:null,modal:false},onDismiss:()=>f.actions.push(["dismiss"])};
  const props = {spec:{icons:["bell"],title:"Allow?",inputProtectionKey:"request-1",buttons:[{id:"accept",title:"Allow"}]},onButton:id=>f.actions.push(["button",id]),onChoice:id=>f.actions.push(["choice",id]),onToggle:value=>f.actions.push(["toggle",value]),onClose:()=>f.actions.push(["close"])};
  const host = render(nativeBody.NativePromptBody,props);
  assert.equal(host.type,"NativePromptView");
  const state = JSON.parse(host.props.state);
  assert.equal(state.inputProtectionKey,"request-1");
  assert.deepEqual(state.popover,f.placement.placement);
  for (const event of [{kind:"button",id:"accept"},{kind:"choice",id:"Ada"},{kind:"toggle",value:true},{kind:"close"},{kind:"dismiss"}]) host.props.onPromptEvent({nativeEvent:event});
  assert.deepEqual(f.actions,[["button","accept"],["choice","Ada"],["toggle",true],["close"],["dismiss"]]);
});
