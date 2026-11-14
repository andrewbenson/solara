import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { isDeepStrictEqual } from "node:util";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((arg) => !arg.startsWith("--"));
if (!appArg) {
  console.error("usage: node cli-sidebar-test.mjs <Debug Solara.app> [--python=/path/to/python] [--keep-data]\n\nExercises sidebar commands through the token CLI channel, dry-run and refusal invariance, native workspace snapshots, and profile/window moves. Requires the CLI's locked Python dependencies and an engine with Solara.sidebar support.");
  process.exit(2);
}
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const python = args.find((arg) => arg.startsWith("--python="))?.slice(9) || "python3";
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-cli-sidebar-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "cli-sidebar-test.log"), { name: "cli-sidebar-test" });
const execute = promisify(execFile);
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(fixturePage(req.url.slice(1) || "sidebar"));
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = (id) => `http://127.0.0.1:${server.address().port}/${id}`;
const fixture = session({
  profiles: ["Personal", "Work"],
  windows: [{ id: "w1", activeTabIds: { default: "a" } }, { id: "w2" }],
  tabs: [..."abcdefgh"].map((id) => ({ id, url: url(id), title: id.toUpperCase() })).concat([{ id: "z", windowId: "w2", url: url("z"), title: "Z" }]),
  settings: { cliControl: true },
});

let app;
const invoke = async (words, { json = true, code = 0 } = {}) => {
  let result;
  try {
    result = await execute(python, ["-B", "-m", "solara_cli", ...words, "--data-dir", data, ...(json ? ["--json"] : [])], {
      cwd: root,
      env: { ...process.env, PYTHONPATH: join(root, "apps/cli"), PYTHONDONTWRITEBYTECODE: "1", SOLARA_CDP_URL: "", SOLARA_DATA_DIR: data },
      timeout: 15000,
      maxBuffer: 4 * 1024 * 1024,
    });
    result.code = 0;
  } catch (error) {
    result = error;
  }
  assert.equal(result.code, code, `${words.join(" ")}: ${result.stderr || result.message || result.stdout}`);
  if (code !== 0) return result.stderr;
  assert.equal(result.stderr, "", words.join(" "));
  return json ? JSON.parse(result.stdout) : result.stdout;
};
const inventory = () => invoke(["sidebar"]);
const editState = () => app.eval(`
  const s = ac.store.getState();
  return {
    windows: Object.values(s.windows).map(({ id, profileId, tabIds }) => ({ id, profileId, tabIds })),
    tabs: Object.values(s.tabs).map(({ id, windowId, profileId, customTitle, pinned, pinnedAsRow, tileFolder }) => ({ id, windowId, profileId, customTitle, pinned, pinnedAsRow, tileFolder })),
    groups: s.groups,
  };
`);
const tab = (state, id) => state.tabs.find((value) => value.id === id);
const group = (state, id) => state.groups.find((value) => value.id === id);
const folder = (state, id) => state.folders.find((value) => value.id === id);
const canonical = (state) => ({
  windows: state.windows.map(({ id, profileId, tabIds }) => ({ id, profileId, tabs: tabIds })).sort((a, b) => a.id.localeCompare(b.id)),
  tabs: state.tabs.map(({ id, windowId, profileId, pinned, groupId, folderId }) => ({ id, windowId, profileId, pinned, groupId: groupId ?? null, folderId: folderId ?? null })).sort((a, b) => a.id.localeCompare(b.id)),
});
const nativeMatches = async () => {
  const expected = await inventory();
  const deadline = Date.now() + 5000;
  let last;
  while (Date.now() < deadline) {
    if (!app.alive) throw new Error("sidebar instance exited");
    last = await app.snapshot({ tabDrag: true }, { timeout: 1000 });
    const normal = new Set(expected.windows.map((value) => value.id));
    const actual = {
      windows: last.windows.filter((value) => normal.has(value.id)).map(({ id, profileId, tabIds }) => ({ id, profileId, tabs: tabIds })).sort((a, b) => a.id.localeCompare(b.id)),
      tabs: last.tabs.filter((value) => normal.has(value.windowId)).map(({ id, windowId, profileId, pinned, tileFolderId }) => ({
        id, windowId, profileId, pinned,
        groupId: last.groups.find((value) => value.tabIds.includes(id))?.id ?? null,
        folderId: tileFolderId ?? null,
      })).sort((a, b) => a.id.localeCompare(b.id)),
    };
    if (last.consistent && isDeepStrictEqual(actual, canonical(expected))) return;
    await sleep(100);
  }
  throw new Error(`native workspace disagrees with CLI inventory: ${JSON.stringify(last)}`);
};
const mutate = async (...words) => {
  const before = await editState();
  const preview = await invoke([...words, "--dry-run"]);
  assert.equal(preview.dryRun, true);
  assert.ok(preview.changes.length > 0, "dry-run describes the edit");
  assert.deepEqual(await editState(), before, `${words.join(" ")}: dry-run changed the sidebar`);
  const result = await invoke(words);
  assert.equal(result.dryRun, false);
  await nativeMatches();
  return result;
};
const refuse = async (words, message) => {
  const before = await editState();
  for (const dry of [[], ["--dry-run"]]) {
    const error = await invoke([...words, ...dry], { code: 1 });
    assert.match(error, message);
    assert.deepEqual(await editState(), before, "refusal changed the sidebar");
  }
};

try {
  app = await launch(resolve(appArg), { data, control: true, session: fixture, onboarded: true });
  rep.log(`instance: pid ${app.pid}, data ${data}`);
  await rep.check("sidebar lists native IDs and matches the native workspace", async () => {
    const state = await inventory();
    assert.ok(tab(state, "a"));
    assert.ok(state.profiles.some((value) => value.name === "Work"));
    assert.match(await invoke(["sidebar"], { json: false }), /w1/);
    await nativeMatches();
  });
  let groupId;
  await rep.check("create, join, rename and reorder a group with dry-run before each edit", async () => {
    groupId = (await mutate("group", "create", "Research", "--color", "blue", "--tabs", "a", "b")).id;
    assert.ok(groupId);
    assert.equal(group(await inventory(), groupId).color, "blue");
    await mutate("tab", "move", "c", "--to-group", groupId);
    await mutate("group", "rename", groupId, "Reading");
    await mutate("tab", "rename", "a", "A custom title");
    await mutate("tab", "reorder", "a", "--after", "c");
    assert.deepEqual(group(await inventory(), groupId).tabIds, ["b", "c", "a"]);
    await mutate("tab", "reorder", "a", "--before", "b");
    assert.deepEqual(group(await inventory(), groupId).tabIds, ["a", "b", "c"]);
    assert.equal(tab(await inventory(), "a").title, "A custom title");
    assert.equal(group(await inventory(), groupId).name, "Reading");
  });
  let folderId;
  await rep.check("create, join, rename and dissolve a tile folder", async () => {
    folderId = (await mutate("folder", "create", "Tools", "--tabs", "d", "e")).id;
    assert.ok(folderId);
    await mutate("tab", "move", "f", "--to-folder", folderId);
    assert.deepEqual(new Set(folder(await inventory(), folderId).tabIds), new Set(["d", "e", "f"]));
    await mutate("folder", "rename", folderId, "Daily tools");
    assert.equal(folder(await inventory(), folderId).name, "Daily tools");
    await mutate("folder", "delete", folderId);
    const state = await inventory();
    assert.equal(folder(state, folderId), undefined);
    for (const id of ["d", "e", "f"]) assert.equal(tab(state, id).pinned, true);
  });
  await rep.check("pin and unpin, move window and move profile through native actions", async () => {
    await mutate("tab", "pin", "g");
    assert.equal(tab(await inventory(), "g").pinned, true);
    await mutate("tab", "unpin", "g");
    assert.equal(tab(await inventory(), "g").pinned, false);
    await mutate("tab", "move", "g", "--to-window", "w2");
    assert.equal(tab(await inventory(), "g").windowId, "w2");
    await mutate("tab", "move", "g", "--to-profile", "Work");
    const state = await inventory();
    assert.equal(tab(state, "g").profileId, state.profiles.find((value) => value.name === "Work").id);
    assert.equal(tab(state, "g").url, url("g"));
  });
  await rep.check("unknown IDs and mixed invalid bulk input are atomic errors", async () => {
    for (const words of [
      ["tab", "pin", "missing"], ["tab", "unpin", "missing"], ["tab", "rename", "missing", "No"],
      ["tab", "move", "h", "--to-group", "missing"], ["tab", "move", "h", "--to-folder", "missing"],
      ["tab", "move", "h", "--to-window", "missing"], ["tab", "move", "h", "--to-profile", "missing"],
      ["tab", "reorder", "h", "--before", "missing"], ["group", "rename", "missing", "No"],
      ["group", "delete", "missing"], ["folder", "rename", "missing", "No"], ["folder", "delete", "missing"],
      ["group", "create", "No", "--tabs", "h", "missing"], ["folder", "create", "No", "--tabs", "h", "missing"],
    ]) await refuse(words, /unknown|not found/i);
  });
  await rep.check("private tabs, profiles and windows are refused and absent from inventory", async () => {
    const privateState = await app.eval(`
      const s = ac.store.getState();
      const windowId = s.createWindow({ incognito: true, profileId: "default", url: ${JSON.stringify(url("private"))} });
      const w = ac.store.getState().windows[windowId];
      return { windowId, profileId: w.profileId, tabId: w.tabIds[0] };
    `);
    assert.ok(privateState.tabId);
    const state = await inventory();
    assert.equal(tab(state, privateState.tabId), undefined);
    assert.ok(!state.windows.some((value) => value.id === privateState.windowId));
    for (const words of [
      ["tab", "pin", privateState.tabId], ["tab", "rename", privateState.tabId, "No"],
      ["tab", "move", "h", "--to-window", privateState.windowId],
      ["tab", "move", "h", "--to-profile", privateState.profileId],
      ["group", "create", "No", "--tabs", "h", privateState.tabId],
      ["folder", "create", "No", "--window", privateState.windowId],
    ]) await refuse(words, /private|incognito/i);
  });
  await rep.check("group delete closes its tabs using the native delete action", async () => {
    await mutate("group", "delete", groupId);
    const state = await inventory();
    assert.equal(group(state, groupId), undefined);
    for (const id of ["a", "b", "c"]) assert.equal(tab(state, id), undefined);
  });
  await rep.check("control off prevents sidebar edits", async () => {
    await app.eval('ac.store.getState().updateSettings({ cliControl: false }); return true;');
    const deadline = Date.now() + 5000;
    while (existsSync(join(data, "Chromium", "SolaraControl.json")) && Date.now() < deadline) {
      if (!app.alive) throw new Error("sidebar instance exited");
      await sleep(100);
    }
    assert.equal(existsSync(join(data, "Chromium", "SolaraControl.json")), false, "token control did not stop");
    const stderr = await invoke(["tab", "rename", "h", "No"], { code: 2 });
    assert.match(stderr, /isn't running|control|off/i);
    assert.notEqual(await app.eval('return ac.store.getState().tabs.h.customTitle;'), "No");
  });
} finally {
  await app?.quit();
  await new Promise((done) => server.close(done));
  if (!keep) rmSync(data, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);
