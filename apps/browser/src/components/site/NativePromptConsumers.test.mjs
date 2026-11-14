import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const urls = new Set(["Prompts", "EnginePrompt", "DeviceChooser", "NativePromptBody"].map((name) => new URL(`./${name}.tsx`, import.meta.url).href));
const bodyURL = new URL("./NativePromptBody.tsx", import.meta.url).href;
const f = globalThis.nativePromptConsumersTest = {};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `export const nativeToolbarAvailable = () => false, nativePagesAvailable = () => false; export const NativePromptView = "NativePromptView", NativeDeviceChooserView = "NativeDeviceChooserView";`,
  "@solara/solaracore": `
    const f = globalThis.nativePromptConsumersTest;
    export const getSiteSettings = async () => ({popups:{isDefault:true}});
    export const resolveExternalApp = (...args) => f.actions.push(["external", ...args]);
    export const setSiteSetting = (...args) => f.actions.push(["site", ...args]);
    export const cancelDeviceChooser = (...args) => f.actions.push(["cancelDevice", ...args]);
    export const selectDevice = (...args) => f.actions.push(["selectDevice", ...args]);
    export const refreshDeviceChooser = (...args) => f.actions.push(["refreshDevice", ...args]);
    export const openBluetoothSettings = (...args) => f.actions.push(["settingsDevice", ...args]);
    export const onDeviceChooser = () => {};`,
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
  zustand: `export const create = () => () => select => select({byTab:{a:globalThis.nativePromptConsumersTest.chooser}});`,
  "../../lib/theme": `export const useTheme = () => globalThis.nativePromptConsumersTest.theme;`,
  "../../lib/productName": `export const PRODUCT = "Solara";`,
  "../../lib/webviews": `export const webviews = new Map([["a", {
    resolvePasswordPrompt: (...args) => globalThis.nativePromptConsumersTest.actions.push(["password", ...args]),
    resolveAutofillPrompt: (...args) => globalThis.nativePromptConsumersTest.actions.push(["autofill", ...args]),
    openBlockedPopup: (...args) => globalThis.nativePromptConsumersTest.actions.push(["popup", ...args])
  }]]);`,
  "../../lib/engines": `export const useEngineOffers = select => select({a:globalThis.nativePromptConsumersTest.offer}); export const stayOnPage = (...args) => globalThis.nativePromptConsumersTest.actions.push(["stay", ...args]); export const acceptEngineOffer = (...args) => globalThis.nativePromptConsumersTest.actions.push(["webkit", ...args]);`,
  "../../store/browser": `export const useBrowser = Object.assign(select => select(globalThis.nativePromptConsumersTest.store), {getState:() => globalThis.nativePromptConsumersTest.store, subscribe:()=>{}});`,
  "../../store/model": `export const engineProfile = id => id;`,
  "../primitives": `export const useHover = () => ({hovered:false,hoverProps:{}});`,
  "../settings/controls": `export const Checkbox = "Checkbox", useFormColors = () => ({accent:"accent",control:"control",controlBorder:"border"});`,
  "../layout/controls": `export const PANEL = {}, Popover = "RNPopover", PromptButton = "RNButton", PanelCloseButton = "RNClose", PopoverRow = "RNRow", PopoverSeparator = "RNSeparator";`,
  "../layout/pageState": `
    export const usePage = (id, select) => select(globalThis.nativePromptConsumersTest.page);
    export const pageOf = () => globalThis.nativePromptConsumersTest.page;
    export const patchPage = (id, patch) => { Object.assign(globalThis.nativePromptConsumersTest.page, patch); globalThis.nativePromptConsumersTest.actions.push(["patch",id,patch]); };
    export const setPopover = (...args) => globalThis.nativePromptConsumersTest.actions.push(["popover",...args]);
    export const tabForBrowser = () => "a";`,
  "./permissions": `export const describePermission = () => ({icons:["bell"],question:"Allow notifications?"}), answerPermission = (...args) => globalThis.nativePromptConsumersTest.actions.push(["permission",...args]);`,
  "./promptGuard": `export const usePromptInputGuard = key => action => (...args) => { if (globalThis.nativePromptConsumersTest.allow) action(...args); };`,
};
const nativeBodyStub = `export const NativePromptBody = "NativePromptBody", PromptPopover = "PromptPopover", nativePromptFrames = () => false, usePromptPlacement = () => globalThis.nativePromptConsumersTest.placement;`;
const hooks = registerHooks({ resolve(specifier, context, next) {
  if (!urls.has(context.parentURL)) return next(specifier, context);
  if (specifier === "./NativePromptBody") return fake(nativeBodyStub);
  return specifier in sources ? fake(sources[specifier]) : next(specifier, context);
} });
const prompts = await import("./Prompts.tsx");
const { EngineOfferPrompt } = await import("./EnginePrompt.tsx");
const { DeviceChooser } = await import("./DeviceChooser.tsx");
const nativeBody = await import(bodyURL);
after(() => { hooks.deregister(); delete globalThis.nativePromptConsumersTest; });
const render = (fn, props = {}) => { f.index = 0; return fn({tabId:"a",left:12,right:8,top:8,...props}); };
const promptChild = (element) => {
  assert.equal(element.type, "PromptPopover");
  assert.equal(element.props.children.type, "NativePromptBody");
  return element.props.children.props;
};
beforeEach(() => Object.assign(f, {
  index:0, states:[], actions:[], allow:true, placement:null,
  store:{tabs:{a:{profileId:"default"}}}, page:{popups:[]},
  theme:{dark:false,textPrimary:"ink",textSecondary:"dim",toolbarHover:"hover",rowHover:"row",icon:"icon",accent:"accent",goButton:"go",goButtonText:"goText"},
  offer:{site:"video.test",host:"video.test",canRemember:true},
  chooser:{id:"device-1",open:true,title:"Choose a device",options:[{name:"Device",connected:false,paired:true,signal:3}],bothButtonsEnabled:false,adapterOff:false,unauthorized:false,showSignal:true,refreshing:false,canRefresh:true,scanningText:"Scanning",noOptionsText:"No devices",cancelLabel:"Cancel",okLabel:"Connect"},
}));

test("permission prompts mount native controls without a toolbar capability and preserve the input guard", () => {
  f.page.permission = {id:"permission-1"};
  const body = promptChild(render(prompts.PermissionPrompt));
  assert.equal(body.spec.inputProtectionKey,"permission-1");
  f.allow = false;
  body.onButton("accept");
  assert.deepEqual(f.actions,[]);
  f.allow = true;
  body.onButton("deny");
  body.onClose();
  assert.deepEqual(f.actions,[["permission","a","permission-1","deny"],["permission","a","permission-1","dismiss"]]);
});

test("blocked popup rows and site denial share a native popover without native page capability", () => {
  f.page.popups = [{id:"one",origin:"https://popup.test",url:"https://popup.test/one"},{id:"two",origin:"https://popup.test",url:"https://popup.test/two"}];
  const host = render(prompts.BlockedPopupsPrompt);
  const body = promptChild(host);
  assert.deepEqual(body.spec.rows.map(row => row.id),["one","two"]);
  body.onRow("one");
  assert.deepEqual(f.actions[0],["popup","one",false]);
  assert.deepEqual(f.page.popups.map(popup => popup.id),["two"]);
  body.onButton("deny");
  assert.deepEqual(f.actions.find(action => action[0] === "site"),["site","default","https://popup.test","popups","block"]);
  assert.deepEqual(f.page.popups,[]);
  host.props.onDismiss();
  assert.deepEqual(f.actions.at(-1),["popover","a",null]);
});

for (const [answer, always] of [["once", false], ["allow", true], ["dismiss", null]]) {
  test(`native popup ${answer} keeps the existing opening and retention behavior`, () => {
    f.page.popups = [{id:"one",origin:"https://popup.test",url:"https://popup.test/one"}];
    const body = promptChild(render(prompts.BlockedPopupsPrompt));
    body.onButton(answer);
    assert.deepEqual(f.actions.filter(action => action[0] === "popup"),always === null ? [] : [["popup","one",always]]);
    assert.equal(f.page.popups.length,always === null ? 1 : 0);
    assert.deepEqual(f.actions.at(-1),["popover","a",null]);
  });
}

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

test("external app native controls keep remembered approval gated and resolve the same request", () => {
  f.page.externalApp = {id:7,app:"Fixture",title:"Open Fixture?",message:"Open",remember:"Always allow"};
  let body = promptChild(render(prompts.ExternalAppPrompt));
  body.onToggle(true);
  body = promptChild(render(prompts.ExternalAppPrompt));
  f.allow = false;
  body.onButton("open");
  assert.deepEqual(f.actions,[]);
  f.allow = true;
  body.onButton("open");
  assert.deepEqual(f.actions,[["patch","a",{externalApp:null}],["external",7,true,true]]);
});

test("engine offer native controls preserve remember, stay, open and close actions", () => {
  const offer = render(EngineOfferPrompt);
  let body = promptChild(render(offer.type,offer.props));
  body.onToggle(true);
  body = promptChild(render(offer.type,offer.props));
  body.onButton("stay");
  body.onButton("webkit");
  body.onClose();
  assert.deepEqual(f.actions,[["stay","a",true],["webkit","a"],["stay","a"]]);
});

test("device chooser native events preserve selection, chooser identity and auxiliary actions", () => {
  f.states = [0];
  const host = render(DeviceChooser);
  assert.equal(host.type,"PromptPopover");
  const body = host.props.children;
  assert.equal(JSON.parse(body.props.state).id,"device-1");
  f.placement = {placement:{width:340,top:8,left:12,right:null,modal:false}};
  const view = render(body.type,body.props);
  assert.equal(view.type,"NativeDeviceChooserView");
  assert.deepEqual(JSON.parse(view.props.state).popover,f.placement.placement);
  body.props.onEvent({kind:"choose",index:0});
  body.props.onEvent({kind:"cancel"});
  body.props.onEvent({kind:"refresh"});
  body.props.onEvent({kind:"openSettings"});
  assert.deepEqual(f.actions,[["selectDevice","device-1",0],["cancelDevice","device-1"],["refreshDevice","device-1"],["settingsDevice","device-1"]]);
  f.chooser.bothButtonsEnabled = true;
  render(DeviceChooser).props.children.props.onEvent({kind:"choose",index:-1});
  assert.deepEqual(f.actions.at(-1),["selectDevice","device-1",-1]);
});

test("prompt placement always supplies the native frame independently of other surface capabilities", () => {
  const host = nativeBody.PromptPopover({width:340,top:8,left:12,modal:false,children:"body"});
  assert.equal(host.type,"PlacementProvider");
  assert.deepEqual(host.props.value.placement,{width:340,top:8,left:12,right:null,modal:false});
});

test("native prompt body forwards all native events and retains protection and placement state", () => {
  f.placement = {placement:{width:300,top:8,left:12,right:null,modal:false},onDismiss:()=>f.actions.push(["dismiss"])};
  const props = {spec:{icons:["bell"],title:"Allow?",inputProtectionKey:"request-1",buttons:[{id:"accept",title:"Allow"}]},onButton:id=>f.actions.push(["button",id]),onChoice:id=>f.actions.push(["choice",id]),onToggle:value=>f.actions.push(["toggle",value]),onClose:()=>f.actions.push(["close"]),onRow:id=>f.actions.push(["row",id])};
  const host = render(nativeBody.NativePromptBody,props);
  assert.equal(host.type,"NativePromptView");
  const state = JSON.parse(host.props.state);
  assert.equal(state.inputProtectionKey,"request-1");
  assert.deepEqual(state.popover,f.placement.placement);
  for (const event of [{kind:"button",id:"accept"},{kind:"choice",id:"Ada"},{kind:"toggle",value:true},{kind:"row",id:"one"},{kind:"close"},{kind:"dismiss"}]) host.props.onPromptEvent({nativeEvent:event});
  assert.deepEqual(f.actions,[["button","accept"],["choice","Ada"],["toggle",true],["row","one"],["close"],["dismiss"]]);
});
