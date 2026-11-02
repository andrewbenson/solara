import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error("usage: node onboarding-test.mjs <Debug Solara.app> [--port=<DevTools port>] [--keep-data]\n\nNo text field sits behind the onboarding card, where its I-beam and clicks would come through the rows, the first row's checkbox toggles on a click, another window keeps its New Tab field meanwhile, and the New Tab field is back and focused once onboarding ends, in a bar that keeps its height.");
  process.exit(2);
}
const appPath = resolve(appArg);
const product = execFileSync("plutil", ["-extract", "CFBundleName", "raw", join(appPath, "Contents/Info.plist")], { encoding: "utf8" }).trim();
const defaultBrowserRow = `Set ${product} as default browser`;
const defaultBrowserAx = new RegExp(`AXCheckBox: ${defaultBrowserRow}`);
const port = args.find((a) => a.startsWith("--port="))?.slice(7);
const keep = args.includes("--keep-data");
const extraEnv = Object.fromEntries(args.filter((a) => a.startsWith("--env=")).map((a) => a.slice(6).split("=")));
const overlay = {};
const scratch = mkdtempSync(join(tmpdir(), "ac-onboarding-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "onboarding-test.log"), { name: "onboarding-test" });

let app = null;
const metroPort = Number(process.env.METRO_PORT ?? 8081);
const warmBundle = async (ms = 300000) => {
  const started = Date.now();
  const url = `http://localhost:${metroPort}/index.bundle?platform=macos&dev=true&minify=false`;
  const response = await fetch(url, { signal: AbortSignal.timeout(ms) }).catch((error) => {
    throw new Error(`Metro on :${metroPort} didn't build the bundle within ${ms / 1000} s: ${error.message}`);
  });
  if (!response.ok) throw new Error(`Metro on :${metroPort} answered ${response.status} for the bundle`);
  await response.arrayBuffer();
  return Date.now() - started;
};
const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const act = (a) => C.chromeWindows().then((ws) => C.devWindow(ws.find((w) => w.hasRoot).window, a));
const hook = globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__;
const roots = () => [...hook.renderers.keys()].flatMap((id) => [...hook.getFiberRoots(id)].map((r) => r.current));
const nameOf = (f) => (typeof f.type === "string" ? f.type : f.type?.displayName || f.type?.name || "");
const find = (from, test) => {
  const stack = [from];
  while (stack.length) {
    const f = stack.pop();
    if (test(f)) return f;
    for (let c = f.child; c; c = c.sibling) stack.push(c);
  }
  return null;
};
const checkRow = (label) => roots().map((r) => find(r, (f) => f.memoizedProps?.accessibilityRole === "checkbox" && f.memoizedProps?.accessibilityLabel === label)).find(Boolean);
const checked = (label) => !!checkRow(label)?.memoizedProps.accessibilityState?.checked;
const checkMarkCenter = (label) => new Promise((r) => {
  const mark = find(find(checkRow(label), (f) => nameOf(f) === "CheckMark"), (f) => typeof f.stateNode?.measureInWindow === "function");
  mark.stateNode.measureInWindow((x, y, w, h) => r([Math.round(x + w / 2), Math.round(y + h / 2)]));
});
const windowsAx = () => C.chromeWindows().then((ws) => Promise.all(ws.filter((w) => w.hasRoot).map((w) => C.devWindow(w.window, "ax"))));
const barHeight = () => new Promise((r) => {
  const ntp = roots().map((root) => find(root, (f) => nameOf(f) === "NewTabPage")).find(Boolean);
  const bar = find(ntp, (f) => f.memoizedProps?.onLayout && f.memoizedProps?.style?.position === "absolute" && typeof f.stateNode?.measureInWindow === "function");
  bar.stateNode.measureInWindow((x, y, w, h) => r(h));
});
const click = ([x, y]) => act("mouse:down:" + x + "," + y).then(() => settle(70)).then(() => act("mouse:up:" + x + "," + y));
const S = globalThis.expo.modules.SolaraSettings;
const nativeOverlay = () => (S.devOnboarding ? S.devOnboarding("state").then((t) => JSON.parse(t).active === true) : Promise.resolve(false));
const findNative = (label) => S.devOnboarding("find", label).then((t) => JSON.parse(t));
const goStep = (step) => nativeOverlay().then((n) => (n ? S.devOnboarding("go", step + ":0") : acOnboarding.store.getState().go(step)));
const isChecked = (label) => nativeOverlay().then((n) => (n ? findNative(label).then((e) => e.value === "1") : checked(label)));
const isDisabled = (label) => nativeOverlay().then((n) => (n ? findNative(label).then((e) => e.enabled === false) : !!checkRow(label)?.memoizedProps.accessibilityState?.disabled));
const toggleAt = (label) => nativeOverlay().then((n) => (n ? findNative(label).then((e) => [Math.round(e.frame[0] + e.frame[2] - 24), Math.round(e.frame[1] + e.frame[3] / 2)]) : checkMarkCenter(label)));
const finish = () => nativeOverlay().then((n) => (n ? S.devOnboarding("finish") : acOnboarding.finish()));
const nativeNewTab = () => !!globalThis.expo.modules.SolaraNewTab?.available?.();
const focusOf = (number) => C.devWindow(number, "type:");
const rootWindow = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
`;
const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 20000 });
const textFields = (ax) => ax.split("\n").filter((line) => line.trim().startsWith("AXTextField"));
const isField = (responder) => /NSTextView|NSTextField|FieldEditor|TextField/.test(responder);
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

try {
  rep.log(`bundle: built by Metro on :${metroPort} in ${await warmBundle()} ms`);
  app = await launch(appPath, { data, port, env: { SOLARA_ONBOARDING: "1", ...overlay, ...extraEnv } });
  rep.log(`instance: pid ${app.pid}, DevTools port ${app.port}, data ${data}`);
  await app.ready({ test: "const S = globalThis.expo?.modules?.SolaraSettings; return S?.devOnboarding ? S.devOnboarding(\"state\").then((t) => JSON.parse(t).active === true) : false" }).catch(async (error) => {
    const state = await run("return S.devOnboarding ? S.devOnboarding(\"state\") : \"no devOnboarding\";").catch((e) => e.message);
    const lines = readFileSync(app.log, "utf8").split("\n").filter((line) => /onboarding|appIntegration|bundle/i.test(line)).slice(-12);
    throw new Error(`${error.message}\nonboarding state: ${state}\n${lines.join("\n")}`);
  });
  rep.log(`overlay: ${(await run("return nativeOverlay();")) ? "native" : "RN"}`);

  const native = await run("return nativeOverlay();");
  const newTab = await run("return nativeNewTab();");
  rep.log(`New Tab page: ${newTab ? "native" : "RN"}`);
  await untilSnapshot("New Tab availability", (snapshot) => snapshot.newTabAvailable === newTab);

  await rep.check("the home step has no text field behind its card", async () => {
    const r = await run(`return goStep("home").then(() => settle(1200)).then(() => Promise.all([act("ax"), act("type:"), nativeOverlay().then((n) => (n ? S.devOnboarding("state").then(JSON.parse) : null))]))`);
    const [ax, responder, state] = r;
    if (native) {
      assert.equal(state.step, "home", "the step is on screen");
      await untilSnapshot("onboarding home", (snapshot) => snapshot.onboarding.state.step === state.step &&
        snapshot.onboarding.state.active === state.active && snapshot.onboarding.defaultBrowserRow.found === true);
    }
    else assert.match(ax, defaultBrowserAx, "the step is on screen");
    if (newTab) assert.ok(!isField(responder), `a text field behind the card takes the first row's keys and clicks: ${responder}`);
    else assert.deepEqual(textFields(ax), [], "a text field behind the card takes the first row's cursor and clicks");
    await untilSnapshot("home accessibility text fields", (snapshot) =>
      snapshot.windows.some((window) => window.textFieldCount === textFields(ax).length), { textFields: true });
    return responder;
  });

  const label = JSON.stringify(defaultBrowserRow);
  const toggles = "a click on the first row's checkbox toggles it";
  const disabled = await run(`return isDisabled(${label});`);
  if (native) await untilSnapshot("default browser checkbox enabled", (snapshot) =>
    snapshot.onboarding.defaultBrowserRow.enabled === !disabled);
  if (disabled)
    rep.record(toggles, { skip: "this build is the system's default browser, so the row is disabled" });
  else await rep.check(toggles, async () => {
    const r = await run(`let before; return isChecked(${label}).then((b) => { before = b; return act("fakeActiveClicks"); }).then(() => toggleAt(${label})).then((at) => click(at).then((hit) => settle(400).then(() => isChecked(${label})).then((after) => ({ at, hit, before, after }))));`);
    assert.notEqual(r.after, r.before, `the click at ${r.at} reached ${r.hit}`);
    if (native) await untilSnapshot("default browser checkbox toggled", (snapshot) =>
      snapshot.onboarding.defaultBrowserRow.value === (r.after ? "1" : "0"));
    return `${r.before} -> ${r.after}`;
  });

  await rep.check("another window keeps its New Tab field during onboarding", async () => {
    const r = await run(`return rootWindow().then((first) => { const id = ac.store.getState().createWindow(); return settle(1500).then(() => C.chromeWindows()).then((ws) => { const other = ws.find((w) => w.hasRoot && w.window !== first)?.window; return Promise.all([windowsAx(), focusOf(first), other ? focusOf(other) : "", C.devWindow(first, "ax"), other ? C.devWindow(other, "ax") : ""]); }).then((out) => [...out, id]); })`);
    const [axes, onboardingFocus, otherFocus, onboardingAx, otherAx, otherId] = r;
    try {
      assert.equal(axes.length, 2, "two windows");
      if (newTab) {
        assert.ok(!isField(onboardingFocus), `the onboarding window: ${onboardingFocus}`);
        assert.ok(isField(otherFocus), `the other window's New Tab field: ${otherFocus}`);
      } else {
        const [onboarding, other] = defaultBrowserAx.test(axes[0]) ? axes : [...axes].reverse();
        assert.deepEqual(textFields(onboarding), [], "the onboarding window");
        assert.equal(textFields(other).length, 1, "the other window's New Tab field");
      }

      await untilSnapshot("onboarding window accessibility text fields", (snapshot) =>
        snapshot.windows.some((window) => window.id === otherId && window.textFieldCount === textFields(otherAx).length) &&
        snapshot.windows.some((window) => window.id !== otherId && window.textFieldCount === textFields(onboardingAx).length), { textFields: true });
      await untilSnapshot("onboarding keeps another window focused", (snapshot) =>
        snapshot.windows.some((w) => w.id === otherId && isField(w.firstResponder) === isField(otherFocus)) &&
        snapshot.windows.some((w) => w.id !== otherId && isField(w.firstResponder) === isField(onboardingFocus)));
      return otherFocus;
    } finally {
      await run(`ac.store.getState().closeWindow(${JSON.stringify(otherId)}); return settle(500);`);
    }
  });

  await rep.check("after onboarding the New Tab field is back and focused, in a bar of the same height", async () => {
    if (newTab) {
      const r = await run(`return finish().then(() => settle(1500)).then(() => act("type:"))`);
      assert.ok(isField(r), `first responder: ${r}`);
      await untilSnapshot("New Tab focus after onboarding", (snapshot) =>
        snapshot.onboarding.state.active === false && snapshot.windows.some((w) => isField(w.firstResponder)));
      return `${r} (the native bar's height isn't measured here)`;
    }
    const r = await run(`return barHeight().then((during) => { finish(); return settle(1500).then(() => Promise.all([act("ax"), act("type:"), barHeight()])).then(([ax, focus, after]) => ({ ax, focus, during, after })); });`);
    assert.equal(textFields(r.ax).length, 1, "the New Tab field");
    assert.ok(isField(r.focus), `first responder: ${r.focus}`);
    assert.equal(r.after, r.during, "the bar's height");
    await untilSnapshot("New Tab focus after onboarding", (snapshot) =>
      snapshot.windows.some((w) => isField(w.firstResponder)));
    await untilSnapshot("New Tab accessibility text field after onboarding", (snapshot) =>
      snapshot.windows.some((window) => window.textFieldCount === textFields(r.ax).length), { textFields: true });
    return `${r.focus}, bar ${r.during} -> ${r.after}`;
  });

  await rep.check("Continue through every step ends onboarding, saved at the outro", async () => {
    const r = await run(`
      const state = () => nativeOverlay().then((n) => (n ? S.devOnboarding("state").then(JSON.parse) : { active: !!acOnboarding.store.getState().windowId, step: acOnboarding.store.getState().step, sub: acOnboarding.store.getState().sub }));
      acOnboarding.start(null, "source");
      let continues = 0;
      const pages = [];
      const loop = () => state().then((s) => {
        if (!s.active || acOnboarding.store.getState().leaving) return { continues, pages };
        if (continues > 40) throw new Error("still on " + s.step + ":" + s.sub + " after 40 clicks");
        pages.push(s.step + ":" + s.sub);
        continues += 1;
        return click([363, 663]).then(() => settle(700)).then(loop);
      });
      return settle(1500).then(() => act("fakeActiveClicks")).then(() => click([311, 389])).then(() => settle(500)).then(loop);
    `);
    await sleep(1500);
    const saved = JSON.parse(readFileSync(join(data, "onboarding.json"), "utf8"));
    assert.ok(saved.completedAt, "completedAt");
    assert.equal(saved.step, "outro", "the saved step");
    if (native) await untilSnapshot("onboarding ended", (snapshot) => snapshot.onboarding.state.active === false);
    return `${r.continues} clicks: ${r.pages.join(" ")}; picked ${Object.keys(saved.picked ?? {}).length}`;
  });
} finally {
  await app?.quit();
  if (!keep) rmSync(data, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);
