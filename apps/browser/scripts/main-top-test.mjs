import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node main-top-test.mjs <Debug Solara.app> [--keep-data]

The window's RN main root on top of the native shell's layers (SOLARA_SHELL_MAIN_TOP=1, with SOLARA_NATIVE_SHELL=1,
SOLARA_SHELL_PANES=1 and SOLARA_NATIVE_PAGES_POOL=1), once with the native sidebar column (SOLARA_NATIVE_SIDEBAR=1,
SOLARA_NATIVE_TOP_STRIP=1, SOLARA_NATIVE_PROFILE_PAGER=1: the column must be up), once with the native sidebar alone and once
with RN's: the root is stacked under the overlay and above every other slot (the profile pager's swipe targets, which
draw nothing and hit nothing, sit above the overlay as the shell keeps views it doesn't own, and don't count);
no React Native view that draws nothing and handles nothing catches the pointer over the card, the sidebar or the top
strip (devReactBlockers hit-tests a grid over them and names each RN view there with no background or content; the
ones with their own mouse enter or leave handler, or a press, click, responder or drop handler on themselves or a
parent no more than twice their area, are controls and pass, and the report names the parent and prop that made each one); a click on the page
lands on the page, outside the main root, and focuses it; and file, URL and text drops there go to the web contents.
The pool must serve the pages: a build where SolaraTabPool isn't available, or a page still under the main root, fails
the click check.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-main-top-"));
const rep = reporter(join(scratch, "main-top-test.log"), { name: "main-top-test" });
const WEB = /RenderWidgetHostViewCocoa|WebContentsViewCocoa|SolaraCoreWebView/;
const TYPES = ["public.file-url", "public.url", "public.utf8-plain-text"];

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${req.url.slice(1).toUpperCase()}</title><link rel="icon" href="data:,"><body style="height:2000px">${req.url.slice(1)}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (n) => `http://127.0.0.1:${server.address().port}/${n}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("one"), title: "ONE" }, { id: "b", url: url("two"), title: "TWO" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const S = () => ac.store.getState();
const W = globalThis.expo.modules.SolaraWindowShell;
const describe = () => W.describe("w1").then(JSON.parse);
`;
const PRESS_PROPS = ["onPress", "onPressIn", "onClick", "onMouseDown", "onStartShouldSetResponder", "onResponderGrant", "draggedTypes", "onDrop", "onDragEnter"];
const OWN_PROPS = ["onMouseEnter", "onMouseLeave"];
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};

const untilSnapshot = async (what, accept, args = {}, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await app.snapshot(args).catch((error) => ({ error: error.message }));
    if (!last.error && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const rectNear = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);

async function pass(label, env) {
  app = await launch(resolve(appArg), {
    data: join(scratch, `data-${label}`), fresh: true, session: fixture, onboarded: true, probe: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_SHELL_MAIN_TOP: "1", ...env },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.expo.modules.SolaraWindowShell && !!globalThis.acPerf",
  });
  await until("page ONE", `return S().tabs.a.title === "ONE" || null;`, 15000);
  await sleep(1500);
  const shell = await run(`return describe();`);

  await rep.check(`${label}: the-main-root-is-under-the-overlay-and-above-the-rest`, async () => {
    const order = shell.order.filter((name) => name !== "SolaraSettingsAdapter.NativeSwipeTarget");
    if (!shell.reactOnTop) throw new Error(`the flag didn't take: ${JSON.stringify(shell)}`);
    if (order.at(-1) !== "SolaraUI.ShellOverlayView" || order.at(-2) !== "RCTRootView") throw new Error(`order ${order.join(" < ")}`);
    const snapshot = await untilSnapshot("shell layer order", (state) => {
      const native = state.windows.find((w) => w.id === "w1")?.shell;
      return native?.reactOnTop === shell.reactOnTop &&
        JSON.stringify(native.order.filter((name) => name !== "SolaraSettingsAdapter.NativeSwipeTarget")) === JSON.stringify(order) &&
        rectNear(native.card, shell.card);
    }, { windowId: "w1" });
    return { order: order.join(" < "), native: snapshot.windows.find((w) => w.id === "w1").shell.order };
  });

  if (env.SOLARA_NATIVE_PROFILE_PAGER === "1")
    await rep.check(`${label}: the-native-sidebar-column-is-up`, async () => {
      const column = await run(`return globalThis.expo.modules.SolaraHosted.sidebarShell("w1").then(JSON.parse);`);
      if (!column?.chrome) throw new Error(`no native column: ${JSON.stringify(column)}`);
      await untilSnapshot("native sidebar column", (state) => {
        const native = state.windows.find((w) => w.id === "w1")?.sidebarShell;
        return native?.chrome && rectNear(native.frame, column.frame);
      }, { windowId: "w1" });
      return { frame: column.frame };
    });

  await rep.check(`${label}: no-rn-view-that-draws-and-handles-nothing-catches-the-pointer`, async () => {
    const found = await run(`return W.devReactBlockers("w1", 24).then(JSON.parse).then((views) => views.map((v) => {
      const press = ${JSON.stringify(PRESS_PROPS)};
      const host = typeof v.reactTag === "number" ? acPerf.hostFiber(v.reactTag) : null;
      const own = (host && host.memoizedProps) || {};
      const ownerOf = (fiber) => { for (let c = fiber && fiber.return; c; c = c.return) { const n = typeof c.type === "string" ? null : acPerf.nameOf(c.type); if (n && n !== "View" && n !== "Animated(View)") return n; } return null; };
      let by = null;
      const ownProp = ${JSON.stringify(OWN_PROPS)}.concat(press).find((k) => own[k] != null);
      if (ownProp) by = { prop: ownProp, depth: 0, tag: v.reactTag, owner: ownerOf(host) };
      const area = v.frame[2] * v.frame[3];
      let stoppedAt = null;
      for (let i = 0; !by && i < (v.ancestors || []).length; i++) {
        const [tag, w, h] = v.ancestors[i];
        if (w * h > 2 * area) { stoppedAt = { tag, depth: i + 1, size: [w, h] }; break; }
        const fiber = acPerf.hostFiber(tag);
        const props = (fiber && fiber.memoizedProps) || {};
        const prop = press.find((k) => props[k] != null);
        if (prop) by = { prop, depth: i + 1, tag, owner: ownerOf(fiber) };
      }
      return { ...v, ancestors: undefined, owner: ownerOf(host), control: !!by, by, stoppedAt, resolved: !!host };
    }));`);
    await untilSnapshot("React hit samples", (state) => {
      const native = state.windows.find((w) => w.id === "w1")?.reactBlockers;
      return Array.isArray(native) && native.length === found.length && found.every((view) =>
        native.some((item) => item.reactTag === view.reactTag && item.class === view.class && rectNear(item.frame, view.frame)));
    }, { windowId: "w1", reactBlockerStep: 24 });
    const blockers = found.filter((v) => !v.control);
    if (blockers.length) throw new Error(`${blockers.length} RN views draw and handle nothing but catch the pointer: ${JSON.stringify(blockers.slice(0, 8))}`);
    return { controls: found.map((v) => ({ owner: v.owner, by: v.by })) };
  });

  const clickCheck = `${label}: a-click-on-the-page-lands-outside-the-main-root-and-focuses-it`;
  await rep.check(clickCheck, async () => {
    const pooled = await run(`return !!globalThis.expo.modules.SolaraTabPool?.available?.();`);
    if (!pooled) throw new Error("SolaraTabPool isn't available, so the pages are still RN's");
    await untilSnapshot("page pool available", (state) => state.poolAvailable === pooled, { windowId: "w1" });
    const [x, y] = shell.card;
    const slot = await run(`return W.devHitCost("w1", ${x + 200}, ${y + 300}).then((r) => r.slot);`);
    const r = await run(`return ac.shell.devClick("w1", { in: "page", x: 200, y: 300, wait: 250 });`);
    if (!WEB.test(String(r.hit))) throw new Error(`the click landed on ${r.hit}`);
    if (!WEB.test(String(r.firstResponderAfter))) throw new Error(`first responder after the click: ${r.firstResponderAfter}`);
    if (slot === "react") throw new Error(`the page is still under the main root (the pool hasn't taken it): ${r.hit} in the react slot`);
    await untilSnapshot("page hit and focus", (state) => {
      const native = state.windows.find((w) => w.id === "w1");
      return native?.hitSlot === slot && WEB.test(String(native.hitView)) && WEB.test(String(native.firstResponder));
    }, { windowId: "w1", hitPoint: [x + 200, y + 300] });
    return { ...r, slot };
  });

  await rep.check(`${label}: drops-on-the-page-reach-the-web-contents`, async () => {
    const win = await run(`return globalThis.expo.modules.SolaraCEF.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);`);
    const [x, y, w, h] = shell.card;
    const at = [Math.round(x + w / 2), Math.round(y + h * 0.6)];
    const seen = {};
    for (const type of TYPES) {
      const hit = JSON.parse(await run(`return globalThis.expo.modules.SolaraPages.devDropTarget(${win}, ${at[0]}, ${at[1]}, ${JSON.stringify(type)});`));
      if (!WEB.test(String(hit.view))) throw new Error(`${type} at ${at} taken by ${hit.chain?.join(" < ") ?? hit.view}`);
      seen[type] = hit.view;
    }
    await untilSnapshot("drop targets", (state) => {
      const targets = state.windows.find((w) => w.id === "w1")?.dropTargets;
      return targets?.length === TYPES.length && targets.every((target) => target.view === seen[target.type]);
    }, { windowId: "w1", dropTargets: TYPES.map((type) => ({ x: at[0], y: at[1], type })) });
    return seen;
  });
  await app.quit().catch(() => {});
  app = null;
}

try {
  await pass("native-column", { SOLARA_NATIVE_SIDEBAR: "1", SOLARA_NATIVE_TOP_STRIP: "1", SOLARA_NATIVE_PROFILE_PAGER: "1" });
  await pass("native-sidebar", { SOLARA_NATIVE_SIDEBAR: "1" });
  await pass("rn-sidebar", { SOLARA_NATIVE_SIDEBAR: "0" });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
const pending = rep.results.filter((r) => r.skipped).length;
const ran = rep.results.length - pending;
console.log(`${ran - failed.length}/${ran} passed${pending ? `, ${pending} pending` : ""}${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
