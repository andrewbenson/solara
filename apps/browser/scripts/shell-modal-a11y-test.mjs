import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node shell-modal-a11y-test.mjs <Debug Solara.app> [--keep-data]

What the accessibility tree reaches in a shell window (SOLARA_NATIVE_SHELL=1 with the main root on top, the pool and
the pane roots) while the main root shows a modal. The shell's WindowShellAccessibility walks the window's
accessibilityChildren the way VoiceOver does and counts the elements by the shell layer they live in. At rest and in a
split the card's native layers (and the native sidebar's, when it is on) are reachable; in a split the main root has
nothing to reach. With the command panel up only the main root and the native command bar in the shell's overlay are,
with the Bookmark All Tabs dialog only the main root, and closing the panel brings the card back. Without the shell
switch, the sampler answers null.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const app = resolve(appArg);
const scratch = mkdtempSync(join(tmpdir(), "ac-shell-modal-a11y-"));
const rep = reporter(join(scratch, "shell-modal-a11y-test.log"), { name: "shell-modal-a11y-test" });
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${req.url}</title><link rel="icon" href="data:,"><body><button>Inside the page</button></body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [
    { id: "a", url: `${base}/a`, title: "A" },
    { id: "b", url: `${base}/b`, title: "B" },
  ],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});
const SHELL = { SOLARA_NATIVE_SHELL: "1", SOLARA_SHELL_MAIN_TOP: "1", SOLARA_SHELL_PANES: "1", SOLARA_NATIVE_PAGES_POOL: "1" };
const layersOf = (reach) => Object.keys(reach ?? {}).filter((k) => !k.startsWith("outside:") && k !== "truncated");

let instance = null;
try {
  for (const leg of ["shell", "rn"]) {
    instance = await launch(app, { data: join(scratch, `data-${leg}`), fresh: true, session: fixture, onboarded: true, env: leg === "shell" ? SHELL : { SOLARA_NATIVE_SHELL: "0" } });
    const run = (body) => instance.eval(body, { timeout: 20000 });
    const reach = () => run(`return globalThis.expo.modules.SolaraWindowShell.accessibilityReach("w1")`);
    const settle = () => sleep(1200);
    const untilSnapshot = async (what, accept, ms = 5000) => {
      const end = Date.now() + ms;
      let last;
      while (Date.now() < end) {
        last = await instance.snapshot({ windowId: "w1" }).catch((error) => ({ error: error.message }));
        if (!last.error && accept(last)) return last;
        await sleep(100);
      }
      throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
    };
    const end = Date.now() + 15000;
    while (Date.now() < end && !(await run(`return ac.store.getState().tabs.a?.title === "/a"`).catch(() => false))) await sleep(200);
    await settle();
    if (leg === "rn") {
      await rep.check("rn: no shell, no sampler", async () => {
        const got = await reach();
        if (got !== null) throw new Error(`expected null without the shell, got ${JSON.stringify(got)}`);
        return got;
      });
      break;
    }
    const expectLayers = (name, act, want) =>
      rep.check(name, async () => {
        if (act) await run(act);
        await settle();
        const got = await reach();
        const layers = layersOf(got).sort();
        if (JSON.stringify(layers) !== JSON.stringify([...want].sort())) throw new Error(`reached ${JSON.stringify(got)}, want only ${want.join(", ")}`);
        const nativeLayers = (state) => layersOf(state.windows.find((window) => window.id === "w1")?.accessibilityLayers).sort();
        const snapshot = await untilSnapshot(name, (state) => JSON.stringify(nativeLayers(state)) === JSON.stringify(layers));
        if (JSON.stringify(nativeLayers(snapshot)) !== JSON.stringify(layers)) throw new Error(`native reached ${JSON.stringify(nativeLayers(snapshot))}, JS reached ${JSON.stringify(layers)}`);
        return got;
      });
    const sidebar = (await run(`return globalThis.expo.modules.SolaraHosted.sidebarShell("w1")`)) !== "null" ? ["sidebar"] : [];
    await expectLayers("rest: the card is reachable", null, ["react", "card", "titlebar", ...sidebar]);
    await expectLayers("command panel: only the main root and the native bar", `ac.store.getState().openPanel("w1"); return true`, ["react", "overlay"]);
    await expectLayers("panel closed: the card is back", `ac.store.getState().closePanel("w1"); return true`, ["react", "card", "titlebar", ...sidebar]);
    await expectLayers("split: the split panes are reachable", `ac.store.getState().createSplit(["a", "b"]); return true`, ["card", "titlebar", ...sidebar]);
    await expectLayers("split under the command panel: only the native bar", `ac.store.getState().openPanel("w1"); return true`, ["overlay"]);
    await expectLayers("split, panel closed: the panes are back", `ac.store.getState().closePanel("w1"); return true`, ["card", "titlebar", ...sidebar]);
    await expectLayers("Bookmark All Tabs dialog: only the main root", `ac.runCommand({ command: "bookmarkAllTabs", windowId: "w1" }); return true`, ["react"]);
    await instance.quit().catch(() => {});
    instance = null;
  }
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await instance?.quit().catch(() => {});
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
