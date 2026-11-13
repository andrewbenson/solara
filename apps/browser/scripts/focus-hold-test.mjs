import { mkdtempSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

const appArg = process.argv.slice(2).find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node focus-hold-test.mjs <Debug Solara.app>

A tab switch then ⌘L or ⌘F 0, 30 and 80 ms later, with the leaving page focused: the address field or the find field
keeps the focus. A tab switch holds the leaving page up until the incoming one draws (TabViewPool); when the leaving page
had focus, the incoming page takes it a turn later, but never after the app has moved it to a field. The switch goes
through the store, as ⌃Tab's switcher commits it (the switcher itself selects on ⌃ release, which a synthetic key press
can't give).`);
  process.exit(2);
}
const server = createServer((req, res) => {
  const n = Number((/\/p(\d+)/.exec(req.url) ?? [])[1] ?? 0);
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>p${n}</title><body style="margin:0;background:#${n ? "1e8449" : "2471a3"};height:3000px"><input id="f"><h1>page ${n}</h1></body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const scratch = mkdtempSync(join(tmpdir(), "ac-focus-hold-"));
const instance = await launch(resolve(appArg), { data: join(scratch, "data"), fresh: true, onboarded: true, ready: "return !!ac.shell.devKeyEquivalent" });
const run = (body, timeout = 30000) => instance.eval(body, { timeout });
const out = { checks: [] };
let failed = 0;
try {
  const w = await run(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; s.setWindowFrame(w, [60, 60, 1200, 800]); return w;`);
  const tabs = [];
  for (let i = 0; i < 2; i++) {
    tabs.push(await run(`const s = ac.store.getState(); s.newTab(${JSON.stringify(w)}, { url: ${JSON.stringify(`${base}/p${i}`)} });
      return new Promise((r) => setTimeout(r, 1500)).then(() => { const st = ac.store.getState(); return st.windows[${JSON.stringify(w)}].activeTabIds[st.windows[${JSON.stringify(w)}].profileId]; });`));
  }
  const keys = [["⌘L", { key: "l", keyCode: 37, modifiers: ["command"] }], ["⌘F", { key: "f", keyCode: 3, modifiers: ["command"] }]];
  let at = 1;
  for (const [name, key] of keys) {
    for (let round = 0; round < 3; round++) {
      const from = tabs[at], to = tabs[1 - at];
      await run(`ac.store.getState().activate(${JSON.stringify(from)}); return 1;`);
      await sleep(700);
      await run(`ac.store.getState().closePanel?.(${JSON.stringify(w)}); return 1;`).catch(() => 0);
      await run(`return ac.shell.devKeyEquivalent(${JSON.stringify(w)}, { key: "\\u0000", keyCode: 0, modifiers: [], focus: "page", dry: true, wait: 50 });`);
      await sleep(300);
      const delay = [0, 30, 80][round];
      const r = await run(`ac.store.getState().activate(${JSON.stringify(to)});
        return new Promise((r) => setTimeout(r, ${delay})).then(() => ac.shell.devKeyEquivalent(${JSON.stringify(w)}, { ...${JSON.stringify(key)}, asKey: true, wait: 450 }));`);
      await sleep(400);
      const later = await run(`return ac.shell.devKeyEquivalent(${JSON.stringify(w)}, { key: "\\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 });`);
      const responder = later.firstResponder;
      const ok = r.handledBy !== "none" && responder !== "RenderWidgetHostViewCocoa" && r.firstResponderAfter !== "RenderWidgetHostViewCocoa";
      if (!ok) failed++;
      out.checks.push({ name, delay, ok, handledBy: r.handledBy, before: r.firstResponder, after: r.firstResponderAfter, later: responder });
      console.log(`${ok ? "PASS" : "FAIL"} switch then ${name} ${delay} ms after the switch: handled by ${r.handledBy}, first responder ${r.firstResponder} → ${r.firstResponderAfter} → ${responder}`);
      await run(`ac.store.getState().closePanel?.(${JSON.stringify(w)}); return 1;`).catch(() => 0);
      await run(`return ac.shell.devKeyEquivalent(${JSON.stringify(w)}, { key: "\\u001b", keyCode: 53, modifiers: [], asKey: true, wait: 200 });`).catch(() => 0);
      at = 1 - at;
    }
  }
} catch (error) {
  out.error = String(error?.stack ?? error);
  failed++;
  console.log(out.error);
} finally {
  await instance.quit();
  server.close();
}
console.log(failed ? `${failed} failed` : `${out.checks.length}/${out.checks.length} passed`);
process.exit(failed ? 1 : 0);
