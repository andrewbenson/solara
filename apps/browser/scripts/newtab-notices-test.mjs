import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = "node apps/browser/scripts/newtab-notices-test.mjs <Debug Solara.app> <scratch> [--baseline]\n--baseline requires a frozen pre-port RN bundle; it refuses current native-only drawing.";
const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) { console.log(HELP); process.exit(0); }
assert.ok(args.length >= 2 && args.every((value, index) => index < 2 || value === "--baseline"), HELP);
const [appPath, scratch] = args.slice(0, 2).map(value => resolve(value));
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
const bundleId = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8" }).trim();
assert.ok(bundleId.endsWith(".dev"), "use the isolated dev identity");
const baseline = args.includes("--baseline");
process.env.AC_UITEST_WAIT ??= "480";
process.env.AC_KEEP_DATA = "1";
mkdirSync(scratch, { recursive: true });
process.env.TMPDIR = join(scratch, "tmp");
mkdirSync(process.env.TMPDIR, { recursive: true });
const captures = join(scratch, "captures");
mkdirSync(captures, { recursive: true });
const rep = reporter(join(scratch, "newtab-notices-test.log"), { name: "newtab-notices-test" });
let app;
let launching;
let cleaning;
let stopping = false;
let failed = false;
const cleanup = () => cleaning ??= (async () => {
  const deadline = setTimeout(() => process.exit(1), 30_000);
  try { await (app ?? await launching?.catch(() => null))?.quit({ graceful: false }); }
  finally { clearTimeout(deadline); }
})();
const stop = async (code, reason) => {
  stopping = true;
  console.error(reason);
  await cleanup();
  process.exit(code);
};
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) process.once(signal, () => void stop(code, signal));
const deadline = setTimeout(() => void stop(1, "newtab-notices-test exceeded 570 seconds"), 570_000);
const run = body => {
  assert.ok(!stopping, "test is stopping");
  return app.eval(`const noticeInWindow = fiber => { for (let node=fiber;node;node=node.return) { if (node.memoizedProps?.windowId === "w1" || node.memoizedProps?.tabId === "a") return true; } return false; };\n${body}`, { timeout: 4000 });
};
const until = async (name, sample, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  do {
    if (!app.stillOwned()) throw new Error(`instance exited waiting for ${name}`);
    last = await sample();
    if (accept(last)) return last;
    await sleep(60);
  } while (Date.now() < end);
  const diagnostics = name === "postcard dismissed" ? await noticeDiagnostics() : null;
  throw new Error(`${name}: ${JSON.stringify(last)}${diagnostics ? " diagnostics=" + JSON.stringify(diagnostics) : ""}`);
};
const banner = (action = "state", argument = null, windowId = "w1") => run(`return globalThis.expo.modules.SolaraHosted.devCheckInBanner(${JSON.stringify(windowId)},${JSON.stringify(action)},${JSON.stringify(argument)}).then(JSON.parse);`);
const postcard = (kind = "releaseNotesPostcard", action = "state", argument = null, windowId = "w1") => run(`return globalThis.expo.modules.SolaraHosted.devPostcard(${JSON.stringify(windowId)},${JSON.stringify(kind)},${JSON.stringify(action)},${JSON.stringify(argument)}).then(JSON.parse);`);
const postcardDismissReady = () => until("postcard dismiss control ready", () => postcard("releaseNotesPostcard", "find", "Dismiss release notes"), value => value.found && value.enabled);
const focusPostcardDismiss = async () => {
  assert.equal((await postcard("releaseNotesPostcard", "focus", "What's new in Solara")).accepted, true);
  await postcardDismissReady();
  assert.equal((await postcard("releaseNotesPostcard", "focus", "Dismiss release notes")).accepted, true);
};
const hero = (windowId = "w1") => run(`const fiber=acPerf.findFibers("NativeNewTabHero",50).find(f=>f.memoizedProps?.windowId===${JSON.stringify(windowId)}); for(let hook=fiber?.memoizedState;hook;hook=hook.next){const ref=hook.memoizedState?.current;if(ref&&typeof ref.driverState==="function")return ref.driverState().then(JSON.parse);}return null;`);
const prepareEditor = async (windowId = "w1", text = "notice selection fixture") => {
  await run(`ac.store.getState().setFocusedWindow(${JSON.stringify(windowId)});return true;`);
  await sleep(60);
  await run(`const fiber=acPerf.findFibers("NativeNewTabHero",50).find(f=>f.memoizedProps?.windowId===${JSON.stringify(windowId)});for(let hook=fiber?.memoizedState;hook;hook=hook.next){const ref=hook.memoizedState?.current;if(ref&&typeof ref.driverState==="function")return ref.focus().then(()=>ref.clear()).then(()=>ref.type(${JSON.stringify(text)})).then(()=>ref.applyMenu("selectAll")).then(()=>true);}throw new Error("missing hero ref");`);
  await run(`return [["\\uf702",123,false],...Array.from({length:3},()=>["\\uf703",124,false]),...Array.from({length:6},()=>["\\uf703",124,true])].reduce((previous,[key,keyCode,shift])=>previous.then(()=>ac.shell.devKeyEquivalent(${JSON.stringify(windowId)},{key,keyCode,modifiers:shift?["shift","function"]:["function"],send:true,asKey:true,wait:1})).then(result=>{if(result.error||result.handledBy!=="sent")throw new Error(JSON.stringify(result));}),Promise.resolve()).then(()=>true);`);
  return until("hero edit selected", () => hero(windowId), value => value?.focused && value.fieldValue === text && value.fieldSelection?.start === 3 && value.fieldSelection?.end === 9);
};
const nativeNotices = (action, argument = null) => run(`return globalThis.expo.modules.SolaraHosted.devNewTabNotices(${JSON.stringify(action)},${JSON.stringify(argument && JSON.stringify(argument))}).then(JSON.parse);`);
const fixture = () => baseline
  ? run('acCheckIn.store.setState({trialStartedAt:Date.now()-8*86400000,doneAt:null}); acReleaseNotes.store.setState({page:null}); acReleaseNotes.queue("1.0"); return true;')
  : nativeNotices("fixture");
const noticeState = () => baseline
  ? run('return {...acReleaseNotes.store.getState(), doneAt: acCheckIn.store.getState().doneAt};')
  : nativeNotices("state");
const openNotes = (windowId) => baseline
  ? run(`acReleaseNotes.open(${JSON.stringify(windowId)}, "1.0"); return true;`)
  : nativeNotices("open", { windowId, version: "1.0" });
const closeNotes = () => baseline
  ? run('acReleaseNotes.store.setState({page:null}); return true;')
  : nativeNotices("close");
const queueNotes = () => baseline
  ? run('acReleaseNotes.queue("1.0"); return true;')
  : nativeNotices("queue", { version: "1.0" });
const noticeDiagnostics = async () => ({ native: await postcard(), notices: await noticeState() });
const hoverRN = async (name, on) => run(`const f=acPerf.findFibers(${JSON.stringify(name)},10).find(noticeInWindow); const visit=n=>{if(!n)return false;if(n.memoizedProps?.onMouseEnter){n.memoizedProps[${JSON.stringify(on ? "onMouseEnter" : "onMouseLeave")}]();return true;}return visit(n.child)||visit(n.sibling)}; return visit(f?.child);`);
const capture = async name => {
  assert.equal(await run(`return ac.shell.devSnapshotWindow("w1",${JSON.stringify(join(captures, name + ".png"))});`), true);
  const rnFrames = baseline ? await run('const out=[]; const labels=new Set(["How are you liking Solara? Leave us feedback","Dismiss","What\'s new in Solara","Latest Release Notes","Dismiss release notes","Close release notes"]); const visit=n=>{if(!n)return;const label=n.memoizedProps?.accessibilityLabel;if(labels.has(label)&&typeof n.stateNode?.measureInWindow === "function")out.push(new Promise(done=>n.stateNode.measureInWindow((x,y,width,height)=>done({label,frame:[x,y,width,height]}))));visit(n.child);visit(n.sibling);};for(const name of ["CheckInBanner","ReleaseNotesPostcard","ReleaseNotesPage"])for(const f of acPerf.findFibers(name,10).filter(noticeInWindow))visit(f.child);return Promise.all(out);') : null;
  const state = { snapshot: await app.snapshot(), ...(baseline ? { rnFrames } : { banner: await banner(), postcard: await postcard(), page: await postcard("releaseNotesPage") }) };
  writeFileSync(join(captures, name + ".json"), JSON.stringify(state, null, 2));
  if (name === "dark-rest" || name === "dark-page") {
    const directory = join(captures, name + "-metal");
    mkdirSync(directory, { recursive: true });
    const shaders = await run(`return globalThis.expo.modules.SolaraAreaLight.debugSnapshot(${JSON.stringify(directory)});`);
    writeFileSync(join(captures, name + "-metal.json"), JSON.stringify(shaders, null, 2));
  }
};
const check = async (name, fn) => { if (!await rep.check(name, fn)) throw new Error(`stopping after ${name}`); };
try {
  launching = launch(appPath, { data: join(scratch, "data"), ready: false, fresh: true, onboarded: true, probe: true, keepData: true, startTimeout: 25_000, files: { "bench-offline": "" }, session: session({
    profiles: ["Personal", "Work"],
    windows: [{ id: "w1", profileId: "default", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } }, { id: "w2", profileId: "work", frame: [100, 100, 1100, 800], activeTabIds: { work: "b" } }],
    tabs: [{ id: "a", windowId: "w1", url: "", title: "" }, { id: "b", windowId: "w2", url: "", title: "" }],
    settings: { appearance: "dark", newTabOpens: "page", addressBar: "toolbar", searchSuggestions: false, warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false },
  }), env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_NEWTAB: "1" } });
  app = await launching;
  await app.ready({ timeout: 25_000, test: baseline ? "return !!globalThis.acCheckIn && !!globalThis.acReleaseNotes && !!ac.store.getState().windows.w2;"
    : "return !!globalThis.expo.modules.SolaraHosted?.devNewTabNotices && !!ac.store.getState().windows.w2;" });
  await fixture();
  if (baseline) {
    await until("frozen pre-port RN Card and Artwork mounted", () => run('return ["Card","Artwork","ReleaseNotesPostcard"].map(name=>acPerf.findFibers(name,20).filter(noticeInWindow).length);'), value => value.every(Boolean));
    await run('globalThis.acNoticeMotion = { started: Date.now(), values: {}, subscriptions: [] }; for (const name of ["Card","ReleaseNotesPostcard"]) { const f = acPerf.findFibers(name,10).find(noticeInWindow); let index = 0; for (let hook=f?.memoizedState;hook;hook=hook.next) { const value=hook.memoizedState?.current; if (value && typeof value.addListener === "function" && typeof value.__getValue === "function") { const key=name+":"+index++; acNoticeMotion.values[key]=[[Date.now(),value.__getValue()]]; const id=value.addListener((recordKey=>event=>acNoticeMotion.values[recordKey].push([Date.now(),event.value]))(key)); acNoticeMotion.subscriptions.push([value,id,key,value._animation]); } } } return Object.keys(acNoticeMotion.values);');
    await sleep(1600);
    const motion = await run('for(const [value,id] of acNoticeMotion.subscriptions)value.removeListener(id); return {started:acNoticeMotion.started,values:acNoticeMotion.values,origins:Object.fromEntries(acNoticeMotion.subscriptions.map(([, ,key,animation])=>[key,animation?{start:animation._startTime??animation._lastTime,delay:animation._delay??0,duration:animation._duration,from:animation._fromValue??animation._startPosition,to:animation._toValue}:null]))};');
    writeFileSync(join(captures, "rn-intro-motion.json"), JSON.stringify(motion, null, 2));
  }
  if (!baseline) await until("native notices mounted", async () => [await banner(), await postcard()], value => value.every(item => item.active));
  await check("due check-in and queued 1.0 postcard match the light and dark fixture captures", async () => {
    for (const appearance of ["dark", "light"]) {
      await run(`ac.store.getState().updateSettings({appearance:${JSON.stringify(appearance)}}); return true;`);
      await sleep(1200);
      await capture(`${appearance}-rest`);
      if (baseline) { await hoverRN("Card", true); await hoverRN("ReleaseNotesPostcard", true); }
      else { await banner("hover", "true"); await postcard("releaseNotesPostcard", "hover", "true"); }
      await sleep(500);
      await capture(`${appearance}-hover`);
      if (baseline) await openNotes("w1");
      else assert.equal((await postcard("releaseNotesPostcard", "key", "What's new in Solara|Space")).accepted, true);
      await until("notes page opened", noticeState, value => value.page?.windowId === "w1" && !value.pending);
      if (baseline) {
        await until("RN page mounted", () => run('return acPerf.findFibers("ReleaseNotesPage",10).length;'), Boolean);
        await run('const f=acPerf.findFibers("ReleaseNotesPage",10).find(noticeInWindow);globalThis.acNoticePageMotion={started:Date.now(),values:[],subscriptions:[]};for(let hook=f?.memoizedState;hook;hook=hook.next){const value=hook.memoizedState?.current;if(value&&typeof value.addListener==="function"&&typeof value.__getValue==="function"){acNoticePageMotion.values.push([Date.now(),value.__getValue()]);const id=value.addListener(event=>acNoticePageMotion.values.push([Date.now(),event.value]));acNoticePageMotion.subscriptions.push([value,id,value._animation]);}}return true;');
      }
      await sleep(1000);
      await capture(`${appearance}-page`);
      if (baseline) {
        const motion=await run('for(const [value,id] of acNoticePageMotion.subscriptions)value.removeListener(id);return {started:acNoticePageMotion.started,values:acNoticePageMotion.values,origins:acNoticePageMotion.subscriptions.map(([, ,animation])=>animation?{start:animation._startTime??animation._lastTime,delay:animation._delay??0,duration:animation._duration,from:animation._fromValue??animation._startPosition,to:animation._toValue}:null)};');
        writeFileSync(join(captures, `${appearance}-page-motion.json`), JSON.stringify(motion,null,2));
      }
      if (baseline) await closeNotes();
      else assert.equal((await postcard("releaseNotesPage", "press", "Close release notes")).accepted, true);
      await until("page closed", () => noticeState().then(state => state.page), value => value === null);
      await queueNotes();
      if (baseline) await hoverRN("Card", false);
      else await banner("hover", "false");
      await sleep(1000);
    }
    return { baseline, captures };
  });
  if (!baseline) {
    await check("keyboard opening and closing release notes preserves the New Tab edit", async () => {
      await fixture();
      await until("postcard ready", () => postcard(), value => value.active);
      const before = await prepareEditor();
      assert.equal((await postcard("releaseNotesPostcard", "focus", "What's new in Solara")).accepted, true);
      await postcard("releaseNotesPostcard", "key", "What's new in Solara|Space");
      await until("notes page ready", () => postcard("releaseNotesPage"), value => value.active);
      assert.equal((await postcard("releaseNotesPage", "focus", "Close release notes")).accepted, true);
      await postcard("releaseNotesPage", "key", "Close release notes|Return");
      await until("notes page closed", () => noticeState().then(state => state.page), value => value === null);
      const restored = await until("hero focus restored after page", () => hero(), value => value?.focused);
      assert.equal(restored.fieldValue, before.fieldValue);
      assert.deepEqual(restored.fieldSelection, before.fieldSelection);
      await fixture();
      return true;
    });
    await check("keyboard notice dismissal restores the New Tab edit and selection", async () => {
      for (const kind of ["releaseNotesPostcard", "checkInBanner"]) {
        await fixture();
        await until("notice ready", () => kind === "checkInBanner" ? banner() : postcard(), value => value.active && value.visible !== false);
        const before = await prepareEditor();
        if (kind === "checkInBanner") {
          assert.equal((await banner("focus", "Dismiss")).accepted, true);
          assert.equal((await banner("key", "Dismiss|Return")).accepted, true);
          await until("banner dismissed", () => noticeState().then(state => state.doneAt), value => typeof value === "number");
        } else {
          await focusPostcardDismiss();
          assert.equal((await postcard(kind, "key", "Dismiss release notes|Space")).accepted, true);
          await until("postcard dismissed", () => noticeState().then(state => state.pending), value => value === null);
        }
        const restored = await until("hero focus restored", () => hero(), value => value?.focused);
        assert.equal(restored.fieldValue, before.fieldValue);
        assert.deepEqual(restored.fieldSelection, before.fieldSelection);
      }
      await fixture();
      return true;
    });
    await check("a dismissing notice preserves focus moved to a different field", async () => {
      for (const kind of ["releaseNotesPostcard", "checkInBanner"]) {
        await fixture();
        await until("notice ready", () => kind === "checkInBanner" ? banner() : postcard(), value => value.active && value.visible !== false);
        await prepareEditor();
        if (kind === "checkInBanner") {
          assert.equal((await banner("focus", "Dismiss")).accepted, true);
        } else {
          await focusPostcardDismiss();
        }
        const action = kind === "checkInBanner"
          ? 'hosted.devCheckInBanner("w1", "key", "Dismiss|Return")'
          : 'hosted.devPostcard("w1", "releaseNotesPostcard", "key", "Dismiss release notes|Space")';
        assert.equal(await run(`
          const hosted = globalThis.expo.modules.SolaraHosted;
          const fiber = acPerf.findFibers("NativeNewTabHero", 50).find(f => f.memoizedProps?.windowId === "w2");
          for (let hook = fiber?.memoizedState; hook; hook = hook.next) {
            const field = hook.memoizedState?.current;
            if (typeof field?.driverState !== "function") continue;
            return ${action}.then(JSON.parse).then(result => {
              if (!result.accepted) return false;
              ac.store.getState().setFocusedWindow("w2");
              return field.focus().then(() => true);
            });
          }
          return false;
        `), true);
        const other = await prepareEditor("w2", "other window selected");
        await sleep(500);
        const retained = await hero("w2");
        assert.equal((await hero()).focused, false, kind + " restored focus in the window that lost it");
        assert.equal(retained.focused, true);
        assert.equal(retained.fieldValue, other.fieldValue);
        assert.deepEqual(retained.fieldSelection, other.fieldSelection);
      }
      await fixture();
      return true;
    });
    await check("delayed dismissals cannot cross a profile replacement or close another window's new page", async () => {
      await fixture();
      await banner("hover", "true");
      assert.equal((await banner("press", "Dismiss")).accepted, true);
      await run('ac.store.getState().switchProfile("w1","work"); return true;');
      await sleep(500);
      assert.equal(await noticeState().then(state => state.doneAt), null);
      await until("work notices mounted", async () => [await banner(), await postcard()], value => value.every(item => item.active && item.profileId === "work"));
      await postcard("releaseNotesPostcard", "hover", "true");
      await postcardDismissReady();
      assert.equal((await postcard("releaseNotesPostcard", "press", "Dismiss release notes")).accepted, true);
      await run('ac.store.getState().switchProfile("w1","default"); return true;');
      await sleep(500);
      assert.equal(await noticeState().then(state => state.pending?.version), "1.0");
      await until("default postcard mounted", () => postcard(), value => value.active && value.profileId === "default");
      assert.equal((await postcard("releaseNotesPostcard", "press", "What's new in Solara")).accepted, true);
      await until("first page mounted", () => postcard("releaseNotesPage"), value => value.active);
      assert.equal((await postcard("releaseNotesPage", "press", "Close release notes")).accepted, true);
      await openNotes("w2");
      await sleep(600);
      assert.equal(await noticeState().then(state => state.page?.windowId), "w2");
      assert.equal((await postcard("releaseNotesPage", "press", "Close release notes", "w2")).accepted, true);
      await until("replacement page closed", () => noticeState().then(state => state.page), value => value === null);
      await fixture();
      await until("fixture restored", () => postcard(), value => value.active);
      return true;
    });
    await check("VoiceOver dismissal retires postcard once and the check-in only after its exit", async () => {
      await postcard("releaseNotesPostcard", "hover", "true");
      await postcardDismissReady();
      assert.equal((await postcard("releaseNotesPostcard", "press", "Dismiss release notes")).accepted, true);
      await until("postcard retired", () => noticeState().then(state => state.pending), value => value === null);
      await banner("hover", "true");
      assert.equal((await banner("key", "Dismiss|Return")).accepted, true);
      await until("check-in done", () => noticeState().then(state => state.doneAt), value => typeof value === "number");
      await until("banner removed", () => banner(), value => !value.active || value.visible === false);
      const other = await banner("state", null, "w2");
      assert.ok(!other.active || other.visible === false);
      assert.equal(await noticeState().then(state => state.page), null);
      return true;
    });
    await check("navigation removes hosts and remount respects dismissed state", async () => {
      await run('ac.store.getState().navigate("a","about:blank"); return true;');
      await until("hosts gone", async () => [await banner(), await postcard()], value => value.every(item => !item.active));
      await run('ac.store.getState().newTab("w1"); return true;');
      await sleep(500);
      assert.ok(!(await banner()).active || (await banner()).visible === false);
      assert.equal((await postcard()).active, false);
      await fixture();
      await until("notices remounted", async () => [await banner(), await postcard()], value => value.every(item => item.active));
      return true;
    });
    await check("page is confined to the opening window and profile switches fence native state", async () => {
      assert.equal((await postcard("releaseNotesPostcard", "press", "What's new in Solara")).accepted, true);
      await until("page mounted", () => postcard("releaseNotesPage"), value => value.active);
      assert.equal((await postcard("releaseNotesPage", "state", null, "w2")).active, false);
      await run('ac.store.getState().switchProfile("w1","work"); return true;');
      await sleep(500);
      const state = await postcard("releaseNotesPage");
      assert.ok(!state.active || state.profileId === "work");
      await closeNotes();
      return state;
    });
  }
} catch (error) { failed = true; rep.record("notices test aborted", { error }); }
finally {
  try { await cleanup(); } catch (error) { failed = true; rep.record("cleanup", { error }); }
  clearTimeout(deadline);
}
rep.summary();
console.log(`evidence: ${scratch}`);
process.exitCode = failed ? 1 : 0;
