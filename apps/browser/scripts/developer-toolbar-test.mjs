const HELP = `Checks the Developer Mode toolbar and its edit-in-place.

  node apps/browser/scripts/developer-toolbar-test.mjs <Debug Solara.app> [--keep DIR]

A hidden instance on a page served from 127.0.0.1, which is in Developer Mode by default. For light and dark it snapshots the window at rest and with the URL being
edited (⌘L), and checks:
  - Chromium's level for the loopback page is NONE and the field shows no red not-secure badge;
  - the URL's ink box doesn't move (1 px at 2x) when editing starts;
  - ⌘L opens no command bar, typed text and Return navigate the tab, Escape leaves the URL as it was.
Exits 1 on any failure.`;

import { mkdtempSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inflateSync } from "node:zlib";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";
import { developerPage } from "../../../scripts/lib/fixture-html.mjs";

const argv = process.argv.slice(2);
if (!argv.length || argv.includes("-h") || argv.includes("--help")) {
  console.log(HELP);
  process.exit(argv.length ? 0 : 2);
}
const app = resolve(argv[0]);
const scratch = argv.includes("--keep") ? resolve(argv[argv.indexOf("--keep") + 1]) : mkdtempSync(join(tmpdir(), "ac-developer-toolbar-"));

function readPng(path) {
  const buf = readFileSync(path);
  let width = 0, height = 0, channels = 4;
  const idat = [];
  for (let at = 8; at < buf.length; ) {
    const length = buf.readUInt32BE(at), type = buf.toString("ascii", at + 4, at + 8);
    if (type === "IHDR") {
      width = buf.readUInt32BE(at + 8);
      height = buf.readUInt32BE(at + 12);
      channels = { 2: 3, 6: 4 }[buf[at + 17]];
    } else if (type === "IDAT") idat.push(buf.subarray(at + 8, at + 8 + length));
    at += 12 + length;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const data = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const v = raw[y * (stride + 1) + 1 + x];
      const a = x >= channels ? data[y * stride + x - channels] : 0;
      const b = y ? data[(y - 1) * stride + x] : 0;
      const c = x >= channels && y ? data[(y - 1) * stride + x - channels] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter];
      data[y * stride + x] = (v + pred) & 255;
    }
  }
  return { width, height, channels, data };
}

const rgb = (png, x, y) => {
  const i = (y * png.width + x) * png.channels;
  return [png.data[i], png.data[i + 1], png.data[i + 2]];
};
const lum = ([r, g, b]) => (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;

function inkBox(png, dark, [x0, y0, x1, y1]) {
  let left = Infinity, right = -1, top = Infinity, bottom = -1;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const c = rgb(png, x, y);
    if (Math.max(...c) - Math.min(...c) < 40 && (dark ? lum(c) > 0.6 : lum(c) < 0.45)) {
      left = Math.min(left, x); right = Math.max(right, x); top = Math.min(top, y); bottom = Math.max(bottom, y);
    }
  }
  return right < 0 ? null : { left, right, top, bottom };
}

function redPixels(png, [x0, y0, x1, y1]) {
  let n = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const [r, g, b] = rgb(png, x, y);
    if (r > 200 && g < 120 && b < 120) n++;
  }
  return n;
}

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(developerPage(req.url));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

const results = {};
let failed = 0;
const check = (name, ok, detail) => {
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? `  (${detail})` : ""}`);
};

for (const side of ["native"]) {
  const instance = await launch(app, { data: join(scratch, `data-${side}`), fresh: true, onboarded: true });
  const inApp = (body) => instance.eval(body, { timeout: 30000 });
  const untilSnapshot = async (what, accept, ms = 5000) => {
    const end = Date.now() + ms;
    let last;
    while (Date.now() < end) {
      last = await instance.snapshot().catch((error) => ({ error: error.message }));
      if (!last.error && accept(last)) return last;
      await sleep(100);
    }
    throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
  };
  try {
    const w = await inApp(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; s.setWindowFrame(w, [80, 80, 1280, 800]); return w;`);
    for (const appearance of ["light", "dark"]) {
      const shots = { rest: join(scratch, `${side}-${appearance}-rest.png`), edit: join(scratch, `${side}-${appearance}-edit.png`) };
      const r = await inApp(`
        const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
        const s = ac.store.getState(), w = ${JSON.stringify(w)};
        s.closePanel(w);
        s.updateSettings({ appearance: ${JSON.stringify(appearance)} });
        s.newTab(w, { url: ${JSON.stringify(`${base}/some/path?x=1`)} });
        let level = null;
        return sleep(3000)
          .then(() => {
            const st = ac.store.getState(), win = st.windows[w];
            level = ac.pageState.getState().pages[win.activeTabIds[win.profileId]]?.security?.chromium ?? null;
            return ac.shell.devSnapshotWindow(w, ${JSON.stringify(shots.rest)});
          })
          .then(() => ac.runCommand({ command: "focusCommandBar", arg: null, windowId: w }))
          .then(() => sleep(900))
          .then(() => ac.shell.devSnapshotWindow(w, ${JSON.stringify(shots.edit)}))
          .then(() => ({ level, panel: ac.store.getState().windowUi[w].panel.open, frame: ac.store.getState().windows[w].frame }));`);
      await inApp(`return ac.shell.devTypeKeys(${JSON.stringify(w)}, "\\u001b", 20).then(() => new Promise((r) => setTimeout(r, 400))).then(() => 1);`);
      const rest = readPng(shots.rest), edit = readPng(shots.edit);
      const scale = Math.round(rest.width / r.frame[2]);
      const field = [Math.round(336 * scale), Math.round(10 * scale), Math.round(rest.width - 200 * scale), Math.round(42 * scale)];
      const dark = appearance === "dark";
      results[`${side}-${appearance}`] = {
        rest: inkBox(rest, dark, field), edit: inkBox(edit, dark, field), red: redPixels(rest, field), level: r.level, panel: r.panel,
        row: [5, 44].flatMap((y) => Array.from({ length: rest.width }, (_, x) => rgb(rest, x, Math.round(y * scale)).join(","))),
      };
    }
    const edits = await inApp(`
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const s = ac.store.getState(), w = ${JSON.stringify(w)};
      const url = () => { const st = ac.store.getState(), win = st.windows[w]; return st.tabs[win.activeTabIds[win.profileId]].url; };
      const cmdL = () => ac.runCommand({ command: "focusCommandBar", arg: null, windowId: w });
      cmdL();
      return sleep(800)
        .then(() => ac.shell.devTypeKeys(w, ${JSON.stringify(`${base}/other\r`)}, 20))
        .then(() => sleep(2000))
        .then(() => { const went = url(); cmdL(); return sleep(800).then(() => ac.shell.devTypeKeys(w, "junk\\u001b", 20)).then(() => sleep(800)).then(() => ({ went, kept: url(), panel: ac.store.getState().windowUi[w].panel.open })); });`);
    results[`${side}-edits`] = edits;
    const snapshot = await untilSnapshot("the edited URL", (state) => state.windows.some((window) => window.id === w &&
      state.tabs.some((tab) => tab.id === window.selectedTabId && tab.url === edits.kept)));
    const selected = snapshot.windows.find((window) => window.id === w)?.selectedTabId;
    results[`${side}-native-url`] = snapshot.tabs.find((tab) => tab.id === selected)?.url;
  } finally {
    await instance.quit();
  }
}
server.close();

const near = (a, b) => !!a && !!b && ["left", "right", "top", "bottom"].every((k) => Math.abs(a[k] - b[k]) <= 1);
const box = (b) => (b ? `${b.left}-${b.right} × ${b.top}-${b.bottom}` : "none");
for (const appearance of ["light", "dark"]) {
  const nat = results[`native-${appearance}`];
  check(`${appearance}: loopback is Chromium's NONE and shows no not-secure badge`, nat.level === "none" && nat.red === 0, `level ${nat.level}, red px ${nat.red}`);
  check(`${appearance}: the URL doesn't move when editing starts`, near(nat.edit, nat.rest), `rest ${box(nat.rest)}, edit ${box(nat.edit)}`);
  check(`${appearance}: ⌘L edits in place, no command bar`, !nat.panel, `panel ${nat.panel}`);
}
const e = results["native-edits"];
check("Return goes to the typed URL, Escape keeps it", e.went.endsWith("/other") && e.kept === e.went && !e.panel, JSON.stringify(e).replace(base, ""));
check("native snapshot keeps the selected tab at the edited URL", results["native-native-url"] === e.kept,
  `native ${results["native-native-url"]}, JS ${e.kept}`);
console.log(failed ? `${failed} failed (snapshots in ${scratch})` : "all pass");
process.exit(failed ? 1 : 0);
