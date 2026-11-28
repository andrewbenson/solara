#!/usr/bin/env node
import assert from "node:assert/strict";
import { sidebarPosition, sidebarPositionSpecified, sidebarSession, assertSidebarPosition } from "./sidebar-position-test.mjs";
import { isDeepStrictEqual } from "node:util";
import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node shell-drop-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data] [--guest-only]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-shell-drop-"));
const rep = reporter(join(scratch, "shell-drop-test.log"), { name: "shell-drop-test" });
const TYPES = ["public.file-url", "public.url", "public.utf8-plain-text"];
const WEB = /RenderWidgetHostViewCocoa|WebContentsViewCocoa|SolaraCoreWebView/;
const PAGE = "data:text/html,<body style='height:2000px'>drop here</body>";

async function open(env, dir) {
  const app = await launch(resolve(appArg), { ...(sidebarPositionSpecified ? { session: session(sidebarSession({})) } : {}), data: join(scratch, dir), onboarded: true, env });
  let nativePollDeadline = 0;
  const read = (body) => {
    if (nativePollDeadline && nativePollDeadline - Date.now() < 1000) throw new Error("native comparison has less than 1000 ms remaining");
    return app.eval(body, { timeout: nativePollDeadline ? 1000 : 20000 });
  };
  await app.ready({ test: "return !!globalThis.expo?.modules?.SolaraPages?.devDropTarget" });
  await sleep(4000);
  await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; s.newTab(w, { url: ${JSON.stringify(PAGE)} }); return true`);
  await sleep(3000);
  const win = await app.eval(`const C = globalThis.expo.modules.SolaraCEF; return C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window)`);
  const info = JSON.parse(await app.eval(`const C = globalThis.expo.modules.SolaraCEF; return C.devWindow(${win}, "winfo")`));
  const [, , w, h] = info.frame.replace(/[{}]/g, "").split(",").map(Number);
  const tab = await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; return s.windows[w].activeTabIds[s.windows[w].profileId]`);
  const windowId = await app.eval(`return Object.keys(ac.store.getState().windows)[0]`);
  const untilSnapshot = async (what, args, accept, ms = 5000) => {
    const end = Date.now() + ms;
    let last;
    while (Date.now() < end) {
      if (!app.alive) throw new Error(`${what}: the owned app exited`);
      if (end - Date.now() < 1000) break;
      last = await app.snapshot({ windowId, ...args }, { timeout: 1000 }).catch((error) => ({ error: error.message }));
      nativePollDeadline = end;
      try {
        if (!last.error && last.consistent && Date.now() < end && await accept(last.windows.find((w) => w.id === windowId), last) && Date.now() < end) return last;
      } finally {
        nativePollDeadline = 0;
      }
      await sleep(100);
    }
    throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
  };
  if (env.SOLARA_NATIVE_SHELL !== "0") await assertSidebarPosition(app, windowId);
  await untilSnapshot("Chrome window and selected tab", {}, (window) =>
    window?.chromeWindowNumber === win && window.selectedTabId === tab &&
    Math.abs(window.frame.width - w) <= 0.5 && Math.abs(window.frame.height - h) <= 0.5);
  const target = async (x, y, type) => {
    let hit;
    await untilSnapshot("drop target", { dropTargets: [{ x, y, type }] }, async (window) => {
      hit = JSON.parse(await read(`return globalThis.expo.modules.SolaraPages.devDropTarget(${win}, ${x}, ${y}, ${JSON.stringify(type)})`));
      const native = window?.dropTargets?.[0];
      return native?.view === hit.view && isDeepStrictEqual(native.chain, hit.chain);
    });
    return hit;
  };
  const frameOf = async (needle) => {
    let frame;
    await untilSnapshot("view frame", { viewFrames: [needle] }, async (window) => {
      frame = JSON.parse(await read(`return globalThis.expo.modules.SolaraPages.devViewFrame(${win}, ${JSON.stringify(needle)})`));
      const native = window?.viewFrames?.[needle];
      return native?.found === frame.found && (!frame.found || ["x", "y", "width", "height"].every((key) => Math.abs(native[key] - frame[key]) <= 0.5));
    });
    return frame;
  };
  const zoom = (on) => app.eval(`ac.pageState.setState({ popover: expo.modules.SolaraSettings.setPanePopover(${JSON.stringify(tab)}, ${on ? '"zoom"' : "null"}) }); return true`);
  return { app, read, w, h, tab, win, windowId, target, frameOf, zoom, untilSnapshot };
}

if (args.includes("--guest-only")) {
  let guest;
  try {
    guest = await open({ SOLARA_NATIVE_SHELL: "0" }, "guest-data");
    await rep.check("the compatibility sidebar opens dropped URLs through its AppKit view", async () => {
      const host = JSON.parse(await guest.read(`return globalThis.expo.modules.SolaraPages.devViewFrame(${guest.win}, "FileDropView")`));
      assert.ok(host.found && host.width > 0, "the compatibility drop view is visible");
      const x = Math.round(host.x + host.width / 2);
      const y = Math.round(host.y + 30);
      const urls = ["http://127.0.0.1:1/first-drop", "http://127.0.0.1:1/second-drop"];
      const call = (action, payload) => guest.app.eval(
        `return ac.shell.devFileDrag.drag(${JSON.stringify(guest.windowId)}, ${JSON.stringify(action)}, ${x}, ${y}, ${JSON.stringify(payload)});`,
      );

      assert.match(await call("move", { urls }), /FileDropView [1-9]/);
      assert.equal(await call("cancel"), "cancelled");
      const cancelled = await guest.app.snapshot({ windowId: guest.windowId });
      assert.ok(cancelled.consistent && cancelled.tabs.every((tab) => !urls.includes(tab.url)));

      assert.match(await call("drop", { urls }), /FileDropView performed/);
      const state = await guest.untilSnapshot("dropped page order and selection", {}, (window, snapshot) => {
        const dropped = urls.map((url) => snapshot.tabs.find((tab) => tab.url === url));
        if (!window || dropped.some((tab) => !tab)) return false;
        const indices = dropped.map((tab) => window.tabIds.indexOf(tab.id));
        return window.selectedTabId === dropped[0].id && indices[0] >= 0 && indices[1] === indices[0] + 1;
      });
      return state.tabs.filter((tab) => urls.includes(tab.url)).map((tab) => tab.id);
    });
  } finally {
    await guest?.app.quit();
    if (!keep) rmSync(join(scratch, "guest-data"), { recursive: true, force: true });
  }
  process.exit(rep.summary() ? 0 : 1);
}

let shell = null;
let rn = null;
try {
  shell = await open({ SOLARA_NATIVE_SHELL: "1" }, "shell-data");
  const { w, h } = shell;
  let pageFrame = { x: 0, y: 0, width: w, height: h };
  const nativeLayout = await shell.read(`return globalThis.expo.modules.SolaraWindowShell.nativeLayout(${JSON.stringify(shell.windowId)});`);
  if (nativeLayout) await shell.untilSnapshot("actual native page endpoint", { fields: ["windows.shell"] }, async (window) => {
    const description = await shell.read(`return globalThis.expo.modules.SolaraWindowShell.describe(${JSON.stringify(shell.windowId)}).then(JSON.parse);`);
    const actual = description?.layout?.actual?.["page:" + shell.tab];
    const expected = description?.layout?.pages?.[shell.tab];
    if (!window?.shell?.card?.every((value, index) => Math.abs(value - description.card[index]) <= 0.5)) return false;
    if (!actual || !expected || actual[2] <= 0 || actual[3] <= 0) return false;
    assert.ok(actual.every((value, index) => Math.abs(value - expected[index]) <= 0.5), "the actual page endpoint matches its native allocation");
    pageFrame = { x: actual[0], y: actual[1], width: actual[2], height: actual[3] };
    return true;
  });
  const page = [Math.round(pageFrame.x + pageFrame.width * 0.6), Math.round(pageFrame.y + pageFrame.height * 0.6)];
  const pageGoesToWeb = async (label, at = page) => {
    for (const type of TYPES) {
      const hit = await shell.target(at[0], at[1], type);
      assert.match(String(hit.view), WEB, `${label}: ${type} taken by ${hit.chain?.join(" < ")}`);
    }
  };

  await rep.check("with the page alone, file, URL and text drops go to the web contents", () => pageGoesToWeb("alone"));

  let onPopover = null;
  const nativeOnPopover = {};
  await rep.check("with the zoom popover open, a drop beside it reaches the page", async () => {
    await shell.zoom(true);
    await sleep(800);
    const pop = await shell.frameOf("PopoverView");
    assert.ok(pop.found, "popover shown");
    onPopover = [Math.round(pop.x + pop.width / 2), Math.round(pop.y + Math.min(pop.height, 40) / 2)];
    await pageGoesToWeb("beside the popover", [Math.round(w * 0.4), Math.round(h * 0.75)]);
    for (const type of TYPES) nativeOnPopover[type] = WEB.test(String((await shell.target(onPopover[0], onPopover[1], type)).view));
    await shell.zoom(false);
    await sleep(400);
  });

  const windowId = shell.windowId;
  const card = async () => JSON.parse(await shell.read(`return globalThis.expo.modules.SolaraHosted.sidebarHoverCard(${JSON.stringify(windowId)})`));
  const region = (png, x, y, w, h) => execFileSync("ffmpeg", ["-v", "error", "-i", png, "-vf", `crop=${w}:${h}:${x}:${y}`, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], { maxBuffer: 64 << 20 });
  const pixel = (png, x, y) => [...region(png, x, y, 1, 1)];
  const snapshot = async (label) => {
    const png = join(scratch, `card-${label.replace(/\W+/g, "-")}.png`);
    assert.ok(await shell.app.eval(`return ac.shell.devSnapshotWindow(${JSON.stringify(windowId)}, ${JSON.stringify(png)})`), `${label}: window snapshot`);
    return png;
  };
  const near = (a, b, by) => Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((v, i) => Number.isFinite(v) && Number.isFinite(b[i]) && Math.abs(v - b[i]) <= by);
  let bare = null;
  const cardOnScreen = async (label) => {
    let c = await card();
    assert.equal(c?.kind, "tab", `${label}: the native tab card is mounted (${JSON.stringify(c)})`);
    assert.equal(c.phase, "shown", `${label}: phase`);
    assert.ok(c.opacity > 0.99 && Math.abs(c.scale - 1) < 0.001, `${label}: fully faded in (${c.opacity}, ${c.scale})`);
    assert.ok(c.onScreen && c.inWindow, `${label}: on screen inside the window`);
    await shell.untilSnapshot("hover card", {}, async (window) => {
      c = await card();
      const native = window?.hoverCard;
      return c?.kind === "tab" && c.phase === "shown" && c.opacity > 0.99 && Math.abs(c.scale - 1) < 0.001 && c.onScreen && c.inWindow && native?.kind === c.kind && native.phase === c.phase &&
        Math.abs(native.opacity - c.opacity) <= 0.01 && Math.abs(native.scale - c.scale) <= 0.01 &&
        native.frame?.every((value, index) => Math.abs(value - c.frame[index]) <= 0.5);
    });
    assert.ok((await shell.frameOf("SidebarTabCardView")).found, `${label}: the card view is in the window`);
    const at = [Math.round((c.frame[0] + 8) * 2), Math.round((c.frame[1] + 10) * 2)];
    const shot = await snapshot(label);
    const inside = pixel(shot, ...at);
    const fill = c.fill.match(/[0-9a-f]{2}/gi).slice(0, 3).map((h) => parseInt(h, 16));
    const rect = c.frame.map((v) => Math.round(v * 2));
    const [withCard, without] = [region(shot, ...rect), region(bare, ...rect)];
    let changed = 0;
    for (let i = 0; i < withCard.length; i += 3) if (!near([...withCard.subarray(i, i + 3)], [...without.subarray(i, i + 3)], 20)) changed++;
    const share = changed / (withCard.length / 3);
    rep.say(`${label}: card at ${c.frame.map(Math.round)}, pixel ${inside} (fill ${fill}), ${(share * 100).toFixed(1)}% of its pixels differ from the window without it`);
    if (!c.glass) assert.ok(near(inside, fill, 6), `${label}: the card's fill is drawn (${inside} vs ${fill})`);
    assert.ok(share > 0.02, `${label}: the card changes what the window shows (${(share * 100).toFixed(1)}% of its pixels)`);
    return c;
  };

  await rep.check("with the native hover card on screen, a drop on the page still reaches it", async () => {
    bare = await snapshot("without the card");
    const anchor = await shell.app.eval(`return globalThis.expo.modules.SolaraHosted.sidebarRowFrame(${JSON.stringify(windowId)}, "t:" + ${JSON.stringify(shell.tab)});`);
    assert.ok(anchor && anchor.width > 0, "the card anchor is an actual native sidebar row");
    await shell.app.eval(`const w = ${JSON.stringify(windowId)}; ac.pages.setSidebarUi({ hover: { windowId: w, kind: "tab", id: ${JSON.stringify(shell.tab)}, anchor: ${JSON.stringify(anchor)} } }); return true`);
    await sleep(800);
    const before = await cardOnScreen("before the drops");
    await pageGoesToWeb("with a hover card");
    const after = await cardOnScreen("after the drops");
    assert.deepEqual(after.frame, before.frame, "the card stayed put through the drops");
    await shell.app.eval(`ac.pages.setSidebarUi({ hover: null }); return true`);
    await sleep(400);
    assert.equal((await card())?.phase ?? "hidden", "hidden", "the card leaves once the hover clears");
    await shell.untilSnapshot("hover card hidden", {}, (window) =>
      !window?.hoverCard || window.hoverCard.phase === "hidden");
  });

  await rep.check("with two tabs in a split, a drop on either pane reaches the web contents", async () => {
    await shell.app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; const other = s.newTab(w, { url: "data:text/html,<body>right</body>" }); s.createSplit([${JSON.stringify(shell.tab)}, other]); return true`);
    await sleep(2000);
    assert.ok((await shell.frameOf("SplitChromeView")).found, "the native split chrome shown");
    await shell.untilSnapshot("split chrome", {}, (window) => window?.split != null);
    await pageGoesToWeb("left pane", [Math.round(pageFrame.x + pageFrame.width * 0.25), Math.round(h * 0.6)]);
    await pageGoesToWeb("right pane", [Math.round(pageFrame.x + pageFrame.width * 0.75), Math.round(h * 0.6)]);
  });
  if (sidebarPositionSpecified && sidebarPosition === "right") await rep.check("right sidebar and right extension panel keep separate native frames and page drop targets", async () => {
    await shell.app.eval(`const s = ac.store.getState(); for (const split of Object.values(s.splits)) s.separateSplit(split.id); return true;`);
    await shell.untilSnapshot("one page before extension coexistence", {}, async (window) => {
      const layout = await shell.read(`return globalThis.expo.modules.SolaraWindowShell.describe(${JSON.stringify(windowId)}).then(JSON.parse).then((shell) => shell.layout);`);
      return layout && Object.keys(layout.panes).length === 1 && Object.keys(window?.split?.leaves ?? {}).length === 0;
    });
    const ext = join(scratch, "side-panel-extension");
    cpSync(resolve(import.meta.dirname, "../../../packages/solaracore/scripts/fixtures/ext"), ext, { recursive: true });
    const manifest = JSON.parse(readFileSync(join(ext, "manifest.json"), "utf8"));
    delete manifest.content_scripts;
    delete manifest.declarative_net_request;
    manifest.name = "Right sidebar drop fixture";
    manifest.permissions = ["sidePanel"];
    writeFileSync(join(ext, "manifest.json"), JSON.stringify(manifest));
    writeFileSync(join(ext, "panel.html"), "<!doctype html><title>Right panel</title><body>Right panel</body>");
    const extension = await shell.app.eval(`return globalThis.expo.modules.SolaraExtensions.install(${JSON.stringify(ext)}, "");`);
    assert.ok(extension?.id, "the scratch extension installs");
    await shell.app.eval(`return ac.extensions.refreshExtensions("").then(() => expo.modules.SolaraToolbar.devSidePanel(${JSON.stringify(windowId)}, "open", ${JSON.stringify(extension.id)}));`);
    try {
      let frames;
      await shell.untilSnapshot("right sidebar beside the extension panel", { fields: ["windows.sidePanel", "windows.shell", "windows.sidebarShell"] }, async (window) => {
        const panel = window?.sidePanel?.card?.frame;
        const column = window?.sidebarShell?.frame;
        const page = window?.shell?.card;
        if (!panel || !column || !page || window.sidePanel.moving) return false;
        assert.ok(panel[2] > 0 && page[2] > 0 && column[2] > 0, "all three native allocations have usable width");
        assert.ok(panel[0] + panel[2] <= column[0] + 0.5, `the right panel stays inward from the sidebar: ${JSON.stringify({ panel, column })}`);
        assert.ok(page[0] + page[2] <= panel[0] + 0.5, `the page stays inward from the panel: ${JSON.stringify({ panel, page })}`);
        frames = { panel, column, page };
        return true;
      });
      const leftPagePoint = [Math.round(frames.page[0] + frames.page[2] / 3), Math.round(frames.page[1] + frames.page[3] / 2)];
      await pageGoesToWeb("with the right sidebar and extension panel", leftPagePoint);
      const panelTargets = async () => {
        const response = await fetch(`http://127.0.0.1:${shell.app.port}/json/list`, { signal: AbortSignal.timeout(1000) });
        return (await response.json()).filter((target) => target.url.startsWith(`chrome-extension://${extension.id}/panel.html`)).map(({ id, url }) => ({ id, url }));
      };
      let identity;
      for (const end = Date.now() + 5000; end - Date.now() >= 1000; await sleep(100)) {
        identity = await panelTargets();
        if (identity.length === 1) break;
      }
      assert.equal(identity?.length, 1, "the real extension panel has one Chromium target");
      await shell.app.eval(`const s = ac.store.getState(); if (s.windows[${JSON.stringify(windowId)}].sidebarOpen) s.toggleSidebar(${JSON.stringify(windowId)}); return true;`);
      await shell.untilSnapshot("right sidebar hidden beside the extension panel", { fields: ["windows.sidePanel"] }, async (window) => {
        const state = await shell.read(`return globalThis.expo.modules.SolaraWindowShell.describe(${JSON.stringify(windowId)}).then(JSON.parse);`);
        return state?.sidebarDock?.dock === 0 && !state.sidebarDock.moving && !state.sidebarDock.live && !!window?.sidePanel?.card;
      });
      await shell.app.eval(`return ac.shell.devLeftEdgePointer(${JSON.stringify(windowId)}, { x: ${w + 4}, y: 300 }).then(() => new Promise((resolve) => setTimeout(resolve, 250))).then(() => ac.shell.devLeftEdgePointer(${JSON.stringify(windowId)}, { x: ${w - 3}, y: 300 }));`);
      let peek;
      await shell.untilSnapshot("right peek overlaps the extension panel", { fields: ["windows.sidePanel", "windows.sidebarShell"] }, async (window) => {
        const state = await shell.read(`return globalThis.expo.modules.SolaraWindowShell.describe(${JSON.stringify(windowId)}).then(JSON.parse);`);
        const coverage = state?.sidebarDock?.coverage;
        const panel = window?.sidePanel?.card?.frame;
        if (!state?.sidebarDock?.live || state.sidebarDock.moving || Math.abs(state.sidebarDock.slide - 1) > 0.001 || !coverage || !panel) return false;
        const overlaps = coverage[0] < panel[0] + panel[2] && panel[0] < coverage[0] + coverage[2] && coverage[1] < panel[1] + panel[3] && panel[1] < coverage[1] + coverage[3];
        assert.ok(overlaps, `the actual right peek covers part of the extension panel: ${JSON.stringify({ coverage, panel })}`);
        peek = { coverage, panel };
        return true;
      });
      const peekRow = await shell.read(`return globalThis.expo.modules.SolaraHosted.sidebarRowFrame(${JSON.stringify(windowId)}, "t:" + ${JSON.stringify(shell.tab)});`);
      assert.ok(peekRow?.width > 0 && peekRow.height > 0, "the actual peeking sidebar row has a visible frame");
      const rowPoint = [Math.round(peekRow.x + peekRow.width / 2), Math.round(peekRow.y + peekRow.height / 2)];
      assert.ok(rowPoint[0] >= peek.coverage[0] && rowPoint[0] < peek.coverage[0] + peek.coverage[2] && rowPoint[1] >= peek.coverage[1] && rowPoint[1] < peek.coverage[1] + peek.coverage[3], "the real row pointer lies in native peek coverage");
      await shell.app.eval(`return ac.shell.devLeftEdgePointer(${JSON.stringify(windowId)}, { x: ${rowPoint[0]}, y: ${rowPoint[1]} });`);
      for (const type of TYPES) {
        const hit = await shell.target(rowPoint[0], rowPoint[1], type);
        assert.match(String(hit.view), /SidebarShellColumn/, `the right peek takes ${type} above the page and extension panel: ${JSON.stringify(hit)}`);
      }
      await pageGoesToWeb("left page while the right peek covers the extension panel", leftPagePoint);
      await shell.app.eval(`return ac.shell.devLeftEdgePointer(${JSON.stringify(windowId)}, { x: ${leftPagePoint[0]}, y: ${leftPagePoint[1]} });`);
      await shell.untilSnapshot("dismissing the right peek keeps the extension panel", { fields: ["windows.sidePanel"] }, async (window) => {
        const state = await shell.read(`return globalThis.expo.modules.SolaraWindowShell.describe(${JSON.stringify(windowId)}).then(JSON.parse);`);
        return !state?.sidebarDock?.live && !state?.sidebarDock?.coverage && !!window?.sidePanel?.card && window.sidePanel.pages.some((page) => page.extensionId === extension.id && page.visible);
      });
      assert.deepEqual(await panelTargets(), identity, "dismissing the peek keeps the same extension-panel Chromium target");
      return { ...frames, peek, rowPoint, panelIdentity: identity };
    } finally {
      await shell.app.eval(`return ac.shell.devLeftEdgePointer(${JSON.stringify(windowId)}, null);`).catch(() => {});
      await shell.app.eval(`return expo.modules.SolaraToolbar.devSidePanel(${JSON.stringify(windowId)}, "close", null);`);
    }
  });
  await shell.app.quit();
  shell = null;

  await rep.check("a drop on the zoom popover goes where RN's does", async () => {
    assert.ok(onPopover, "the shell's popover point");
    rn = await open({ SOLARA_NATIVE_SHELL: "0" }, "rn-data");
    await rn.zoom(true);
    await sleep(800);
    const rnOnPopover = {};
    for (const type of TYPES) rnOnPopover[type] = WEB.test(String((await rn.target(onPopover[0], onPopover[1], type)).view));
    rep.say(`on the popover, to the page? RN ${JSON.stringify(rnOnPopover)}, shell ${JSON.stringify(nativeOnPopover)}`);
    assert.deepEqual(nativeOnPopover, rnOnPopover);
  });
} finally {
  await shell?.app.quit();
  await rn?.app.quit();
  if (!keep) for (const dir of ["shell-data", "rn-data"]) rmSync(join(scratch, dir), { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);
