import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const baseline = args.includes("--baseline");
const [appArg, outputArg] = args.filter((a) => !a.startsWith("--"));
assert.ok(appArg && outputArg, `usage: node apps/browser/scripts/native-find-commands-test.mjs <Debug app> <fresh output directory> [--baseline]

The find commands decided in Swift, with the JavaScript command handlers turned off: ⌘F then typing at once, ⌘F again,
⌘G and ⇧⌘G, ⌘E, find and replace, Escape, a find claim that expires, a background window, Little Solara and a Peek.
--baseline runs the same presses on a build where JavaScript still decides them and records what happens.`);
const appPath = resolve(appArg);
const output = resolve(outputArg);
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim(), "network.benson.solara.dev");
mkdirSync(output, { recursive: true });
const evidence = [];
const observed = {};
const server = createServer((req, res) => {
  const path = new URL(req.url, "http://x").pathname;
  res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
  res.end(`<!doctype html><title>Page ${path}</title><link rel="icon" href="data:,"><body><p id="w">needle</p><p>needle haystack needle</p><input id="f"></body>`);
});
let app;
let handlerBaseline;
const run = (body, timeout = 4000) => app.eval(body, { timeout });
const nativeState = async () => (await run(`
  const module = expo.modules.SolaraStoreAdapter;
  const status = module.status();
  if (!status.active || status.frozen !== false) throw new Error("native workspace ownership required");
  return JSON.parse(module.snapshot());
`)).data;
const menu = (windowId, command) =>
  run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand(${JSON.stringify(windowId)}, ${JSON.stringify(command)}, null);`);
const keys = {
  f: { key: "f", keyCode: 3, modifiers: ["command"] },
  g: { key: "g", keyCode: 5, modifiers: ["command"] },
  G: { key: "G", keyCode: 5, modifiers: ["command", "shift"] },
  e: { key: "e", keyCode: 14, modifiers: ["command"] },
  j: { key: "j", keyCode: 38, modifiers: ["command"] },
  l: { key: "l", keyCode: 37, modifiers: ["command"] },
  escape: { key: "\u001b", keyCode: 53, modifiers: [] },
};
const letterCodes = { a: 0, b: 11, c: 8, x: 7, n: 45, e: 14, d: 2, l: 37 };
const letter = (ch) => ({ key: ch, keyCode: letterCodes[ch], modifiers: [] });
const press = (windowId, keyPress, extra = {}) =>
  run(`return ac.shell.devKeyEquivalent(${JSON.stringify(windowId)}, ${JSON.stringify({ ...keyPress, send: true, asKey: true, wait: 250, ...extra })});`);
const responder = async (windowId) =>
  (await run(`return ac.shell.devKeyEquivalent(${JSON.stringify(windowId)}, { key: "\\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 });`)).firstResponder;
const typeAtOnce = async (windowId, first, text, wait = 700) => {
  if (first.focus) await run(`return ac.shell.devKeyEquivalent(${JSON.stringify(windowId)}, { key: "\\u0000", keyCode: 0, modifiers: [], focus: ${JSON.stringify(first.focus)}, dry: true, wait: 50 });`);
  const presses = [{ key: first.key, keyCode: first.keyCode, modifiers: first.modifiers, after: 0 }, ...[...text].map((ch) => ({ ...letter(ch), after: 0 }))];
  const before = await responder(windowId);
  await run(`return expo.modules.SolaraApp.devPostKeys(${JSON.stringify(windowId)}, ${JSON.stringify(presses)});`);
  await sleep(wait);
  return { firstResponder: before, firstResponderAfter: await responder(windowId) };
};
const pageEval = (tabId, expression) =>
  run(`return ac.webviews.get(${JSON.stringify(tabId)}).evaluate(${JSON.stringify(`post("result", JSON.stringify(${expression}))`)});`);
const focusTrace = async () => (await run("return expo.modules.SolaraApp.devFocusHandoffTrace();")).filter((line) => /hold|adopt|release|late begin|begin|claim|replay|drop/.test(line)).slice(-12);
const focusTimes = async () => {
  if (baseline) return null;
  const seam = await run("return expo.modules.SolaraSettings.devPageCommands();");
  return { delaysMs: seam.findFocusDelays, expiries: seam.findFocusExpiries };
};
const find = (s, id) => s.find?.[id] ?? {};
const isField = (name) => /TextView|TextField/.test(name);
const isPage = (name) => /RenderWidgetHostViewCocoa/.test(name);

async function until(label, accept, ms = 8000) {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() + 500 < deadline) {
    assert.ok(app.alive, `${label}: owned instance exited`);
    last = await nativeState();
    if (await accept(last)) return last;
    await sleep(50);
  }
  evidence.push({ label, failed: true, find: last?.find });
  writeFileSync(join(output, "evidence.json"), JSON.stringify({ evidence, observed }, null, 2));
  throw new Error(`${label}: deadline exceeded`);
}

async function typed(label, key, mustKeep = !baseline) {
  try {
    await until(label, (s) => find(s, "a").open && find(s, "a").query === "needle", 4000);
    return true;
  } catch (error) {
    if (mustKeep) {
      observed[key] = { lost: true, find: find(await nativeState(), "a"), times: await focusTimes(), responder: await responder("w1") };
      writeFileSync(join(output, "evidence.json"), JSON.stringify({ evidence, observed }, null, 2));
      console.log(`OBSERVED ${label} failed: ${JSON.stringify(observed[key])}`);
      throw error;
    }
    observed[key] = { lost: true, find: find(await nativeState(), "a"), times: await focusTimes() };
    console.log(`OBSERVED baseline ${label}: ${JSON.stringify(observed[key])}`);
    return false;
  }
}

async function handledNatively(label) {
  if (baseline) return;
  await sleep(200);
  const stats = await run("return ac.commandHandlers.stats();");
  assert.equal(stats.enabled, false, `${label}: JS handlers unexpectedly enabled`);
  assert.equal(stats.calls, handlerBaseline.calls, `${label}: JS handler made a decision`);
  assert.equal(stats.blocked, handlerBaseline.blocked, `${label}: command fell through to disabled JS`);
}

function pass(label, details = {}) {
  evidence.push({ label, ...details });
  writeFileSync(join(output, "evidence.json"), JSON.stringify({ evidence, observed }, null, 2));
  console.log(`PASS ${label}`);
}

async function closeFind(windowId, tabId, viaEscape = true) {
  if (viaEscape) {
    await press(windowId, keys.escape, { wait: 200 });
    return until(`${tabId}'s find closes`, (s) => !find(s, tabId).open);
  }
  await run(`ac.store.getState().setFind(${JSON.stringify(tabId)}, { open: false, count: null, active: 0 }); return true;`);
  return until(`${tabId}'s find closes`, (s) => !find(s, tabId).open);
}

async function jumpSelection(windowId, tabId, via = "menu") {
  await closeFind(windowId, tabId, false);
  await pageEval(tabId, `(() => {
    const target = document.getElementById("jump-target") ?? document.body.appendChild(document.createElement("p"));
    target.id = "jump-target"; target.textContent = "jump needle";
    target.style.cssText = "margin-top:2400px;margin-bottom:2400px";
    document.activeElement?.blur();
    const range = document.createRange(); range.selectNodeContents(target);
    getSelection().removeAllRanges(); getSelection().addRange(range);
    scrollTo(0, 0); return true;
  })()`);
  const selected = await pageEval(tabId, "String(getSelection())");
  const visible = () => pageEval(tabId, `(() => {
    const rect = getSelection().getRangeAt(0).getBoundingClientRect();
    return rect.top >= 0 && rect.bottom <= innerHeight;
  })()`);
  assert.equal(await visible(), false, "the selection starts offscreen");
  if (via === "⌘J") await press(windowId, keys.j, { focus: "page" });
  else if (via === "bridge") await run(`ac.runCommand({ command: "jumpToSelection", windowId: ${JSON.stringify(windowId)}, arg: null }); return true;`);
  else await menu(windowId, "jumpToSelection");
  await until("Jump reveals the selection", async () => await visible() === true, 4000);
  assert.equal(await pageEval(tabId, "String(getSelection())"), selected, "Jump preserves the selection");
  await handledNatively("Jump to Selection");
  pass(`Jump to Selection in ${windowId}: ${via}`, { tabId });
}

try {
  await new Promise((done, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", done); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const other = `http://localhost:${server.address().port}`;
  app = await launch(appPath, {
    data: join(output, "data"), fresh: true, onboarded: true, probe: true, keepData: true,
    env: { SOLARA_NATIVE_WINDOW_LAYOUT: process.env.SOLARA_NATIVE_WINDOW_LAYOUT ?? "1" },
    session: session({
      windows: [
        { id: "w1", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } },
        { id: "w2", frame: [140, 140, 900, 700], activeTabIds: { default: "d" } },
      ],
      tabs: [
        { id: "a", url: `${base}/a`, title: "A", windowId: "w1" },
        { id: "b", url: `${other}/b`, title: "B", windowId: "w1" },
        { id: "d", url: `${base}/d`, title: "D", windowId: "w2" },
      ],
      settings: { sleepInactiveTabs: false, warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false },
    }),
    ready: "return !!ac.commandHandlers && !!ac.shell.devKeyEquivalent && !!expo.modules.SolaraApp.devWorkspaceMenuCommand && !!ac.store.getState().windows.w1 && !!ac.store.getState().windows.w2;",
  });
  const probe = await menu("w1", "noSuchCommand");
  assert.equal(probe?.debug, true, "devWorkspaceMenuCommand did nothing: this driver needs a Debug build");
  await until("both pages loaded", (s) => s.tabs.a?.title === "Page /a" && s.tabs.d?.title === "Page /d", 20000);
  await sleep(500);
  handlerBaseline = await run(baseline
    ? "return ac.commandHandlers.stats();"
    : "const b = ac.commandHandlers.stats(); ac.commandHandlers.setEnabled(false); return b;");

  await press("w1", { key: "\u0000", keyCode: 0, modifiers: [] }, { focus: "page", send: false, dry: true, wait: 50 });
  const first = await typeAtOnce("w1", { ...keys.f, focus: "page" }, "needle");
  if (!await typed("⌘F then typing at once: every letter lands in the find field", "coldTyping")) {
    await run('ac.store.getState().setFind("a", { query: "needle" }); return true;');
  }
  assert.ok(isField(await responder("w1")), "the find field is first responder");
  await handledNatively("⌘F then typing");
  observed.coldTrace = baseline ? null : await focusTrace();
  if (!baseline) assert.ok(observed.coldTrace.some((line) => /adopt 6 after \d+ ms/.test(line)), `the six letters were held and handed to the find field: ${JSON.stringify(observed.coldTrace)}`);
  pass("⌘F then typing at once: every letter lands in the find field", { responderAfter: first.firstResponderAfter, trace: observed.coldTrace });
  observed.coldFind = await focusTimes();

  await closeFind("w1", "a");
  await press("w1", { key: "\u0000", keyCode: 0, modifiers: [] }, { focus: "page", send: false, dry: true, wait: 50 });
  await run(`return ac.shell.devKeyEquivalent("w1", { key: "\\u0000", keyCode: 0, modifiers: [], focus: "page", dry: true, wait: 50 });`);
  await run(`return expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify([{ ...keys.f, after: 0 }, { ...keys.f, after: 0 }, ...[..."needle"].map((ch) => ({ ...letter(ch), after: 0 }))])});`);
  if (!await typed("a double ⌘F then typing: every letter lands in the find field", "doubleTyping")) {
    await run('ac.store.getState().setFind("a", { query: "needle" }); return true;');
  }
  assert.ok(isField(await responder("w1")), "the find field is first responder after a double ⌘F");
  await handledNatively("double ⌘F then typing");
  pass("a double ⌘F then typing: every letter lands in the find field");
  observed.doubleFind = await focusTimes();

  await until("the page reports its matches", (s) => (find(s, "a").count ?? 0) >= 3);
  const active = find(await nativeState(), "a").active;
  await press("w1", keys.g, { focus: "page" });
  await until("⌘G steps to the next match", (s) => find(s, "a").active !== active);
  await handledNatively("⌘G");
  pass("⌘G steps to the next match");
  await press("w1", keys.G, { focus: "page" });
  await until("⇧⌘G steps back", (s) => find(s, "a").active === active);
  await handledNatively("⇧⌘G");
  pass("⇧⌘G steps back");

  const again = await press("w1", { ...keys.f, focus: "page" }, { wait: 500 });
  assert.ok(isField(await responder("w1")), "⌘F again focuses the find field");
  assert.equal(find(await nativeState(), "a").query, "needle", "⌘F again keeps the text");
  await press("w1", letter("x"), { asKey: true, wait: 200 });
  await until("⌘F again selects the text, so typing replaces it", (s) => find(s, "a").query === "x");
  await handledNatively("⌘F again");
  pass("⌘F again re-selects the field and keeps its text", { responderAfter: again.firstResponderAfter });

  await closeFind("w1", "a");
  assert.ok(isPage(await responder("w1")), "Escape gives the page its focus back");
  pass("Escape closes find and the page takes focus again");

  if (!baseline) {
    await pageEval("a", `(() => { window.__keys = []; window.__ownFind = (e) => { if (e.metaKey && (e.key === "f" || e.key === "l")) e.preventDefault(); window.__keys.push(e.key); }; document.addEventListener("keydown", window.__ownFind, true); return true; })()`);
    await typeAtOnce("w1", { ...keys.f, focus: "page" }, "needle", 900);
    const keysSeen = await pageEval("a", "window.__keys");
    const seen = typeof keysSeen === "string" ? JSON.parse(keysSeen) : keysSeen;
    const ownTrace = await focusTrace();
    observed.pageOwnFind = { seen, trace: ownTrace };
    const from = seen.indexOf("f");
    assert.deepEqual(from < 0 ? seen : seen.slice(from, from + 7), ["f", ..."needle"], `a page that takes ⌘F itself gets every letter, in order: ${JSON.stringify(observed.pageOwnFind)}`);
    assert.equal(find(await nativeState(), "a").open, false, "a page that takes ⌘F itself keeps Solara's find closed");
    assert.ok(isPage(await responder("w1")), "a page that takes ⌘F itself keeps its focus");
    assert.ok(ownTrace.some((line) => /release 6 to the page \(cap\) after \d+ ms/.test(line)), `the held letters went back to the page at the cap: ${JSON.stringify(ownTrace)}`);
    pass("a page that takes ⌘F itself gets every letter, in order, after the hold's cap", observed.pageOwnFind);

    await run("ac.commandHandlers.setEnabled(true); return true;");
    const rawTrace = async () => run("return expo.modules.SolaraApp.devFocusHandoffTrace();");
    const traceBefore = (await rawTrace()).at(-1);
    await pageEval("a", `(() => { window.__keys = []; return true; })()`);
    await run(`return expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify([{ ...keys.f, after: 0 }, { ...letter("a"), after: 0 }, { ...keys.l, after: 0 }, { ...letter("b"), after: 0 }, { ...letter("c"), after: 250 }, { ...letter("d"), after: 30 }])});`);
    await sleep(900);
    const replaySeen = await pageEval("a", "window.__keys");
    const traceAfter = await rawTrace();
    const releaseTrace = traceAfter.slice(traceBefore == null ? 0 : traceAfter.indexOf(traceBefore) + 1)
      .filter((line) => /hold|adopt|release|drop|commandBar/.test(line));
    observed.releaseOrder = { seen: replaySeen, trace: releaseTrace };
    console.log(`OBSERVED a held ⌘L re-sent at the cap: ${JSON.stringify(observed.releaseOrder)}`);
    const released = releaseTrace.findIndex((line) => /release \d+ to the page/.test(line));
    assert.ok(released >= 0, `the held keys went back to the page: ${JSON.stringify(observed.releaseOrder)}`);
    assert.ok(!releaseTrace.slice(released + 1).some((line) => /hold for/.test(line)), `re-sending the held ⌘L opens no second hold: ${JSON.stringify(releaseTrace)}`);
    const fieldAfter = await responder("w1");
    observed.releaseOrder.responder = fieldAfter;
    assert.ok(replaySeen.includes("a"), `the letter before the released ⌘L reaches the page: ${JSON.stringify(replaySeen)}`);
    assert.ok(releaseTrace.some((line) => /commandBar .* claim DeveloperUrlField/.test(line)) && isField(fieldAfter), `the released ⌘L focuses the developer URL field of this 127.0.0.1 page, as it did before: ${fieldAfter} ${JSON.stringify(releaseTrace)}`);
    assert.ok(!replaySeen.includes("c") && !replaySeen.includes("d"), `later letters stay out of the page: ${JSON.stringify(replaySeen)}`);
    await press("w1", keys.escape, { wait: 150 });
    await press("w1", keys.escape, { wait: 150 });
    if (find(await nativeState(), "a").open) await closeFind("w1", "a", isField(await responder("w1")));
    handlerBaseline = await run("ac.commandHandlers.setEnabled(false); return ac.commandHandlers.stats();");
    pass("held keys re-sent at the cap, including a held ⌘L, open no second hold and keep their order", observed.releaseOrder);

    await run('ac.store.getState().activate("b"); return true;');
    await until("tab b is loaded for the switch leg", (s) => s.windows.w1.activeTabIds[s.windows.w1.profileId] === "b" && s.tabs.b?.title === "Page /b");
    await sleep(300);
    await pageEval("b", `(() => { window.__keys = []; document.addEventListener("keydown", (e) => window.__keys.push(e.key), true); return true; })()`);
    await run('ac.store.getState().activate("a"); return true;');
    await until("tab a is active for the switch leg", (s) => s.windows.w1.activeTabIds[s.windows.w1.profileId] === "a");
    await sleep(400);
    await run(`return ac.shell.devKeyEquivalent("w1", { key: "\\u0000", keyCode: 0, modifiers: [], focus: "page", dry: true, wait: 50 });`);
    await pageEval("a", `(() => { window.__keys = []; return true; })()`);
    await run(`expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify([{ ...keys.f, after: 0 }, { ...letter("n"), after: 0 }, { ...letter("e"), after: 0 }])}); setTimeout(() => ac.store.getState().activate("b"), 30); return true;`);
    await sleep(900);
    const onB = await pageEval("b", "window.__keys");
    const onA = await pageEval("a", "window.__keys");
    observed.switchDuringHold = { onA, onB, trace: (await focusTrace()).slice(-4) };
    console.log(`OBSERVED a tab switch during the hold: ${JSON.stringify(observed.switchDuringHold)}`);
    await run('ac.store.getState().activate("a"); return true;');
    await until("tab a is active again after the switch leg", (s) => s.windows.w1.activeTabIds[s.windows.w1.profileId] === "a");
    await sleep(300);
    assert.deepEqual(onB.filter((k) => k === "n" || k === "e"), [], `keys typed for tab a never reach tab b: ${JSON.stringify(observed.switchDuringHold)}`);
    pass("keys held for one tab never reach another tab that took its place during the hold", observed.switchDuringHold);
    await run(`return ac.shell.devKeyEquivalent("w1", { key: "\\u0000", keyCode: 0, modifiers: [], focus: "page", dry: true, wait: 50 });`);
    await pageEval("a", `(() => { window.__events = []; window.__ownUps = (e) => window.__events.push(e.type + ":" + e.key); document.addEventListener("keydown", window.__ownUps, true); document.addEventListener("keyup", window.__ownUps, true); return true; })()`);
    await run(`return expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify([{ ...keys.f, after: 0 }, { ...letter("a"), phase: "down", after: 0 }, { ...letter("b"), phase: "down", after: 0 }, { ...letter("a"), phase: "up", after: 0 }, { ...letter("b"), phase: "up", after: 0 }])});`);
    await sleep(700);
    const overlap = (await pageEval("a", "window.__events")).filter((e) => !e.endsWith(":f") && !e.endsWith(":Meta"));
    await pageEval("a", `(() => { document.removeEventListener("keydown", window.__ownUps, true); document.removeEventListener("keyup", window.__ownUps, true); return true; })()`);
    observed.overlap = overlap;
    console.log(`OBSERVED overlapping keys held and released: ${JSON.stringify(overlap)}`);
    assert.deepEqual(overlap.slice(0, 4), ["keydown:a", "keydown:b", "keyup:a", "keyup:b"], `overlapping presses keep their down and up order: ${JSON.stringify(overlap)}`);
    pass("overlapping presses held for a page that keeps ⌘F keep their down and up order", { overlap });

    await pageEval("a", `(() => { document.removeEventListener("keydown", window.__ownFind, true); return true; })()`);

    await pageEval("a", `(() => { setTimeout(() => { const t = performance.now(); while (performance.now() - t < 300) {} }, 0); return true; })()`);
    await sleep(20);
    await typeAtOnce("w1", { ...keys.f, focus: "page" }, "needle", 1200);
    const busyTrace = await focusTrace();
    const busyFind = find(await nativeState(), "a");
    observed.busyPage = { trace: busyTrace, find: busyFind };
    console.log(`OBSERVED ⌘F while the page is busy for 300 ms: ${JSON.stringify(observed.busyPage)}`);
    assert.ok(busyTrace.some((line) => /adopt 6 after \d+ ms|late begin \d+ ms, 6 already released/.test(line)), `a busy page either has the letters adopted or the late command logged: ${JSON.stringify(busyTrace)}`);
    pass("⌘F while the page is busy: the letters are adopted, or the late command is logged", observed.busyPage);
    if (busyFind.open) await closeFind("w1", "a", isField(await responder("w1")));
  }

  await pageEval("a", `(() => { const r = document.createRange(); r.selectNodeContents(document.getElementById("w")); getSelection().removeAllRanges(); getSelection().addRange(r); return true; })()`);
  await press("w1", keys.e, { focus: "page" });
  await until("⌘E with a selection makes it the query", (s) => find(s, "a").open && find(s, "a").query === "needle");
  await handledNatively("⌘E");
  pass("⌘E with a selection makes it the query");
  await closeFind("w1", "a");
  await pageEval("a", `(() => { getSelection().removeAllRanges(); return true; })()`);
  const beforeEmpty = find(await nativeState(), "a");
  await press("w1", keys.e, { focus: "page" });
  await sleep(600);
  assert.deepEqual(find(await nativeState(), "a"), beforeEmpty, "⌘E without a selection changes nothing");
  await handledNatively("⌘E empty");
  pass("⌘E without a selection changes nothing");

  await jumpSelection("w1", "a", "⌘J");
  await jumpSelection("w1", "a");
  await jumpSelection("w1", "a", "bridge");
  await pageEval("a", `(() => { getSelection().removeAllRanges(); scrollTo(0, 0); return true; })()`);
  await menu("w1", "jumpToSelection");
  assert.equal(await pageEval("a", "scrollY"), 0, "Jump without a selection keeps the scroll position");
  await handledNatively("Jump without a selection");
  pass("Jump without a selection does nothing");
  await pageEval("a", `(() => { document.getElementById("jump-target").remove(); return true; })()`);

  await menu("w1", "findAndReplace");
  await until("findAndReplace opens the replace row", (s) => find(s, "a").open && find(s, "a").replace === true);
  await handledNatively("findAndReplace");
  pass("findAndReplace opens the replace row");
  await closeFind("w1", "a");

  await run('ac.store.getState().activate("b"); return true;');
  await until("tab b is active", (s) => s.windows.w1.activeTabIds[s.windows.w1.profileId] === "b");
  await sleep(400);
  await press("w1", keys.g, { focus: "page" });
  await until("⌘G with no query opens the bar", (s) => find(s, "b").open === true && !find(s, "b").query);
  await handledNatively("⌘G no query");
  pass("⌘G with no query only opens the bar");
  await closeFind("w1", "b");

  if (!baseline) await run("ac.commandHandlers.setEnabled(true); return true;");
  await press("w1", { ...keys.l, focus: "page" }, { wait: 400 });
  await press("w1", letter("a"), { asKey: true, wait: 50 });
  await press("w1", letter("b"), { asKey: true, wait: 50 });
  const editing = await responder("w1");
  const midTyping = await typeAtOnce("w1", keys.f, "c", 500);
  await sleep(400);
  const afterOmnibox = await nativeState();
  observed.omniboxThenFind = { editing, before: midTyping.firstResponder, after: midTyping.firstResponderAfter, later: await responder("w1"), find: find(afterOmnibox, "b") };
  console.log(`OBSERVED ⌘F while the address field is edited: ${JSON.stringify(observed.omniboxThenFind)}`);
  await press("w1", keys.escape, { wait: 150 });
  await press("w1", keys.escape, { wait: 150 });
  if (!baseline) handlerBaseline = await run("ac.commandHandlers.setEnabled(false); return ac.commandHandlers.stats();");
  await run('ac.store.getState().activate("a"); return true;');
  await until("tab a is active again", (s) => s.windows.w1.activeTabIds[s.windows.w1.profileId] === "a");
  await sleep(500);
  if (find(await nativeState(), "a").open) await closeFind("w1", "a");

  await press("w1", { key: "\u0000", keyCode: 0, modifiers: [] }, { focus: "page", send: false, dry: true, wait: 50 });
  await run(`
    ac.shell.devKeyEquivalent("w1", ${JSON.stringify({ ...keys.f, focus: "page", send: true, asKey: true, wait: 1400 })});
    const t = Date.now(); while (Date.now() - t < 900) {}
    return true;
  `, 6000);
  await until("a late find bar still opens", (s) => find(s, "a").open === true);
  await sleep(1500);
  const late = await responder("w1");
  observed.expiredClaim = { later: late, times: await focusTimes() };
  if (!baseline) assert.ok(observed.expiredClaim.times.expiries >= 1, "the stalled find bar's claim was logged as expired");
  if (!baseline) assert.ok(!isField(late), `an expired claim never moves focus later (first responder ${late})`);
  await handledNatively("expired claim");
  pass("an expired claim never moves focus later", { responder: late });
  await closeFind("w1", "a", isField(late));

  await run(`return ac.shell.devKeyEquivalent("w1", { key: "\\u0000", keyCode: 0, modifiers: [], focus: "page", dry: true, wait: 50 });`);
  await run(`
    expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify([{ ...keys.f, after: 0 }])});
    ac.shell.devClick("w1", { in: "page", x: 200, y: 200, queued: true, asKey: true, wait: 600 });
    const t = Date.now(); while (Date.now() - t < 280) {}
    return true;
  `, 6000);
  await until("the find bar opens after a click ended the focus gate", (s) => find(s, "a").open === true);
  await sleep(1200);
  const clickedAway = await responder("w1");
  observed.gateEndedByClick = { later: clickedAway, times: await focusTimes() };
  if (!baseline) assert.ok(!isField(clickedAway), `a click that ends the focus gate keeps focus where the click put it (first responder ${clickedAway})`);
  await handledNatively("gate ended by a click");
  pass("a find request never outlives its focus gate: a click before the bar opens keeps the page focused", { responder: clickedAway });
  await closeFind("w1", "a", isField(clickedAway));

  const keyBefore = await responder("w1");
  await menu("w2", "findInPage");
  await until("the background window's find opens", (s) => find(s, "d").open === true);
  await sleep(600);
  assert.equal(await responder("w1"), keyBefore, "the front window's focus is untouched by a background window's ⌘F");
  await handledNatively("background window");
  pass("a background window's ⌘F never takes the front window's focus");

  const small = await run(`return ac.store.getState().createWindow({ url: ${JSON.stringify(`${other}/c`)}, small: true });`);
  await until("Little Solara window", (s) => s.windows[small]?.kind === "small");
  const smallTab = (s) => s.windows[small].activeTabIds[s.windows[small].profileId];
  await until("Little Solara's page loaded", (s) => s.tabs[smallTab(s)]?.title === "Page /c", 15000);
  await menu(small, "findInPage");
  await until("Little Solara finds in its own page", (s) => find(s, smallTab(s)).open === true && !find(s, "a").open);
  await handledNatively("Little Solara");
  pass("Little Solara finds in its own page");

  await run(`ac.store.getState().openPeek("a", ${JSON.stringify(`${other}/peek`)}); return true;`);
  const peeked = await until("a Peek opens", (s) => !!s.peeks?.w1?.tabId && s.tabs[s.peeks.w1.tabId]?.title === "Page /peek", 15000);
  const peekTab = peeked.peeks.w1.tabId;
  await menu("w1", "findInPage");
  await until("the Peek takes the find", (s) => find(s, peekTab).open === true && !find(s, "a").open);
  await handledNatively("Peek");
  pass("a Peek takes the window's find");

  const sourceScroll = await pageEval("a", "scrollY");
  await jumpSelection("w1", peekTab);
  assert.equal(await pageEval("a", "scrollY"), sourceScroll, "a Peek Jump leaves the underlying page alone");
  await jumpSelection(small, smallTab(await nativeState()));
  await jumpSelection("w2", "d");

  writeFileSync(join(output, "result.json"), JSON.stringify({ passed: true, baseline, checks: evidence.map((e) => e.label), observed }, null, 2));
  console.log(`${evidence.length}/${evidence.length} passed${baseline ? " (baseline)" : ""}`);
} finally {
  if (app) await app.quit();
  server.closeAllConnections();
  await new Promise((done) => server.listening ? server.close(done) : done());
}
