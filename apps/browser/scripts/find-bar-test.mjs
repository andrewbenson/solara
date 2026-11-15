import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, extname, join, resolve, sep } from "node:path";
import { frontApp, launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const [appArg, outArg] = args.filter((arg) => !arg.startsWith("--"));
const baseline = args.includes("--baseline");
const bundleArg = args.find((arg) => arg.startsWith("--bundle="))?.slice("--bundle=".length);
const frozenBundle = bundleArg ? readFileSync(resolve(bundleArg)) : null;
const assetRoot = bundleArg ? resolve(dirname(bundleArg), "assets") : null;
if (!appArg || !outArg || args.some((arg) => arg.startsWith("--") && arg !== "--baseline" && !arg.startsWith("--bundle="))) {
  console.error("usage: node find-bar-test.mjs <Debug Solara.app> <new output directory> [--baseline] [--bundle=<frozen index.bundle>]");
  process.exit(2);
}
const out = resolve(outArg);
assert.equal(existsSync(out), false, `output directory already exists: ${out}`);
mkdirSync(out, { recursive: true });
const rep = reporter(join(out, "find-bar-test.log"), { name: "find-bar-test" });
const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
  if (frozenBundle && path === "/status") {
    res.writeHead(200, { "content-type": "text/plain" });
    return res.end("packager-status:running");
  }
  if (frozenBundle && path === "/index.bundle") {
    res.writeHead(200, { "content-type": "application/javascript" });
    return res.end(frozenBundle);
  }
  if (path.startsWith("/assets/")) {
    if (assetRoot) {
      const file = resolve(assetRoot, path.slice(1));
      if (file.startsWith(assetRoot + sep)) {
        try {
          if (statSync(file).isFile()) {
            res.writeHead(200, { "content-type": extname(file) === ".png" ? "image/png" : "application/octet-stream" });
            return res.end(readFileSync(file));
          }
        } catch {}
      }
    }
    res.writeHead(404);
    return res.end();
  }
  res.writeHead(200, { "content-type": "text/html" });
  res.end("<!doctype html><title>FIND FIXTURE</title><body style='margin:32px;background:white;color:black;font:16px sans-serif'><p>needle needle needle</p><input aria-label='Editable fixture'></body>");
});
server.on("upgrade", (req, socket) => socket.destroy());
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("a") }, { id: "b", url: url("b") }],
  settings: { appearance: "light", searchSuggestions: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, shortcutPrecedence: { findInPage: "solara", findNext: "solara", findPrevious: "solara" } },
});
const helpers = `
const S = () => ac.store.getState();
const bars = (id) => acPerf.findFibers("FindBarPanel", 50).filter((f) => f.memoizedProps.tabId === id && f.child);
const descendants = (root) => { const out = []; const visit = (f) => { if (!f) return; out.push(f); visit(f.child); visit(f.sibling); }; visit(root.child); return out; };
const rendering = (id) => bars(id).map((bar) => { const nodes = descendants(bar); const native = nodes.find((f) => typeof f.memoizedProps?.onFindEvent === "function"); return { native: !!native, state: native ? JSON.parse(native.memoizedProps.state) : null, rnFields: nodes.filter((f) => typeof f.memoizedProps?.onChangeText === "function").length }; });
const measure = (id) => new Promise((done) => { let node = bars(id)[0]?.child; while (node && typeof node.stateNode?.measureInWindow !== "function") node = node.child; if (!node) return done(null); node.stateNode.measureInWindow((x,y,w,h) => done([x,y,w,h])); });
`;
const evidence = { baseline, app: resolve(appArg), viewport: [1280, 800], findCrop: [340, 40], littleViewport: [900, 640], input: "AppKit devKeyEquivalent send:true and devClick; no simulated native find events", foregroundBefore: frontApp(), bundle: frozenBundle ? { path: resolve(bundleArg), sha256: createHash("sha256").update(frozenBundle).digest("hex"), bytes: frozenBundle.length, assets: existsSync(assetRoot) ? assetRoot : null } : null, legs: [] };
let instance = null;
const run = (body, timeout = 5000) => instance.eval(helpers + body, { timeout });
const until = async (label, body, timeout = 10000) => {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    last = await run(body);
    if (last) return last;
    await sleep(100);
  }
  throw new Error(`${label}: timed out (${JSON.stringify(last)})`);
};
const press = async (windowId, key, keyCode, modifiers = [], extra = {}) => {
  if (modifiers.includes("shift") && /^[a-z]$/.test(key)) key = key.toUpperCase();
  const result = await run(`return ac.shell.devKeyEquivalent(${JSON.stringify(windowId)}, ${JSON.stringify({ key, keyCode, modifiers, asKey: true, send: true, wait: 150, ...extra })});`);
  assert.equal(result.error, undefined, JSON.stringify(result));
  return result;
};
const state = (tabId) => run(`return S().find[${JSON.stringify(tabId)}] ?? null;`);
const findStep = async (windowId, tabId, key, code, modifiers, step) => {
  const before = await state(tabId);
  assert.equal(before.count, 3);
  await press(windowId, key, code, modifiers);
  const expected = ((before.active - 1 + step + 3) % 3) + 1;
  return until("match step", `const f = S().find[${JSON.stringify(tabId)}]; return f?.active === ${expected} && f.count === 3 ? f : null;`);
};
const capture = async (leg, label, windowId, tabId, height = 40) => {
  await sleep(250);
  const path = join(out, `${leg}-${label}.png`);
  const frame = await run(`return measure(${JSON.stringify(tabId)});`);
  assert.ok(frame && Math.abs(frame[2] - 340) <= 0.5 && frame[3] >= height - 0.5 && frame[3] <= height + 1.5, JSON.stringify(frame));
  assert.equal(await run(`return ac.shell.devSnapshotWindow(${JSON.stringify(windowId)}, ${JSON.stringify(path)});`, 15000), true);
  const png = readFileSync(path);
  assert.equal(png.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  const size = [png.readUInt32BE(16), png.readUInt32BE(20)];
  const width = await run(`return S().windows[${JSON.stringify(windowId)}].frame[2];`);
  const scale = size[0] / width;
  assert.ok(scale === 1 || scale === 2, JSON.stringify({ size, scale }));
  const crop = [Math.round(frame[0] * scale), Math.round(frame[1] * scale), 340 * scale, height * scale];
  assert.ok(crop[0] >= 0 && crop[1] >= 0 && crop[0] + crop[2] <= size[0] && crop[1] + crop[3] <= size[1], JSON.stringify({ crop, size }));
  const cropped = join(out, `${leg}-${label}-find.png`);
  execFileSync("/usr/bin/sips", ["--cropToHeightWidth", String(crop[3]), String(crop[2]), "--cropOffset", String(crop[1]), String(crop[0]), path, "--out", cropped], { timeout: 20000, stdio: "pipe" });
  const croppedPng = readFileSync(cropped);
  assert.deepEqual([croppedPng.readUInt32BE(16), croppedPng.readUInt32BE(20)], crop.slice(2));
  return { path, cropped, findFrame: frame, crop, scale };
};
const type = async (windowId, text) => {
  const codes = { a: 0, e: 14, i: 34, l: 37, n: 45, d: 2, x: 7, z: 6 };
  for (const key of text) await press(windowId, key, codes[key] ?? 0);
};
const query = async (windowId, tabId, text, count) => {
  await press(windowId, "a", 0, ["command"]);
  if (text) await type(windowId, text);
  else await press(windowId, "\u007f", 51);
  return until("query result", `const f = S().find[${JSON.stringify(tabId)}]; return f?.query === ${JSON.stringify(text)} && f.count === ${JSON.stringify(count)} ? f : null;`);
};
const clickInFind = async (windowId, tabId, x, y) => {
  const frame = await run(`return measure(${JSON.stringify(tabId)});`);
  assert.ok(frame, "find frame");
  const clicked = await run(`return ac.shell.devClick(${JSON.stringify(windowId)}, { x: ${frame[0] + x}, y: ${frame[1] + y}, asKey: true, wait: 100 });`);
  assert.equal(clicked.error, undefined, JSON.stringify(clicked));
  return clicked;
};
const pageEval = (tabId, expression) => run(`return ac.webviews.get(${JSON.stringify(tabId)}).evaluate(${JSON.stringify(`post("result", JSON.stringify(${expression}))`)});`);
const clickEditable = async () => {
  const bounds = await pageEval("a", '(() => { const r = document.querySelector("input").getBoundingClientRect(); return [r.x + 3, r.y + r.height / 2]; })()');
  const clicked = await run(`return ac.shell.devClick("w1", { in: "page", x: ${bounds[0]}, y: ${bounds[1]}, asKey: true, wait: 100 });`);
  assert.equal(clicked.error, undefined, JSON.stringify(clicked));
  assert.equal(await pageEval("a", 'document.activeElement.tagName'), "INPUT");
  return clicked;
};
const pageValue = async (tabId, expected) => {
  const end = Date.now() + 5000;
  let value;
  while (Date.now() < end) {
    value = await pageEval(tabId, 'document.querySelector("input").value');
    if (value === expected) return value;
    await sleep(100);
  }
  assert.equal(value, expected);
};
const exerciseReplacement = async (leg) => {
  await rep.check(`${leg}/replace-noneditable-note`, async () => {
    await pageEval("a", '(document.activeElement.blur(), true)');
    await press("w1", "f", 3, ["command", "option"]);
    await until("replace mounted", 'return S().find.a?.replace && bars("a").length ? true : null;');
    await query("w1", "a", "needle", 3);
    await clickInFind("w1", "a", 70, 60);
    await type("w1", "x");
    await clickInFind("w1", "a", 270, 60);
    const shown = await until("noneditable replacement note", 'const r = rendering("a")[0]; const text = bars("a").flatMap(descendants).flatMap((f) => typeof f.memoizedProps?.children === "string" ? [f.memoizedProps.children] : []); return r?.state?.note === "Not in a text field" || text.includes("Not in a text field") ? { r, text } : null;');
    return { shown, capture: await capture(leg, "main-replace-noneditable", "w1", "a", 79) };
  });
  await press("w1", "\u001b", 53);
  await rep.check(`${leg}/replace-one-all-and-undo`, async () => {
    const boundary = [];
    const sample = async (phase) => {
      const value = { phase, page: await pageEval("a", '({ tag: document.activeElement.tagName, value: document.querySelector("input").value, start: document.querySelector("input").selectionStart, end: document.querySelector("input").selectionEnd })'), find: await state("a") };
      boundary.push(value);
      rep.log("replacement boundary", value);
    };
    await pageEval("a", '(() => { document.querySelector("p").textContent = "Editable fixture"; const input = document.querySelector("input"); input.value = "needle needle"; input.focus(); input.setSelectionRange(0,0); return input.value; })()');
    await sample("input-focused");
    await press("w1", "f", 3, ["command", "option"]);
    await until("replace mounted", 'return S().find.a?.replace && bars("a").length ? true : null;');
    await sample("find-replace-focused");
    await press("w1", "a", 0, ["command"]);
    await type("w1", "needle");
    await until("replace query", 'return S().find.a?.query === "needle" ? S().find.a : null;');
    await sample("query-typed");
    await clickInFind("w1", "a", 70, 60);
    await sample("replacement-field-focused");
    await press("w1", "a", 0, ["command"]);
    await type("w1", "x");
    await sample("replacement-typed");
    await clickEditable();
    await sample("page-input-clicked");
    rep.log("editable replacement target", await pageEval("a", '({ tag: document.activeElement.tagName, value: document.querySelector("input").value, start: document.querySelector("input").selectionStart, end: document.querySelector("input").selectionEnd })'));
    await clickInFind("w1", "a", 270, 60);
    const one = await pageValue("a", "x needle");
    assert.equal(one, "x needle");
    const oneCapture = await capture(leg, "main-replace-one", "w1", "a", 79);
    await clickEditable();
    await clickInFind("w1", "a", 319, 60);
    const all = await pageValue("a", "x x");
    assert.equal(all, "x x");
    const allCapture = await capture(leg, "main-replace-all", "w1", "a", 79);
    await clickInFind("w1", "a", 320, 20);
    await clickEditable();
    await press("w1", "z", 6, ["command"]);
    const undo = await pageValue("a", "x needle");
    assert.equal(undo, "x needle");
    await press("w1", "z", 6, ["command"]);
    const undoOne = await pageValue("a", "needle needle");
    assert.equal(undoOne, "needle needle");
    return { one, all, undo, undoOne, oneCapture, allCapture, boundary };
  });
  await press("w1", "\u001b", 53);
  await pageEval("a", '(document.querySelector("p").textContent = "needle needle needle", document.querySelector("input").value = "", document.querySelector("input").blur(), true)');
};
const exercise = async (leg, label, windowId, tabId) => {
  await rep.check(`${leg}/${label}/command-f-and-native-only`, async () => {
    await run(`const web = ac.webviews.get(${JSON.stringify(tabId)}); if (!web) throw new Error("missing fixture page"); return web.focus();`);
    const result = await press(windowId, "f", 3, ["command"]);
    await until("find opened", `return S().find[${JSON.stringify(tabId)}]?.open ? true : null;`);
    const rows = await until("find mounted", `const r = rendering(${JSON.stringify(tabId)}); return r.length ? r : null;`);
    assert.equal(rows.length, 1, JSON.stringify(rows));
    if (!baseline) {
      assert.equal(rows[0].native, true, JSON.stringify(rows));
      assert.equal(rows[0].rnFields, 0, JSON.stringify(rows));
    }
    const focused = await until("find field focus", `return ac.shell.devKeyEquivalent(${JSON.stringify(windowId)}, { key: "\\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 }).then((r) => /TextView|TextField/.test(r.firstResponder) ? r : null);`);
    return { result, focused, rows };
  });
  await rep.check(`${leg}/${label}/typing-and-match-count`, async () => {
    await query(windowId, tabId, "needle", 3);
    const found = await until("three matches", `const f = S().find[${JSON.stringify(tabId)}]; return f?.query === "needle" && f.count === 3 && f.active >= 1 ? f : null;`);
    const rows = await run(`return rendering(${JSON.stringify(tabId)});`);
    if (!baseline || rows[0]?.native) {
      assert.equal(rows[0]?.state.count, 3);
      assert.equal(rows[0]?.state.active, found.active);
    }
    return found;
  });
  for (const [name, key, code, modifiers, step] of [
    ["command-g", "g", 5, ["command"], 1],
    ["shift-command-g", "g", 5, ["command", "shift"], -1],
    ["return", "\r", 36, [], 1],
    ["shift-return", "\r", 36, ["shift"], -1],
  ]) await rep.check(`${leg}/${label}/${name}`, () => findStep(windowId, tabId, key, code, modifiers, step));
  await rep.check(`${leg}/${label}/capture`, () => capture(leg, label, windowId, tabId));
  if (label === "main") {
    await rep.check(`${leg}/repeated-command-f-selects-query`, async () => {
      await press(windowId, "f", 3, ["command"]);
      await type(windowId, "x");
      const selected = await until("repeated find selected query", `const f = S().find[${JSON.stringify(tabId)}]; return f?.query === "x" ? f : null;`);
      await query(windowId, tabId, "needle", 3);
      return selected;
    });
    for (const appearance of ["light", "dark"]) {
      await run(`S().updateSettings({ appearance: ${JSON.stringify(appearance)} }); return true;`);
      await rep.check(`${leg}/${appearance}/count`, async () => {
        await query(windowId, tabId, "needle", 3);
        await until("appearance", `const r = rendering(${JSON.stringify(tabId)})[0]; return !r?.native || r.state.dark === ${appearance === "dark"} ? true : null;`);
        return capture(leg, `main-${appearance}-count`, windowId, tabId);
      });
      await rep.check(`${leg}/${appearance}/no-results`, async () => {
        await query(windowId, tabId, "zzzz", 0);
        return capture(leg, `main-${appearance}-none`, windowId, tabId);
      });
    }
    await run('S().updateSettings({ appearance: "light" }); return true;');
    await query(windowId, tabId, "needle", 3);
  }
  await rep.check(`${leg}/${label}/escape-returns-page-focus`, async () => {
    const result = await press(windowId, "\u001b", 53);
    await until("find closed", `return S().find[${JSON.stringify(tabId)}]?.open === false && bars(${JSON.stringify(tabId)}).length === 0 ? true : null;`);
    const focused = await until("page focus after close", `return ac.shell.devKeyEquivalent(${JSON.stringify(windowId)}, { key: "\\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 }).then((r) => /RenderWidgetHostViewCocoa/.test(r.firstResponder) ? r : null);`);
    return { result, focused };
  });
};
try {
  for (const [leg, env] of [
    ["pooled", { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_TAB_POOL: "1" }],
    ["legacy", { SOLARA_NATIVE_SHELL: "0", SOLARA_NATIVE_PAGES_POOL: "0", SOLARA_SHELL_PANES: "0", SOLARA_TAB_POOL: "0" }],
  ]) {
    try {
      instance = await launch(resolve(appArg), { ...(frozenBundle ? { js: `127.0.0.1:${server.address().port}` } : {}), data: join(out, leg, "data"), fresh: true, session: fixture, onboarded: true, probe: true, env, ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acPerf && !!ac.shell.devKeyEquivalent" });
      await until("fixture page", "return S().tabs.a?.title === 'FIND FIXTURE' ? true : null;", 15000);
      evidence.legs.push({ leg, pid: instance.pid, toolbarAvailable: await run("return globalThis.expo.modules.SolaraToolbar.available();") });
      await exercise(leg, "main", "w1", "a");
      await exerciseReplacement(leg);
      for (const modifiers of [["command"], ["command", "shift"]]) {
        const target = await run(`const id = S().newTab("w1", { url: ${JSON.stringify(url("empty-find"))} }); S().closePanel("w1"); return id;`);
        await until("empty-query fixture", `return S().tabs[${JSON.stringify(target)}]?.title === "FIND FIXTURE" ? true : null;`, 15000);
        await rep.check(`${leg}/empty-query-${modifiers.join("-")}-g-focuses`, async () => {
          await run(`return ac.webviews.get(${JSON.stringify(target)}).focus();`);
          assert.equal(await state(target), null);
          await press("w1", "g", 5, modifiers);
          await until("empty find opened", `return S().find[${JSON.stringify(target)}]?.open ? true : null;`);
          await type("w1", "x");
          return until("empty find accepts typing", `const f = S().find[${JSON.stringify(target)}]; return f?.query === "x" ? f : null;`);
        });
        await run(`S().closeTab(${JSON.stringify(target)}); S().activate("a"); return true;`);
      }
      await rep.check(`${leg}/immediate-find-close`, async () => {
        await press("w1", "f", 3, ["command"], { wait: 0 });
        const result = await press("w1", "\u001b", 53, [], { wait: 0 });
        await sleep(400);
        assert.equal((await state("a")).open, false);
        const focused = await run('return ac.shell.devKeyEquivalent("w1", { key: "\\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 });');
        assert.match(focused.firstResponder, /RenderWidgetHostViewCocoa/);
        return { result, focused };
      });
      await run('S().createSplit(["a", "b"]); S().activate("b"); return true;');
      await until("split fixture", "return S().tabs.b?.title === 'FIND FIXTURE' ? true : null;", 15000);
      await exercise(leg, "split-b", "w1", "b");
      await run('S().activate("a"); return true;');
      await exercise(leg, "split-a", "w1", "a");
      await run('for (const id of Object.keys(S().splits)) S().separateSplit(id); S().activate("a"); return true;');
      if (leg === "legacy") {
        const peek = await run(`return S().openPeek("a", ${JSON.stringify(url("peek"))});`);
        await until("peek fixture", `return S().tabs[${JSON.stringify(peek)}]?.title === 'FIND FIXTURE' ? true : null;`, 15000);
        await exercise(leg, "peek", "w1", peek);
        await run('ac.peek.dismissPeek("w1"); return true;');
        await until("peek closed", 'return !S().peeks.w1 ? true : null;');
      } else {
        rep.log("Native pooled Peek has no FindBar mount before this migration; find presentation there is outside this driver.");
      }
      const before = await run('return ac.shell.devKeyEquivalent("w1", { key: "\\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 });');
      await run('ac.runCommand({ command: "newLittleSolara", windowId: "w1" }); return true;');
      const little = await until("Little Solara", 'const w = Object.values(S().windows).find((w) => w.kind === "small"); return w?.tabIds.length ? { window: w.id, tab: w.tabIds[0] } : null;');
      await run(`S().closePanel(${JSON.stringify(little.window)}); S().setWindowFrame(${JSON.stringify(little.window)}, [80,80,900,640]); S().navigate(${JSON.stringify(little.tab)}, ${JSON.stringify(url("little"))}, { userInitiated: true }); return true;`);
      await until("Little fixture", `return S().tabs[${JSON.stringify(little.tab)}]?.title === 'FIND FIXTURE' ? true : null;`, 15000);
      await exercise(leg, "little", little.window, little.tab);
      await rep.check(`${leg}/little-keeps-main-responder-class`, async () => {
        const after = await run('return ac.shell.devKeyEquivalent("w1", { key: "\\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 });');
        assert.equal(after.firstResponder, before.firstResponder);
        return { before, after };
      });
    } finally {
      if (instance) await instance.quit();
      instance = null;
    }
  }
} catch (error) {
  rep.record("driver", { error });
} finally {
  if (instance) await instance.quit();
  await new Promise((done) => server.close(done));
  evidence.foregroundAfter = frontApp();
  rep.record("foreground-app-preserved", { evidence: { before: evidence.foregroundBefore, after: evidence.foregroundAfter }, error: evidence.legs.some((entry) => entry.pid === evidence.foregroundAfter?.pid) ? new Error("test instance became foreground") : null });
  writeFileSync(join(out, "result.json"), JSON.stringify({ ...evidence, checks: rep.results }, null, 2) + "\n");
}
process.exitCode = rep.summary() ? 0 : 1;
