import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const positional = args.filter((arg) => !arg.startsWith("--"));
if (positional.length !== 2) {
  console.error("usage: node drag-carry-test.mjs <Solara.app> <scratch directory> [--only=keys|hover|controls|inputs] [--matrix] [--in-process] [--case=regex] [--repeat=1] [--skip-controls] [--post-hold-ms=0] [--hover-ms=650] [--baseline]");
  process.exit(64);
}
const [appPath, scratch] = positional.map((value) => resolve(value));
const only = args.find((arg) => arg.startsWith("--only="))?.slice(7);
const baseline = args.includes("--baseline");
const matrix = args.includes("--matrix");
const inProcess = args.includes("--in-process");
const caseFilter = args.find((arg) => arg.startsWith("--case="))?.slice(7);
const casePattern = caseFilter === undefined ? null : new RegExp(caseFilter);
const repeat = Number(args.find((arg) => arg.startsWith("--repeat="))?.slice(9) ?? 1);
const skipControls = args.includes("--skip-controls");
const postHoldMs = Number(args.find((arg) => arg.startsWith("--post-hold-ms="))?.slice(15) ?? 0);
assert.ok(Number.isInteger(postHoldMs) && postHoldMs >= 0 && postHoldMs <= 2000, "post-hold-ms must be an integer from 0 through 2000");
const reproductionDiagnostic = skipControls || casePattern !== null || repeat > 1 || postHoldMs > 0;
assert.ok(Number.isInteger(repeat) && repeat >= 1 && repeat <= 32, "repeat must be an integer from 1 through 32");
const inputDiagnostic = only === "inputs";
const hoverMs = Number(args.find((arg) => arg.startsWith("--hover-ms="))?.slice(11) ?? 650);
assert.ok(!only || ["keys", "hover", "controls", "inputs"].includes(only));
assert.ok(Number.isFinite(hoverMs) && hoverMs >= 600 && hoverMs <= 5000);
mkdirSync(scratch, { recursive: true });
const rep = reporter(join(scratch, "drag-carry-test.log"), { name: reproductionDiagnostic ? "drag-carry-reproduction" : inputDiagnostic ? "drag-carry-input-diagnostic" : "drag-carry-test" });
if (reproductionDiagnostic) rep.say(`Reproduction diagnostic: filter=${caseFilter ?? "all"}, repeat=${repeat}, skipControls=${skipControls}, postHoldMs=${postHoldMs}; does not replace complete driver acceptance.`);
if (inputDiagnostic) rep.say("Input and cancellation diagnostic only; successful page-drop acceptance is not tested in this mode.");
else if (inProcess) rep.say("Original native session destination adapter: Chromium destination callbacks and trusted renderer delivery; WindowServer routing and automatic spring dwell are not tested.");
const here = dirname(fileURLToPath(import.meta.url));
const helper = join(scratch, "drag-carry-events");
execFileSync("xcrun", ["clang", "-fobjc-arc", "-framework", "AppKit", "-framework", "ApplicationServices", "-framework", "QuartzCore", join(here, "drag-carry-events.m"), "-o", helper], { timeout: 30000 });
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=", "base64");
const html = (id) => `<!doctype html><meta charset="utf-8"><title>drag-carry-${id}</title><style>body{margin:0;background:#fafafa;font:24px sans-serif}img{position:absolute;left:64px;top:80px;width:120px;height:100px;background:#5599cc}h1{margin:24px}</style><h1>${id}</h1><a id="link" draggable="true" href="/carried-link?carry-token" style="position:absolute;left:64px;top:210px">Carry link</a><input id="field" style="position:absolute;left:360px;top:280px;width:320px;height:60px"><img id="carry" draggable="true" src="/image.png?carry-token"><script>
globalThis.carryEvents=[];
globalThis.carryImageReceipt=null;
const fileMetadata=file=>({name:file.name,type:file.type,size:file.size,lastModified:file.lastModified});
const imagePixels=image=>{const canvas=document.createElement("canvas");canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;const context=canvas.getContext("2d");context.drawImage(image,0,0);return {width:canvas.width,height:canvas.height,pixels:[...context.getImageData(0,0,canvas.width,canvas.height).data]};};
const receiveImage=async(value,files)=>{
  try{
    const file=files.find(item=>item.type.startsWith("image/")||/\\.(png|jpe?g|gif|webp|tiff?|bmp|ico)$/i.test(item.name));
    let src;
    if(file)src=URL.createObjectURL(file);
    else{
      const parsed=new DOMParser().parseFromString(value.html,"text/html");
      const candidate=parsed.querySelector("img")?.getAttribute("src")||value.uri.split("\\n").find(line=>line&&!line.startsWith("#"))||value.text;
      if(!candidate)return;
      const url=new URL(candidate,location.href);
      if(url.origin!==location.origin||url.pathname!=="/image.png")return;
      src=url.href;
    }
    const image=document.createElement("img");
    image.id="received";image.style.cssText="left:360px;top:400px;width:120px;height:100px";image.src=src;document.body.append(image);
    await image.decode();
    const rect=image.getBoundingClientRect();
    carryImageReceipt={complete:true,via:file?"file":"received-image-url",src,file:file?fileMetadata(file):null,...imagePixels(image),bounds:[rect.x,rect.y,rect.width,rect.height],visible:getComputedStyle(image).visibility==="visible",trustedDrop:value.trusted,dropTime:value.time};
    value.image=carryImageReceipt;
  }catch(error){carryImageReceipt={complete:false,error:String(error)};value.image=carryImageReceipt;}
};
for(const type of ["dragstart","dragend","dragenter","dragleave","dragover","drop","keydown","keyup"]){document.addEventListener(type,event=>{
  if((type==="dragover"||type==="dragenter"||type==="drop")&&event.target.id!=="field")event.preventDefault();
  if(type==="dragover")event.dataTransfer.dropEffect="copy";
  const files=[...(event.dataTransfer?.files??[])];
  const value={type,time:Date.now(),trusted:event.isTrusted,key:event.key??null,types:[...(event.dataTransfer?.types??[])],files:files.map(fileMetadata),items:[...(event.dataTransfer?.items??[])].map(item=>({kind:item.kind,type:item.type})),dropEffect:event.dataTransfer?.dropEffect??null,effectAllowed:event.dataTransfer?.effectAllowed??null};
  if(type==="drop"){
    value.uri=event.dataTransfer.getData("text/uri-list");value.html=event.dataTransfer.getData("text/html");value.text=event.dataTransfer.getData("text/plain");
    value.fileHashesComplete=false;
    Promise.all(files.map(async(file,index)=>{const bytes=await file.arrayBuffer();const hash=await crypto.subtle.digest("SHA-256",bytes);Object.assign(value.files[index],{byteLength:bytes.byteLength,sha256:[...new Uint8Array(hash)].map(byte=>byte.toString(16).padStart(2,"0")).join("")});})).then(()=>{value.fileHashesComplete=true;},error=>{value.fileHashError=String(error);});
    if(event.target.id!=="field")void receiveImage(value,files);
  }
  carryEvents.push(value);if(carryEvents.length>300)carryEvents.shift();
},true);}

</script>`;
const server = createServer((request, response) => {
  if (request.url.startsWith("/image.png")) {
    response.writeHead(200, { "Content-Type": "image/png" });
    response.end(png);
  } else {
    response.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "no-store" });
    response.end(html(request.url.slice(1)));
  }
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${server.address().port}`;
let app;
const pages = new Map();
const run = (body) => app.eval(`const st=()=>ac.store.getState();const M=globalThis.expo.modules;${body}`, { timeout: 4000 });
const until = async (name, read, accept, timeout = 8000) => {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    assert.ok(app.alive, `${name}: owned app exited`);
    last = await read();
    if (accept(last)) return last;
    await sleep(60);
  }
  throw new Error(`${name}: ${JSON.stringify(last)}`);
};
const state = () => run("const w=st().windows.w1;return {profile:w.profileId,active:w.activeTabIds[w.profileId]};");
const select = async (id, profile = "default") => {
  await run(`st().switchProfile("w1",${JSON.stringify(profile)});st().activate(${JSON.stringify(id)});return true;`);
  await until(`select ${id}`, state, (value) => value.profile === profile && value.active === id);
  await sleep(500);
};
const pageGeometry = async (id) => {
  const shell = await until(`native page frame for ${id}`, () => run('return M.SolaraWindowShell.describe("w1").then(JSON.parse);'), (value) => value?.layout?.actual?.[`page:${id}`]?.[2] > 100);
  const [x, y, width, height] = shell.layout.actual[`page:${id}`];
  return { x, y, width, height };
};
const rowPoint = async (id, layout) => {
  if (layout === "top") {
    const data = await run('return M.SolaraTopStrip.items("w1").then(JSON.parse);');
    const item = data.items.find((value) => value.kind === "tab" && value.id === id);
    assert.ok(item?.width > 0, `actual strip target ${id}: ${JSON.stringify(data)}`);
    return [item.windowX + item.width / 2, item.windowY + item.height / 2];
  }
  const data = await run('return M.SolaraSidebarDrag.startProbe("w1").then(JSON.parse);');
  const item = data.items.find((value) => value.tabIds.includes(id) && value.kind === "row");
  assert.ok(item?.w > 0, `actual sidebar target ${id}: ${JSON.stringify(data)}`);
  return [item.x + item.w / 2, item.y + item.h / 2];
};
const profilePoint = async (profile) => {
  const column = await run('return M.SolaraHosted.sidebarShell("w1").then(JSON.parse);');
  const dot = column.chrome?.dots?.find((value) => value.id === profile && !value.hidden);
  assert.ok(dot, `visible native Work profile slot: ${JSON.stringify(column)}`);
  return [column.frame[0] + dot.rect[0] + dot.rect[2] / 2, column.frame[1] + dot.rect[1] + dot.rect[3] / 2];
};
const post = (name, steps, windowNumber) => {
  const plan = join(scratch, `${name}-plan.json`);
  writeFileSync(plan, JSON.stringify(steps, null, 2));
  return new Promise((done, fail) => {
    const child = spawn(helper, [String(app.pid), String(windowNumber), plan, String(postHoldMs)], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    const timer = setTimeout(() => { child.kill("SIGTERM"); fail(new Error("CG event plan exceeded 20 seconds")); }, 20000);
    child.stdout.on("data", (data) => { stdout += data; });
    child.stderr.on("data", (data) => { stderr += data; });
    child.once("error", (error) => { clearTimeout(timer); fail(error); });
    child.once("exit", (code) => {
      clearTimeout(timer);
      writeFileSync(join(scratch, `${name}-posted.jsonl`), stdout);
      if (code !== 0) fail(new Error(`CG plan exited ${code}: ${stderr}`));
      else done(stdout.trim().split("\n").map((line) => JSON.parse(line)));
    });
  });
};
let malformedChecked = false;
const keySteps = (at, code, flags) => [{ at, type: "keyDown", code, flags }, { at: at + 40, type: "keyUp", code, flags }];
const move = (at, type, point) => ({ at, type, x: point[0], y: point[1] });
const carry = async (name, { layout = "sidebar", target = "b", profile = "default", sourceTab = "a", sourceProfile = "default", key = null, swipe = false, mayBegin = false, control = false, link = false, cancel = false, cancelAt = null } = {}) => {
  await run(`st().updateSettings({tabLayout:${JSON.stringify(layout)},sidebarIconsOnly:false});return true;`);
  await select(target, profile);
  const destination = await pageGeometry(target);
  await select(sourceTab, sourceProfile);
  const source = await pageGeometry(sourceTab);
  const hover = key || swipe || control ? null : profile !== sourceProfile ? await profilePoint(profile) : await rowPoint(target, layout);
  const column = swipe ? await run('return M.SolaraHosted.sidebarShell("w1").then(JSON.parse);') : null;
  const swipePoint = column ? [column.frame[0] + column.frame[2] / 2, column.frame[1] + column.frame[3] * 0.65] : null;
  const nativeWindows = await run('return M.SolaraCEF.chromeWindows();');
  const windowNumber = nativeWindows.find((value) => value.hasRoot)?.window;
  assert.ok(windowNumber, JSON.stringify(nativeWindows));
  for (const page of pages.values()) await page.eval('carryEvents=[];carryImageReceipt=null;document.querySelector("#received")?.remove();document.querySelector("#field").value="";true');
  await run('globalThis.__carrySwitches=[];globalThis.__carryStop?.();globalThis.__carryStop=ac.store.subscribe((s)=>{const w=s.windows.w1;__carrySwitches.push({time:Date.now(),profile:w.profileId,active:w.activeTabIds[w.profileId]});});return true;');
  const traceStart = await run(`return M.SolaraCEF.devWindow(${windowNumber},"dragCarry:start");`);
  const from = [source.x + 124, source.y + (link ? 222 : 130)];
  const to = link ? [destination.x + 500, destination.y + 310] : [destination.x + destination.width * 0.65, destination.y + destination.height * 0.6];
  const initial = [move(300, "down", from), move(460, "dragged", [from[0] + 8, from[1] + 8]), move(500, "dragged", [from[0] + 24, from[1] + 24])];
  const releasedAt = cancelAt !== null ? cancelAt + 350 : inProcess ? 8000 : key || swipe || control ? 2300 : 950 + hoverMs + 450;
  const steps = [
    ...initial,
    ...(control ? [] : key ? keySteps(900, key.code, key.flags) : swipe ? [
      move(700, "dragged", swipePoint),
      ...(mayBegin ? [{ at: 810, type: "scroll", phase: 128, dx: 0, x: swipePoint[0], y: swipePoint[1] }] : []),
      ...[[850, 1, 0], [890, 2, -30], [930, 2, -35], [970, 2, -35], [1010, 2, -35], [1050, 2, -35], [1090, 4, 0]].map(([at, phase, dx]) => ({ at, type: "scroll", phase, dx, x: swipePoint[0], y: swipePoint[1] })),
    ] : [move(850, "dragged", hover), move(950, "dragged", hover), move(950 + hoverMs, "dragged", hover)]),
    ...(cancel ? keySteps(releasedAt - 350, 53, 0) : []), move(releasedAt - 300, "dragged", to), move(releasedAt - 100, "dragged", [to[0] + 2, to[1] + 2]), move(releasedAt, "up", to),
  ];
  let posted;
  let nativeError;
  let beforeRelease;
  const nativeReceipts = [];
  const nativeAction = async (op, point) => {
    const request = { op, ...(point ? { x: point[0], y: point[1] } : {}) };
    try {
      const response = await run(`return M.SolaraCEF.devWindow(${windowNumber},${JSON.stringify(`dragCarry:native:${JSON.stringify(request)}`)});`);
      const receipt = typeof response === "string" ? JSON.parse(response) : response;
      nativeReceipts.push({ op, receivedAt: Date.now(), ...receipt });
      writeFileSync(join(scratch, `${name}-native-receipts.json`), JSON.stringify(nativeReceipts, null, 2));
      return receipt;
    } catch (error) {
      nativeReceipts.push({ op, receivedAt: Date.now(), transportError: String(error.stack ?? error), appAlive: app.alive });
      writeFileSync(join(scratch, `${name}-native-receipts.json`), JSON.stringify(nativeReceipts, null, 2));
      throw error;
    }
  };
  const assertOriginalSession = (receipt, original) => {
    assert.equal(receipt.adapter, "original-session-native-destination", "the adapter uses the native destination path");
    assert.equal(receipt.error, undefined, JSON.stringify(receipt));
    assert.equal(receipt.live, true, "the original native source session remains live");
    assert.equal(receipt.sequence, original.sequence, "native destination keeps the original source sequence");
    assert.equal(receipt.pasteboard, original.pasteboard, "native destination reads the original source pasteboard");
    assert.equal(receipt.changeCount, original.originalChangeCount, "the original source pasteboard is unchanged");
    assert.equal(receipt.sourceWindow, windowNumber, "the adapter stays in the captured source window");
    if (receipt.destinationWindow) assert.equal(receipt.destinationWindow, windowNumber, "the live native target belongs to the source window");
  };
  if (inProcess && !malformedChecked) {
    malformedChecked = true;
    for (const body of ['{"op":1}', '{"op":"enter","x":null,"y":5}', '{"op":"drop","x":"1","y":2}', '[1,2]', "not json"]) {
      const response = await run(`return M.SolaraCEF.devWindow(${windowNumber},${JSON.stringify(`dragCarry:native:${body}`)});`);
      const receipt = typeof response === "string" ? JSON.parse(response) : response;
      assert.equal(receipt.error, "malformed destination request", `a malformed adapter request fails cleanly: ${body}`);
    }
    assert.ok(app.alive, "malformed adapter requests leave the instance running");
    rep.say("malformed adapter requests: 5/5 rejected cleanly");
  }
  try {
    const posting = post(name, steps, windowNumber);
    if (inProcess) {
      try {
        const original = await until("live original native drag", () => nativeAction("state"), (receipt) => receipt.live && !receipt.error, 3000);
        assertOriginalSession(original, original);
        if (hover) {
          const entered = await nativeAction("springEnter", hover);
          assertOriginalSession(entered, original);
          assert.ok(entered.springOptions > 0, "production native hover target enables spring loading");
          await sleep(Math.max(hoverMs, 700));
          const activated = await until("stable production spring target dwell", () => nativeAction("springActivate", hover), (receipt) => receipt.activated === true && receipt.dwell >= 0.65, 2500);
          assertOriginalSession(activated, original);
          assert.equal(activated.activated, true, "production native spring target activates after a stable adapter dwell");
          assert.ok(activated.dwell >= 0.65, "intervening native spring resets retain their full dwell before activation");
        }
        if (!control && cancelAt === null) await until("destination selection during original native drag", state, (value) => value.profile === profile && value.active === target, 3500);
        if (!cancel) {
          const entered = await nativeAction("enter", to);
          assertOriginalSession(entered, original);
          assert.equal(entered.destinationClass, "WebContentsViewCocoa", "the actual Chromium page owns native destination handling");
          const updated = await until("renderer dragenter/dragover and native destination acceptance", async () => ({ receipt: await nativeAction("update", to), events: await pages.get(target).eval("carryEvents") }), ({ receipt, events }) => receipt.live && !receipt.error && receipt.operation > 0 && ["dragenter", "dragover"].every((type) => events.some((event) => event.type === type && event.trusted)), 2500);
          assertOriginalSession(updated.receipt, original);
          const dropped = await nativeAction("drop", to);
          assertOriginalSession(dropped, original);
          assert.equal(dropped.attempted, true, "the native destination performs the original session drop once");
          assert.equal(dropped.accepted, true, "Chromium's own native destination accepts the original payload");
          const destinationEvents = await until("trusted renderer drop through native destination", () => pages.get(target).eval("carryEvents"), (events) => events.some((event) => event.type === "drop" && event.trusted && event.fileHashesComplete), 2000);
          const image = link ? null : await until("received image decodes and displays before release", () => pages.get(target).eval("carryImageReceipt"), (value) => value?.complete, 2000);
          beforeRelease = { image, state: await state(), native: await nativeAction("state"), destination: destinationEvents, field: await pages.get(target).eval('document.querySelector("#field").value') };
          beforeRelease.time = Date.now();
          assertOriginalSession(beforeRelease.native, original);
          writeFileSync(join(scratch, `${name}-before-release.json`), JSON.stringify(beforeRelease, null, 2));
        }
      } catch (error) {
        nativeError = String(error.stack ?? error);
      }
    }
    posted = await posting;
    await sleep(600);
  } finally {
    if (!posted) {
      const release = join(scratch, `${name}-emergency-release.json`);
      writeFileSync(release, JSON.stringify([move(0, "up", to)]));
      try { execFileSync(helper, [String(app.pid), String(windowNumber), release], { timeout: 3000 }); } catch {}
      await run(`return M.SolaraCEF.devWindow(${windowNumber},"dragCarry:stop");`).catch(() => {});
    }
    await run('globalThis.__carryStop?.();globalThis.__carryStop=null;return true;').catch(() => {});
  }
  const traceText = await run(`return M.SolaraCEF.devWindow(${windowNumber},"dragCarry:read");`);
  const trace = Array.isArray(traceText) ? traceText : typeof traceText === "string" && traceText.startsWith("[") ? JSON.parse(traceText) : [];
  await run(`return M.SolaraCEF.devWindow(${windowNumber},"dragCarry:stop");`);
  if (!cancel) {
    await until("dropped file metadata settles", () => pages.get(target).eval("carryEvents"), (events) => events.some((event) => event.type === "drop" && event.fileHashesComplete), 2000).catch(() => {});
    if (!link) await until("received image decodes and displays", () => pages.get(target).eval("carryImageReceipt"), (value) => value?.complete, 2000).catch(() => {});
  }
  const evidence = { reproduction: { enabled: reproductionDiagnostic, caseFilter, repeat, skipControls, postHoldMs }, sourceImage: await pages.get(sourceTab).eval('imagePixels(document.querySelector("#carry"))'), image: await pages.get(target).eval("carryImageReceipt"), proofScope: inputDiagnostic ? "input-and-cancel-diagnostic" : inProcess ? "original-session-native-destination-adapter" : "automatic-native-drag-and-drop", nativeError, nativeReceipts, beforeRelease, ...(inProcess ? { nativeEnd: await nativeAction("state") } : {}), traceStart, posted, source: await pages.get(sourceTab).eval("carryEvents"), destination: await pages.get(target).eval("carryEvents"), field: await pages.get(target).eval('document.querySelector("#field").value'), final: await state(), switches: await run("return globalThis.__carrySwitches;"), trace };
  writeFileSync(join(scratch, `${name}-evidence.json`), JSON.stringify(evidence, null, 2));
  rep.log(name, evidence);
  assert.ok(evidence.source.some((event) => event.type === "dragstart" && event.trusted), "posted CG movement starts Chromium's real trusted image drag");
  assert.ok(evidence.source.some((event) => event.type === "dragend" && event.trusted), "the original Chromium drag ends normally after release");
  if (!baseline && traceStart === "started") {
    const began = trace.find((event) => event.stage === "source.dragBegan");
    const ended = trace.find((event) => event.stage === "source.dragEnded");
    assert.ok(began && ended && began.sequence === ended.sequence, "AppKit source lifecycle reports the same real dragging session");
    if (!inProcess || cancel) assert.equal(ended.operation === 0, cancel, "AppKit final operation distinguishes cancellation from accepted drops");
  }
  const release = posted.findLast((event) => event.type === "up");
  const drawn = posted.find((event) => event.type === "window");
  assert.ok(drawn?.postEventAccess && drawn.info.kCGWindowAlpha > 0, "the real drag runs on a drawn background window with event posting access");
  assert.ok(drawn.info.kCGWindowLayer < 0, "the drawn test window remains below owner windows");
  const dragEnd = evidence.source.findLast((event) => event.type === "dragend");
  if (!inProcess || cancel) assert.equal(dragEnd.dropEffect === "none", cancel, "Chromium reports acceptance or cancellation for the original source drag");
  assert.ok(evidence.source.some((event) => event.type === "dragend" && event.time + 1 >= release.postedWallTime - (cancel ? 400 : 0)), "Chromium keeps the source session alive until the posted release");
  if (nativeError) throw new Error(nativeError);
  if (key || swipe) {
    const input = posted.find((event) => event.type === (swipe ? "scroll" : "keyDown"));
    assert.ok(evidence.source.some((event) => event.type === "dragstart" && event.time <= input.postedWallTime), "the input is posted after Chromium starts the drag");
    const began = trace.find((event) => event.stage === "source.dragBegan");
    const ended = trace.find((event) => event.stage === "source.dragEnded");
    if (traceStart === "started") assert.ok(began && ended && began.time <= input.postedUptime && ended.time >= input.postedUptime, "the input is posted inside the actual AppKit source session");
    assert.ok(dragEnd.time >= input.postedWallTime, "the input is posted before the original source drag ends");
    const delivered = trace.some((event) => event.time >= input.postedUptime - 0.05 && event.time < release.postedUptime && /sendEvent|performKeyEquivalent|preHandle|localMonitor|dragLoop/i.test(event.stage) && (swipe ? event.type === 22 : event.type === 10 && event.keyCode === key.code));
    const dropped = evidence.destination.find((event) => event.type === "drop");
    rep.say(`${name}: ${swipe ? "scroll" : "key"} ${delivered ? "reached an app dispatch path" : "delivery unconfirmed; inspect nextEvent/sendEvent trace"}; target drop ${!!dropped}`);
  }
  if (cancel) {
    const escaped = posted.find((event) => event.type === "keyDown" && event.code === 53);
    const switchedFirst = evidence.switches.some((value) => value.profile === profile && value.active === target && value.time < escaped.postedWallTime);
    if (!control && cancelAt === null) assert.ok(switchedFirst, "destination activation precedes cancellation");
    assert.deepEqual(evidence.final, { profile: sourceProfile, active: sourceTab }, "cancel restores original profile and tab");
    if (cancelAt !== null) {
      await sleep(1500);
      assert.deepEqual(await state(), { profile: sourceProfile, active: sourceTab }, "a settling swipe never re-applies its profile after the cancel restored the original");
      rep.say(`${name}: Escape ${cancelAt - 1090} ms after the swipe ended; switched before Escape ${switchedFirst}; original kept 1.5 s later`);
    }
    assert.ok(!evidence.destination.some((event) => event.type === "drop"), "cancel delivers no drop");
    if (inProcess) {
      assert.equal(evidence.nativeEnd.ended?.operation, 0, "actual AppKit cancellation retains operation none");
      assert.equal(evidence.nativeEnd.ended?.attempted, false, "cancellation never attempts a native destination drop");
    }
    return { evidence: join(scratch, `${name}-evidence.json`) };
  }
  if (!control) assert.ok(evidence.switches.some((value) => value.profile === profile && value.active === target && value.time < release.postedWallTime), "destination switches before the posted mouse release");
  if (inProcess) {
    assert.ok(beforeRelease && beforeRelease.time < release.postedWallTime, "native destination acceptance and trusted renderer drop occur before the actual release");
    assert.deepEqual(beforeRelease.state, { profile, active: target }, "the newly selected page receives the original payload while the source session is live");
    const ended = evidence.nativeEnd.ended;
    assert.ok(ended && ended.sequence === beforeRelease.native.sequence, "the real AppKit source end follows the adapted native destination");
    assert.equal(ended.accepted, true, "native destination acceptance persists in the real source-end receipt");
    if (link) assert.equal(beforeRelease.field, `${origin}/carried-link?carry-token`, "the target text field receives the original link before real release");
    assert.deepEqual(evidence.final, ended.operation === 0 ? { profile: sourceProfile, active: sourceTab } : { profile, active: target }, "the actual source operation preserves accepted selection or restores it on WindowServer cancellation");
    rep.say(`${name}: native destination accepted before release; real AppKit source operation ${ended.operation}; final ${JSON.stringify(evidence.final)}`);
  } else assert.deepEqual(evidence.final, { profile, active: target }, "destination activates while the source drag stays alive");
  const dropped = evidence.destination.find((event) => event.type === "drop" && event.trusted);
  assert.ok(dropped, "Chromium dispatches a trusted drop to the newly selected destination page");
  assert.match(`${dropped.uri}\n${dropped.html}\n${dropped.text}`, link ? /carried-link\?carry-token/ : /image\.png\?carry-token/, "the source payload reaches the destination unchanged");
  assert.equal(dropped.fileHashesComplete, true, "dropped file metadata and byte hashes settle");
  for (const file of dropped.files) {
    assert.equal(file.byteLength, file.size, "a dropped file's bytes match its metadata size");
    assert.match(file.sha256, /^[0-9a-f]{64}$/, "a dropped file retains its binary content hash");
  }
  if (link) assert.equal(evidence.field, `${origin}/carried-link?carry-token`, "native link drop inserts the URL into the target text field");
  else {
    assert.equal(evidence.image?.complete, true, "the accepting page renders and decodes the received image");
    assert.equal(evidence.image.trustedDrop, true, "the displayed image comes from the trusted destination drop");
    assert.deepEqual(evidence.sourceImage, {width:1,height:1,pixels:[255,255,255,255]}, "the original fixture image decodes to its known content");
    assert.deepEqual({width:evidence.image.width,height:evidence.image.height,pixels:evidence.image.pixels}, evidence.sourceImage, "the received image displays the original source's decoded content");
    assert.ok(evidence.image.visible && evidence.image.bounds[2] > 0 && evidence.image.bounds[3] > 0, "the received image has a visible page rectangle");
    if (inProcess) assert.deepEqual(beforeRelease.image, evidence.image, "the original decoded image was displayed before the actual source release");
  }
  return { evidence: join(scratch, `${name}-evidence.json`), hoverMs: key || swipe || control ? null : hoverMs };
};

const defaultTabIds = matrix ? ["a", "b", ...Array.from({ length: 7 }, (_, index) => `t${index + 3}`)] : ["a", "b"];
const profileIds = matrix ? ["work", ...Array.from({ length: 7 }, (_, index) => `profile${index + 3}`)] : ["work"];
const profileTabIds = profileIds.map((_, index) => index === 0 ? "c" : `c${index + 2}`);
const fixtureProfiles = [{ id: "default", name: "Personal" }, ...profileIds.map((id, index) => ({ id, name: index === 0 ? "Work" : `Profile ${index + 2}` }))];
const fixtureTabs = [...defaultTabIds.map((id) => ({ id, url: `${origin}/${id}`, title: `Tab ${id}` })), ...profileTabIds.map((id, index) => ({ id, profileId: profileIds[index], url: `${origin}/${id}`, title: `Profile tab ${index + 2}` }))];
const activeTabIds = { default: "a", ...Object.fromEntries(profileIds.map((id, index) => [id, profileTabIds[index]])) };
const keyCodes = [18, 19, 20, 21, 23, 22, 26, 28, 25];
const keyCases = [
  ...(matrix ? defaultTabIds.map((target, index) => [`command-${index + 1}`, { target, sourceTab: target === "a" ? "b" : "a", key: { code: keyCodes[index], flags: 1048576 } }]) : [["command-2", { key: { code: 19, flags: 1048576 } }]]),
  ["command-shift-next", { key: { code: 30, flags: 1179648 } }],
  ["command-shift-previous", { sourceTab: "b", target: "a", key: { code: 33, flags: 1179648 } }],
  ...(matrix ? ["default", ...profileIds].map((profile, index) => [`control-${index + 1}-profile`, { target: index === 0 ? "a" : profileTabIds[index - 1], profile, sourceTab: index === 0 ? "c" : "a", sourceProfile: index === 0 ? "work" : "default", key: { code: keyCodes[index], flags: 262144 } }]) : [["control-2-profile", { target: "c", profile: "work", key: { code: 19, flags: 262144 } }]]),
  ["profile-swipe", { target: "c", profile: "work", swipe: true }],
  ["profile-swipe-may-begin", { target: "c", profile: "work", swipe: true, mayBegin: true }],
  ["profile-swipe-cancel", { target: "c", profile: "work", swipe: true, cancel: true, cancelAt: 1250 }],
];

try {
  app = await launch(appPath, {
    data: join(scratch, "data"), fresh: true, onboarded: true, probe: true,
    env: { SOLARA_NATIVE_WINDOW_LAYOUT: "1", SOLARA_NATIVE_SHELL: "1", SOLARA_DRAW_WINDOWS: "1", ...(inProcess ? { SOLARA_DRAG_CARRY_DESTINATION_PROBE: "1" } : {}) },
    session: session({
      profiles: fixtureProfiles,
      windows: [{ id: "w1", profileId: "default", frame: [80, 80, 1100, 760], tabIds: fixtureTabs.map((tab) => tab.id), activeTabIds }],
      tabs: fixtureTabs,
      settings: { tabLayout: "sidebar", sleepInactiveTabs: false, warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false },
    }),
  });
  for (const { id, profileId = "default" } of [...fixtureTabs].reverse()) {
    const profile = profileId;
    await select(id, profile);
    const page = await app.page(`${origin}/${id}`);
    await until(`${id} fixture`, () => page.eval('document.readyState === "complete" && !!globalThis.carryEvents && document.images[0]?.naturalWidth > 0'), Boolean);
    pages.set(id, page);
  }
  const windows = await run('return M.SolaraCEF.chromeWindows();');
  const number = windows.find((window) => window.hasRoot).window;
  const tracing = await run(`return M.SolaraCEF.devWindow(${number},"dragCarry:start");`);
  await post("ordinary-key-sentinel", keySteps(0, 7, 0), number);
  await sleep(200);
  const sentinel = await run(`return M.SolaraCEF.devWindow(${number},"dragCarry:read");`);
  writeFileSync(join(scratch, "ordinary-key-sentinel.json"), typeof sentinel === "string" ? sentinel : JSON.stringify(sentinel));
  await run(`return M.SolaraCEF.devWindow(${number},"dragCarry:stop");`);
  rep.log("ordinary-key-sentinel", sentinel);
  const sentinelTrace = Array.isArray(sentinel) ? sentinel : typeof sentinel === "string" && sentinel.startsWith("[") ? JSON.parse(sentinel) : [];
  rep.log("ordinary-key-sentinel-delivery", { delivered: sentinelTrace.some((event) => /app\.(nextEvent|sendEvent)$/.test(event.stage) && event.type === 10 && event.keyCode === 7), tracing });
  const checkCase = async (name, options, { control = false } = {}) => {
    if (casePattern && (!control || only === "controls") && !casePattern.test(name)) return true;
    let passed = true;
    for (let iteration = 1; iteration <= repeat; iteration++) {
      const runName = repeat === 1 ? name : `${name}-repeat-${String(iteration).padStart(2,"0")}`;
      if (!await rep.check(runName, () => carry(runName, options))) passed = false;
      if (!app.alive) break;
    }
    return passed;
  };
  if (!inputDiagnostic && !skipControls) {
    if (!await checkCase("same-page-positive-control", { target: "a", control: true }, { control: true })) throw new Error("CG image drag control failed; refusing to interpret switching results");
    if (!await checkCase("same-page-link-control", { target: "a", control: true, link: true }, { control: true })) throw new Error("CG link drag control failed; refusing to interpret switching results");
  }
  if (only !== "hover" && only !== "controls") {
    for (const [caseName, options] of keyCases) {
      const name = inputDiagnostic ? `${caseName}-cancel-diagnostic` : caseName;
      await checkCase(name, { ...options, cancel: inputDiagnostic || options.cancel === true });
      if (!app.alive) break;
    }
  }
  if (only !== "keys" && only !== "controls" && !inputDiagnostic && app.alive) {
    for (const [name, options] of [
      ["cancel-before-switch", { target: "a", control: true, cancel: true }], ["sidebar-hover", {}], ["sidebar-link-field", { link: true }], ["sidebar-cancel", { cancel: true }], ["profile-cancel", { target: "c", profile: "work", cancel: true }], ["strip-hover", { layout: "top" }], ["profile-hover", { target: "c", profile: "work" }], ["profile-link-field", { target: "c", profile: "work", link: true }],
    ]) {
      await checkCase(name, options);
      if (!app.alive) break;
    }
  }
  assert.ok(rep.results.length > 0, "no driver cases matched the requested filter");
} catch (error) {
  rep.record("driver setup", { error });
} finally {
  for (const page of pages.values()) page.close();
  await app?.quit();
  writeFileSync(join(scratch, "results.json"), JSON.stringify(rep.results, null, 2));
  server.closeAllConnections();
  await new Promise((done) => server.close(done));
}
process.exit(rep.summary() ? 0 : 1);
