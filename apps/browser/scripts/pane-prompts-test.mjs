import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { devtools, launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node pane-prompts-test.mjs <Debug Solara.app> [--defaults] [--keep-data]

The pooled pane's prompts drawn from pool page events with SOLARA_NATIVE_PANE_PROMPTS=1 (page pool on), against the
same page with the switch off. Password: a real form submission brings Chrome's save prompt; with the switch on RN
mounts no PasswordPrompt and the native popover sits 8 points from the pane's top right at 350 wide, with Never on
This Site, Not Now and Save; a click on Save, after the input guard's delay, saves the login and closes it; a second
submission's prompt goes when the page navigates to another page. External app: a link to a scheme no app handles
brings the 340-wide popover 8 points below the pane's top with OK, which closes it. Autofill: a save-card prompt sent
as a pool page event draws the 350-wide popover at the top right with its accept and decline buttons; decline closes
it and clears the store, and a closed event for a second prompt takes it down. Pop-ups: a window.open without a
gesture is blocked and brings the 360-wide popover at the top right with Always Deny, Only Once, Always Allow and the
blocked URL as a row; Only Once opens it as a tab and closes the prompt; a click outside a second one dismisses it and
keeps the blocked list. Permission: a notification request and a location request queue; the native popover shows
the same request as the store's current one, 300 wide 8 points below the pane's top, and Don't Allow denies it in the
page and moves on to the next; a request goes when the page navigates. Device chooser: Chrome's Bluetooth chooser
(the DEBUG hook) draws natively at 340 wide, Cancel closes it in the engine and the store, and the unauthorized
chooser shows its notice. Engine offer: a protected-video page message brings the 320-wide WebKit offer 8 points
below the pane's top, and Stay on Page takes it down in JS and natively. With the switch off the RN wrappers still
draw each one. --defaults runs only the native leg at the app's own switch defaults, with no switch env.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-pane-prompts-"));
const rep = reporter(join(scratch, "pane-prompts-test.log"), { name: "pane-prompts-test" });

const page = (title, body) => `<!doctype html><title>${title}</title><link rel="icon" href="data:,"><body>${body}</body>`;
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/login")
    return res.end(page("Login", `<form action="/done" method="get"><input name="u" id="u" autocomplete="username"><input type="password" name="p" id="p" autocomplete="current-password"><button id="go">Sign in</button></form>`));
  if (url.pathname === "/done") return res.end(page("Done", "signed in"));
  res.end(page("Other", "other"));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: `${base}/login`, title: "Login" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const M = globalThis.expo.modules.SolaraMedia;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const act = (n, a) => C.devWindow(n, a);
const click = (n, p) => act(n, "mouse:moved:" + Math.round(p[0]) + "," + Math.round(p[1])).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + Math.round(p[0]) + "," + Math.round(p[1]))).then(() => settle(60)).then(() => act(n, "mouse:up:" + Math.round(p[0]) + "," + Math.round(p[1])));
const native = (w = "w1") => M.describePaneOverlays(w).then(JSON.parse);
const promptIn = (w, kind) => native(w).then((d) => { const p = d && d.tabs && d.tabs.a && d.tabs.a[kind]; return p && !p.hidden ? p : null; });
const rnDrawn = (name) => acPerf.findFibers(name, 5).filter((f) => !!f.child).length;
const rnPrompt = () => rnDrawn("PasswordPrompt");
const pageEvent = (name, payload) => globalThis.expo.modules.SolaraTabPool.devPageEvent("a", name, payload);
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, test, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await (typeof test === "string" ? run(test) : test()).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(150);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const centre = (f) => [f[0] + f[2] / 2, f[1] + f[3] / 2];
const nearRect = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const untilSnapshot = async (what, accept, windowId = "w1", ms = 5000, args = {}) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await app.snapshot({ ...args, windowId }).catch((error) => ({ error: error.message }));
    if (!last.error && await accept(last.windows.find((w) => w.id === windowId), last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const crossPrompt = (windowId, kind, shown) => {
  let current;
  return untilSnapshot(`${kind} snapshot`, async (window) => {
    current = await run(`return promptIn(${JSON.stringify(windowId)}, ${JSON.stringify(kind)});`);
    if (!current || current.progress !== 1 || current.opacity < 0.99 ||
      (shown.key !== undefined && current.key !== shown.key) || (shown.id !== undefined && current.id !== shown.id)) return false;
    const read = window?.paneOverlays?.tabs?.a?.[kind];
    return read && read.hidden === current.hidden && nearRect(read.frame, current.frame) && nearRect(read.card, current.card) &&
      Object.keys({ ...shown.controls, ...current.controls }).every((label) => nearRect(read.controls?.[label], current.controls?.[label])) &&
      (current.key === undefined || read.key === current.key) && (current.id === undefined || read.id === current.id);
  }, windowId).catch((error) => {
    throw new Error(`${error.message}; initial JS ${JSON.stringify(shown)}; last JS ${JSON.stringify(current)}`);
  });
};
const promptGone = (windowId, kind) => untilSnapshot(`${kind} gone`, (window) =>
  !window?.paneOverlays?.tabs?.a?.[kind], windowId);
const POOL = {
  SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_TAB_POOL: "1",
  SOLARA_CHROMIUM_SWITCHES: `--solara-test-bluetooth-chooser ${process.env.SOLARA_CHROMIUM_SWITCHES ?? ""}`.trim(),
};
const LEGS = args.includes("--defaults") ? [{ tag: "native", env: { SOLARA_CHROMIUM_SWITCHES: POOL.SOLARA_CHROMIUM_SWITCHES } }] : [
  { tag: "rn", env: { ...POOL, SOLARA_NATIVE_PANE_PROMPTS: "0" } },
  { tag: "native", env: { ...POOL, SOLARA_NATIVE_PANE_PROMPTS: "1" } },
];

async function submit(user, pass) {
  await until("the login page", `return ac.store.getState().tabs.a?.title === "Login" && !ac.store.getState().live.a?.isLoading || null;`, 10000);
  const target = await until("its DevTools target", async () => (await app.pageTarget(`${base}/login`)) ?? null, 5000);
  const cdp = await devtools(target);
  try {
    for (const [field, text] of [["u", user], ["p", pass]]) {
      await cdp.send("Runtime.evaluate", { expression: `document.getElementById('${field}').focus()` });
      await cdp.send("Input.insertText", { text });
    }
    const box = JSON.parse(await cdp.eval("JSON.stringify(document.getElementById('go').getBoundingClientRect())"));
    const at = { x: box.x + box.width / 2, y: box.y + box.height / 2, button: "left", clickCount: 1 };
    await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ...at, buttons: 1 });
    await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...at, buttons: 0 });
  } finally {
    await cdp.send("Runtime.evaluate", { expression: "document.activeElement?.blur()" }).catch(() => {});
    cdp.close();
  }
}

try {
  for (const { tag, env } of LEGS) {
    const nativePrompts = tag === "native";
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true, env,
      ready: "return !!ac.store.getState().windows.w1",
    });
    await until("page A", `return ac.store.getState().tabs.a?.title === "Login" || null;`, 15000);
    const number = await until("window w1", `const id = Object.entries(ac.pageState.getState().browsers ?? {}).find(([, t]) => t === "a")?.[0]; return id ? C.devWindowNumber(Number(id)) : null;`, 15000);
    const served = await run(`return !!globalThis.expo.modules.SolaraTabPool?.available?.() && !!ac.webviews.get("a") && !acPerf.findFibers("TabWebView", 5).length;`);
    if (!served) throw new Error(`${tag}: the pool doesn't serve page A`);
    const kinds = await run(`return globalThis.expo.modules.SolaraHosted.kinds();`);
    if (kinds.includes("panePrompts") !== nativePrompts) throw new Error(`${tag}: hosted kinds ${JSON.stringify(kinds)}`);
    await untilSnapshot("page pool and hosted prompts", (window, state) =>
      state.poolAvailable === served && window?.chromeWindowNumber === number &&
      window.mediaKinds.includes("panePrompts") === kinds.includes("panePrompts"));

    await rep.check(`${tag}-password-save`, async () => {
      await submit("ada", "s3cret-pass");
      await until("the prompt reaches the store", `return ac.pageState.getState().pages.a?.passwordPrompt?.state === "save" || null;`, 10000);
      if (!nativePrompts) {
        await until("RN draws the prompt", `return rnPrompt() || null;`, 4000);
        await promptGone("w1", "password");
        await run(`ac.pageState.setState((s) => ({ pages: { ...s.pages, a: { ...s.pages.a, passwordPrompt: null } } })); return true;`);
        return "rn";
      }
      const shown = await until("the native prompt", `return native().then((d) => d && d.tabs.a && d.tabs.a.password && !d.tabs.a.password.hidden && d.tabs.a.password.controls.Save ? d.tabs.a.password : null);`, 6000);
      await crossPrompt("w1", "password", shown);
      if (await run(`return rnPrompt();`)) throw new Error("RN still draws the password prompt");
      const [fx, fy, fw] = shown.frame;
      const [cx, cy, cw] = shown.card;
      if (Math.abs(cw - 350) > 0.5 || Math.abs(fx + fw - 8 - (cx + cw)) > 0.5 || Math.abs(fy + 8 - cy) > 0.5)
        throw new Error(`card ${JSON.stringify(shown.card)} in pane ${JSON.stringify(shown.frame)}`);
      for (const title of ["Never on This Site", "Not Now", "Save"]) if (!shown.controls[title]) throw new Error(`no ${title}: ${Object.keys(shown.controls)}`);
      await sleep(800);
      await run(`return click(${number}, ${JSON.stringify(centre(shown.controls.Save))}).then(() => true);`);
      await until("the prompt closes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.password || null);`, 3000);
      await promptGone("w1", "password");
      await until("the store's prompt clears", `return !ac.pageState.getState().pages.a?.passwordPrompt || null;`, 3000);
      const saved = await until("the saved login", `return C.listPasswords("").then((l) => (l.passwords || []).find((x) => x.username === "ada") || null);`, 8000);
      const query = { origin: base, username: "ada" };
      const savedOrigin = new URL(saved.origin).origin;
      if (savedOrigin !== base) throw new Error(`saved login belongs to ${savedOrigin}, expected ${base}`);
      await untilSnapshot("native saved login", (_, snapshot) => snapshot.savedLogin?.exists === !!saved,
        "w1", 8000, { savedLogin: query });
      return { card: shown.card, saved: !!saved };
    });

    await rep.check(`${tag}-password-gone-on-navigation`, async () => {
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/login`)}, { userInitiated: true }); return true;`);
      await submit("grace", "an0ther-pass");
      await until("a second prompt", `return ac.pageState.getState().pages.a?.passwordPrompt || null;`, 10000);
      if (nativePrompts) await until("the native prompt", `return native().then((d) => d && d.tabs.a && d.tabs.a.password || null);`, 6000);
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/other`)}, { userInitiated: true }); return true;`);
      await until("the store's prompt clears", `return !ac.pageState.getState().pages.a?.passwordPrompt || null;`, 8000);
      if (nativePrompts) await until("the native prompt goes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.password || null);`, 4000);
      await promptGone("w1", "password");
      return true;
    });

    await rep.check(`${tag}-external-app`, async () => {
      const target = await until("its DevTools target", async () => (await app.pageTarget(`${base}/other`)) ?? null, 5000);
      const cdp = await devtools(target);
      try {
        await cdp.send("Runtime.evaluate", { expression: "location.href = 'solaracore-no-such-app://hello'", userGesture: true });
      } finally {
        cdp.close();
      }
      await until("the request reaches the store", `return ac.pageState.getState().pages.a?.externalApp || null;`, 8000);
      if (!nativePrompts) {
        await until("RN draws the prompt", `return rnDrawn("ExternalAppPrompt") || null;`, 4000);
        await promptGone("w1", "externalApp");
        await run(`ac.pageState.setState((s) => ({ pages: { ...s.pages, a: { ...s.pages.a, externalApp: null } } })); return true;`);
        return "rn";
      }
      const shown = await until("the native prompt", `return native().then((d) => d && d.tabs.a && d.tabs.a.externalApp && !d.tabs.a.externalApp.hidden && d.tabs.a.externalApp.controls.OK ? d.tabs.a.externalApp : null);`, 6000);
      await crossPrompt("w1", "externalApp", shown);
      if (await run(`return rnDrawn("ExternalAppPrompt");`)) throw new Error("RN still draws the external app prompt");
      const [fx, fy, fw] = shown.frame;
      const [cx, cy, cw] = shown.card;
      if (Math.abs(cw - 340) > 0.5 || Math.abs(fy + 8 - cy) > 0.5 || cx < fx + 8 - 0.5 || cx + cw > fx + fw - 8 + 0.5)
        throw new Error(`card ${JSON.stringify(shown.card)} in pane ${JSON.stringify(shown.frame)}`);
      await sleep(800);
      await run(`return click(${number}, ${JSON.stringify(centre(shown.controls.OK))}).then(() => true);`);
      await until("the prompt closes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.externalApp || null);`, 3000);
      await promptGone("w1", "externalApp");
      await until("the store's request clears", `return !ac.pageState.getState().pages.a?.externalApp || null;`, 3000);
      return { card: shown.card };
    });

    await rep.check(`${tag}-autofill`, async () => {
      const card = (id) => ({ id, kind: "saveCard", origin: base, title: "Save card?", message: "To pay faster next time", accept: "Save", decline: "No thanks", footer: "", lines: ["Visa ending in 1111", "Ada Lovelace"] });
      await run(`return pageEvent("onAutofillPrompt", ${JSON.stringify(card(41))});`);
      await until("the prompt reaches the store", `return ac.pageState.getState().pages.a?.autofillPrompt?.id === 41 || null;`, 4000);
      if (!nativePrompts) {
        await until("RN draws the prompt", `return rnDrawn("AutofillPrompt") || null;`, 4000);
        await promptGone("w1", "autofill");
        await run(`return pageEvent("onAutofillPrompt", { id: 41, closed: true });`);
        await until("the store's prompt clears", `return !ac.pageState.getState().pages.a?.autofillPrompt || null;`, 3000);
        return "rn";
      }
      const shown = await until("the native prompt", `return native().then((d) => d && d.tabs.a && d.tabs.a.autofill && !d.tabs.a.autofill.hidden && d.tabs.a.autofill.controls["No thanks"] ? d.tabs.a.autofill : null);`, 6000);
      await crossPrompt("w1", "autofill", shown);
      if (await run(`return rnDrawn("AutofillPrompt");`)) throw new Error("RN still draws the autofill prompt");
      const [fx, fy, fw] = shown.frame;
      const [cx, cy, cw] = shown.card;
      if (Math.abs(cw - 350) > 0.5 || Math.abs(fx + fw - 8 - (cx + cw)) > 0.5 || Math.abs(fy + 8 - cy) > 0.5)
        throw new Error(`card ${JSON.stringify(shown.card)} in pane ${JSON.stringify(shown.frame)}`);
      if (!shown.controls.Save) throw new Error(`no Save: ${Object.keys(shown.controls)}`);
      await sleep(800);
      await run(`return click(${number}, ${JSON.stringify(centre(shown.controls["No thanks"]))}).then(() => true);`);
      await until("the prompt closes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.autofill || null);`, 3000);
      await promptGone("w1", "autofill");
      await until("the store's prompt clears", `return !ac.pageState.getState().pages.a?.autofillPrompt || null;`, 3000);
      await run(`return pageEvent("onAutofillPrompt", ${JSON.stringify(card(42))});`);
      const secondAutofill = await until("a second native prompt", `return native().then((d) => d && d.tabs.a && d.tabs.a.autofill || null);`, 4000);
      await crossPrompt("w1", "autofill", secondAutofill);
      await run(`return pageEvent("onAutofillPrompt", { id: 42, closed: true });`);
      await until("the closed event takes it down", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.autofill || null);`, 3000);
      await promptGone("w1", "autofill");
      return { card: shown.card };
    });

    await rep.check(`${tag}-engine-offer`, async () => {
      await run(`return pageEvent("onPageMessage", { kind: "drm", data: { keySystem: "com.widevine.alpha" } });`);
      if (!nativePrompts) {
        await until("RN draws the offer", `return rnDrawn("EngineOfferPrompt") || null;`, 4000);
        await promptGone("w1", "engineOffer");
        return "rn";
      }
      const shown = await until("the native offer", `return native().then((d) => d && d.tabs.a && d.tabs.a.engineOffer && !d.tabs.a.engineOffer.hidden && d.tabs.a.engineOffer.controls["Stay on Page"] ? d.tabs.a.engineOffer : null);`, 6000);
      await crossPrompt("w1", "engineOffer", shown);
      if (await run(`return rnDrawn("EngineOfferPrompt");`)) throw new Error("RN still draws the engine offer");
      const [fx, fy, fw] = shown.frame;
      const [cx, cy, cw] = shown.card;
      if (Math.abs(cw - 320) > 0.5 || Math.abs(fy + 8 - cy) > 0.5 || cx < fx + 8 - 0.5 || cx + cw > fx + fw - 8 + 0.5)
        throw new Error(`card ${JSON.stringify(shown.card)} in pane ${JSON.stringify(shown.frame)}`);
      if (!shown.controls["Open in WebKit"]) throw new Error(`no Open in WebKit: ${Object.keys(shown.controls)}`);
      await sleep(800);
      await run(`return click(${number}, ${JSON.stringify(centre(shown.controls["Stay on Page"]))}).then(() => true);`);
      await until("the offer goes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.engineOffer || null);`, 3000);
      await promptGone("w1", "engineOffer");
      await run(`return pageEvent("onPageMessage", { kind: "drm", data: { keySystem: "com.widevine.alpha" } });`);
      await sleep(600);
      if (await run(`return native().then((d) => !!(d && d.tabs.a && d.tabs.a.engineOffer));`)) throw new Error("the declined site was offered again");
      return { card: shown.card };
    });

    await rep.check(`${tag}-popups`, async () => {
      const blockPopup = async (path) => {
        const target = await until("its DevTools target", async () => (await app.pageTarget(`${base}/other`)) ?? null, 5000);
        const cdp = await devtools(target);
        try {
          await cdp.send("Runtime.evaluate", { expression: `window.open(${JSON.stringify(path)}, "_blank")` });
        } finally {
          cdp.close();
        }
        await until("the prompt opens", `return ac.pageState.getState().popover.a === "popups" && ac.pageState.getState().pages.a?.popups.length ? true : null;`, 8000);
      };
      const tabs = () => run(`return Object.keys(ac.store.getState().tabs).length;`);
      await blockPopup("/popped");
      if (!nativePrompts) {
        await until("RN draws the prompt", `return rnDrawn("BlockedPopupsPrompt") || null;`, 4000);
        await promptGone("w1", "popups");
        await run(`ac.pageState.setState((s) => ({ popover: { ...s.popover, a: null }, pages: { ...s.pages, a: { ...s.pages.a, popups: [] } } })); return true;`);
        return "rn";
      }
      const shown = await until("the native prompt", `return native().then((d) => d && d.tabs.a && d.tabs.a.popups && !d.tabs.a.popups.hidden && d.tabs.a.popups.controls["Only Once"] ? d.tabs.a.popups : null);`, 6000);
      await crossPrompt("w1", "popups", shown);
      if (await run(`return rnDrawn("BlockedPopupsPrompt");`)) throw new Error("RN still draws the pop-ups prompt");
      const [fx, fy, fw] = shown.frame;
      const [cx, cy, cw] = shown.card;
      if (Math.abs(cw - 360) > 0.5 || Math.abs(fx + fw - 8 - (cx + cw)) > 0.5 || Math.abs(fy + 8 - cy) > 0.5)
        throw new Error(`card ${JSON.stringify(shown.card)} in pane ${JSON.stringify(shown.frame)}`);
      for (const title of ["Always Deny", "Always Allow", "127.0.0.1:" + new URL(base).port + "/popped"]) if (!shown.controls[title]) throw new Error(`no ${title}: ${Object.keys(shown.controls)}`);
      const before = await tabs();
      await sleep(800);
      await run(`return click(${number}, ${JSON.stringify(centre(shown.controls["Only Once"]))}).then(() => true);`);
      await until("the prompt closes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.popups || null);`, 3000);
      await promptGone("w1", "popups");
      await until("the store clears", `return !ac.pageState.getState().popover.a && !ac.pageState.getState().pages.a?.popups.length || null;`, 3000);
      await until("the pop-up opens as a tab", async () => ((await tabs()) > before ? true : null), 6000);
      await run(`ac.store.getState().activate("a"); return true;`);
      await until("page A is shown again", `return native().then((d) => d && d.tabs.a ? true : null);`, 4000).catch(() => {});
      await blockPopup("/popped-again");
      const second = await until("a second native prompt", `return native().then((d) => d && d.tabs.a && d.tabs.a.popups && !d.tabs.a.popups.hidden ? d.tabs.a.popups : null);`, 6000);
      await crossPrompt("w1", "popups", second);
      await sleep(400);
      await run(`return click(${number}, ${JSON.stringify([second.frame[0] + 40, second.frame[1] + second.frame[3] - 40])}).then(() => true);`);
      await until("a click outside dismisses it", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.popups || null);`, 3000);
      await promptGone("w1", "popups");
      await until("the popover state clears", `return !ac.pageState.getState().popover.a || null;`, 3000);
      if (!(await run(`return ac.pageState.getState().pages.a?.popups.length;`))) throw new Error("dismissing dropped the blocked list");
      return { card: shown.card };
    });

    await rep.check(`${tag}-permission`, async () => {
      const other = `${base.replace("127.0.0.1", "localhost")}/other`;
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(other)}, { userInitiated: true }); return true;`);
      await until("the localhost page", `return ac.store.getState().tabs.a?.url === ${JSON.stringify(other)} && !ac.store.getState().live.a?.isLoading || null;`, 10000);
      const inPage = async (expression) => {
        const target = await until("its DevTools target", async () => (await app.pageTarget(other)) ?? null, 5000);
        const cdp = await devtools(target);
        try {
          return (await cdp.send("Runtime.evaluate", { expression, userGesture: true, returnByValue: true })).result?.value;
        } finally {
          cdp.close();
        }
      };
      const current = `return ac.pageState.getState().pages.a?.permission ?? null;`;
      await inPage("Notification.requestPermission(); true");
      await until("the request reaches the store", current, 8000);
      await inPage("navigator.geolocation.getCurrentPosition(() => {}, () => {}); true");
      if (!nativePrompts) {
        await until("RN draws the prompt", `return rnDrawn("PermissionPrompt") || null;`, 4000);
        await promptGone("w1", "permission");
        await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/other`)}, { userInitiated: true }); return true;`);
        await until("navigation drops it", `return !ac.pageState.getState().pages.a?.permission || null;`, 8000);
        return "rn";
      }
      const shownFor = (request) =>
        until(`the native prompt for ${request.permissions}`, `return native().then((d) => { const p = d && d.tabs.a && d.tabs.a.permission; return p && !p.hidden && p.controls["Don't Allow"] && p.key === ${JSON.stringify(request.id)} ? p : null; });`, 6000).catch(async (e) => {
          throw new Error(`${e.message}; native shows ${await run("return native().then((d) => d.tabs.a && d.tabs.a.permission && d.tabs.a.permission.key);")}`);
        });
      const first = await run(current);
      const shown = await shownFor(first);
      await crossPrompt("w1", "permission", shown);
      if (await run(`return rnDrawn("PermissionPrompt");`)) throw new Error("RN still draws the permission prompt");
      const [fx, fy, fw] = shown.frame;
      const [cx, cy, cw] = shown.card;
      if (Math.abs(cw - 300) > 0.5 || Math.abs(fy + 8 - cy) > 0.5 || cx < fx + 8 - 0.5 || cx + cw > fx + fw - 8 + 0.5)
        throw new Error(`card ${JSON.stringify(shown.card)} in pane ${JSON.stringify(shown.frame)}`);
      await sleep(800);
      await run(`return click(${number}, ${JSON.stringify(centre(shown.controls["Don't Allow"]))}).then(() => true);`);
      if (first.permissions.includes("notifications")) await until("the page sees the denial", async () => ((await inPage("Notification.permission")) === "denied" ? true : null), 5000);
      const second = await until("the store moves on", `const p = ac.pageState.getState().pages.a?.permission; return p && p.id !== ${JSON.stringify(first.id)} ? p : null;`, 6000).catch(() => null);
      if (second) {
        const next = await shownFor(second);
        await crossPrompt("w1", "permission", next);
        await sleep(800);
        await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/other`)}, { userInitiated: true }); return true;`);
        await until("navigation drops it in the store", `return !ac.pageState.getState().pages.a?.permission || null;`, 8000);
        await until("and natively", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.permission || null);`, 4000);
        await promptGone("w1", "permission");
        return { card: shown.card, first: first.permissions, queued: second.permissions, next: next.card };
      }
      await until("the native prompt closes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.permission || null);`, 4000);
      await promptGone("w1", "permission");
      return { card: shown.card, first: first.permissions, queued: null };
    });

    await rep.check(`${tag}-device-chooser`, async () => {
      const browserId = await run(`return Number(Object.entries(ac.pageState.getState().browsers).find(([, t]) => t === "a")?.[0]);`);
      const UI = `globalThis.expo.modules.SolaraChromeUI`;
      const chooserId = `return globalThis.acDeviceChoosers.useChoosers.getState().byTab.a?.id ?? null;`;
      if (!(await run(`return ${UI}.devShowBluetoothChooser(${browserId}, false);`))) throw new Error("the DEBUG chooser hook is missing");
      const id = await until("the chooser reaches JS", chooserId, 6000);
      if (!nativePrompts) {
        await until("RN draws the chooser", `return rnDrawn("DeviceChooser") || null;`, 4000);
        await promptGone("w1", "deviceChooser");
        await run(`return globalThis.acDeviceChoosers.cancelDeviceChooser(${id}).then(() => true);`);
        await until("it closes", `return globalThis.acDeviceChoosers.useChoosers.getState().byTab.a ? null : true;`, 4000);
        return "rn";
      }
      const shown = await until("the native chooser", `return native().then((d) => d && d.tabs.a && d.tabs.a.deviceChooser && !d.tabs.a.deviceChooser.hidden && d.tabs.a.deviceChooser.controls.Cancel && d.tabs.a.deviceChooser.id === ${id} ? d.tabs.a.deviceChooser : null);`, 6000);
      await crossPrompt("w1", "deviceChooser", shown);
      if (await run(`return rnDrawn("DeviceChooser");`)) throw new Error("RN still draws the device chooser");
      const [fx, fy] = shown.frame;
      const [, cy, cw] = shown.card;
      if (Math.abs(cw - 340) > 0.5 || Math.abs(fy + 8 - cy) > 0.5) throw new Error(`card ${JSON.stringify(shown.card)} in pane ${JSON.stringify(shown.frame)} (x ${fx})`);
      await sleep(800);
      await run(`return click(${number}, ${JSON.stringify(centre(shown.controls.Cancel))}).then(() => true);`);
      await until("the engine closes it", `return globalThis.acDeviceChoosers.useChoosers.getState().byTab.a ? null : true;`, 4000);
      await until("the native chooser goes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.deviceChooser || null);`, 3000);
      await promptGone("w1", "deviceChooser");
      await run(`return ${UI}.devShowBluetoothChooser(${browserId}, true);`);
      const lockedId = await until("the unauthorized chooser in JS", `const c = globalThis.acDeviceChoosers.useChoosers.getState().byTab.a; return c && c.unauthorized ? c.id : null;`, 6000);
      const locked = await until("the unauthorized chooser", `return native().then((d) => d && d.tabs.a && d.tabs.a.deviceChooser && d.tabs.a.deviceChooser.id === ${lockedId} && d.tabs.a.deviceChooser.controls.Cancel ? d.tabs.a.deviceChooser : null);`, 6000);
      await crossPrompt("w1", "deviceChooser", locked);
      await sleep(800);
      await run(`return click(${number}, ${JSON.stringify(centre(locked.controls.Cancel))}).then(() => true);`);
      await until("it closes too", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.deviceChooser || null);`, 3000);
      await promptGone("w1", "deviceChooser");
      return { card: shown.card };
    });

    await rep.check(`${tag}-prompts-move-with-their-tab`, async () => {
      if (!nativePrompts) return "rn";
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/login`)}, { userInitiated: true }); return true;`);
      await submit("hopper", "th1rd-pass");
      await until("a password prompt", `return ac.pageState.getState().pages.a?.passwordPrompt || null;`, 10000);
      const sourcePrompt = await until("drawn in w1", `return promptIn("w1", "password");`, 6000);
      await crossPrompt("w1", "password", sourcePrompt);
      await run(`ac.store.getState().newTab("w1"); return true;`);
      const to = await run(`return ac.store.getState().moveTabsToWindow(["a"], null) ?? null;`);
      if (!to) throw new Error("no new window");
      await until("the password prompt leaves w1", `return promptIn("w1", "password").then((p) => !p || null);`, 5000);
      await promptGone("w1", "password");
      const movedPassword = await until("and shows in the new window", `return promptIn(${JSON.stringify(to)}, "password");`, 5000).catch(async (e) => {
        const seen = await run(`return native(${JSON.stringify(to)}).then((d) => ({ overlays: d, prompt: !!ac.pageState.getState().pages.a?.passwordPrompt, window: ac.store.getState().tabs.a?.windowId }));`).catch((x) => String(x));
        throw new Error(`${e.message}; ${JSON.stringify(seen)}`);
      });
      await crossPrompt(to, "password", movedPassword);
      await untilSnapshot("password prompt tab ownership", (_, state) => state.tabs.some((tab) => tab.id === "a" && tab.windowId === to), to);
      const other = `${base.replace("127.0.0.1", "localhost")}/other`;
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(other)}, { userInitiated: true }); return true;`);
      await until("navigation drops the password prompt", `return promptIn(${JSON.stringify(to)}, "password").then((p) => !p || null);`, 8000);
      await promptGone(to, "password");
      await until("the localhost page", `return ac.store.getState().tabs.a?.url === ${JSON.stringify(other)} && !ac.store.getState().live.a?.isLoading || null;`, 10000);
      const target = await until("its DevTools target", async () => (await app.pageTarget(other)) ?? null, 5000);
      const cdp = await devtools(target);
      try {
        await cdp.send("Runtime.evaluate", { expression: "navigator.geolocation.getCurrentPosition(() => {}, () => {}); true", userGesture: true });
      } finally {
        cdp.close();
      }
      const movedPermission = await until("a permission prompt in the new window", `return promptIn(${JSON.stringify(to)}, "permission");`, 8000);
      await crossPrompt(to, "permission", movedPermission);
      await run(`ac.store.getState().moveTabsToWindow(["a"], "w1"); return true;`);
      const returnedPermission = await until("the permission prompt follows it back to w1", `return promptIn("w1", "permission");`, 5000);
      await crossPrompt("w1", "permission", returnedPermission);
      await untilSnapshot("permission prompt tab ownership", (_, state) => state.tabs.some((tab) => tab.id === "a" && tab.windowId === "w1"));
      const left = await run(`return native(${JSON.stringify(to)}).then((d) => !!(d && d.tabs && d.tabs.a));`);
      if (left) throw new Error("the old window still draws tab a's prompts");
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/other`)}, { userInitiated: true }); return true;`);
      await until("navigation drops it", `return promptIn("w1", "permission").then((p) => !p || null);`, 8000);
      await promptGone("w1", "permission");
      return { to };
    });

    await app.quit();
    app = null;
  }
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
