import { mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

const { values, positionals } = parseArgs({ allowPositionals: true, options: { baseline: { type: "boolean" } } });
if (positionals.length !== 2) {
  console.error("usage: node toolbar-backdrop-test.mjs <Debug app> <evidence dir> [--baseline]");
  process.exit(2);
}
const app = resolve(positionals[0]), out = resolve(positionals[1]);
mkdirSync(out, { recursive: true });
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end('<title>Toolbar fixture</title><meta name="theme-color" content="#2471A3"><body style="background:#eee">Toolbar fixture</body>');
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = `http://127.0.0.1:${server.address().port}/toolbar`;
let instance;
const evidence = [];
try {
  instance = await launch(app, { data: join(out, "data"), fresh: true, onboarded: true,
    env: { SOLARA_NATIVE_SHELL: "0", SOLARA_DRAW_WINDOWS: "1" } });
  const windowId = await instance.eval(`const s=ac.store.getState(); const id=Object.keys(s.windows)[0]; s.setWindowFrame(id,[100,100,1200,800]); s.updateSettings({extendWebsiteColor:true,hideToolbarWhileScrolling:false,warnBeforeClosingLastTab:false,warnBeforeClosingWindow:false}); s.newTab(id,{url:${JSON.stringify(url)}}); return id;`);
  for (const appearance of ["light", "dark"]) {
    for (const developer of [false, true]) {
      const state = await instance.eval(`const s=ac.store.getState(); s.updateSettings({appearance:${JSON.stringify(appearance)},developerMode:{[s.windows[${JSON.stringify(windowId)}].profileId]:{on:${developer ? '["127.0.0.1"]' : '[]'},off:${developer ? '[]' : '["127.0.0.1"]'},reload:"reload"}}}); return {id:s.windows[${JSON.stringify(windowId)}].activeTabIds[s.windows[${JSON.stringify(windowId)}].profileId]};`);
      await sleep(1800);
      const projection = await instance.eval(`const id=${JSON.stringify(state.id)}, s=ac.store.getState(), tab=s.tabs[id], facts=ac.nativePages.facts(id); if (!facts) throw new Error("missing native page facts"); ac.nativePages.report(id,{type:"navigation",generation:facts.generation,url:tab.url,title:tab.title,isLoading:false,canGoBack:false,canGoForward:false,themeColor:"#2471A3",eventSeq:facts.newestEventSeq+1}); return new Promise((done)=>setTimeout(()=>done({themeColor:ac.store.getState().live[id]?.themeColor,profileId:tab.profileId}),300));`);
      if (projection.themeColor !== "#2471A3") throw new Error(`theme color projection failed: ${JSON.stringify(projection)}`);
      const name = `${appearance}-${developer ? "developer" : "tinted"}`;
      const path = join(out, `${name}.png`);
      const captured = await instance.eval(`return ac.shell.devSnapshotWindow(${JSON.stringify(windowId)},${JSON.stringify(path)});`);
      if (!captured) throw new Error(`${name}: capture failed`);
      let native = null;
      if (!values.baseline) {
        native = await instance.eval(`return globalThis.expo.modules.SolaraHosted.devToolbarBackdrops(${JSON.stringify(windowId)}).then(JSON.parse);`);
        const host = native.find((entry) => entry.tabId === state.id);
        if (!host || host.frame[2] <= 0 || host.frame[3] !== 41 || host.interceptsInput || !host.hairline || !!host.stripes !== developer || (!developer && host.background !== "#2471A3")) {
          throw new Error(`${name}: native backdrop state mismatch ${JSON.stringify(native)}`);
        }
      }
      evidence.push({ name, path, native, projection });
      console.log(`PASS ${name}: ${values.baseline ? "RN baseline" : "native passive backdrop"} captured`);
    }
  }
  await instance.eval(`const s=ac.store.getState();s.newTab(${JSON.stringify(windowId)});return true;`);
  await sleep(500);
  if (!values.baseline) {
    const native = await instance.eval(`return globalThis.expo.modules.SolaraHosted.devToolbarBackdrops(${JSON.stringify(windowId)}).then(JSON.parse);`);
    if (native.some((entry) => entry.hairline)) throw new Error(`blank tab divider remains: ${JSON.stringify(native)}`);
  }
  writeFileSync(join(out, "results.json"), JSON.stringify(evidence, null, 2));
} finally {
  if (instance) await instance.quit();
  await new Promise((done) => server.close(done));
}
