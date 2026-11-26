import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, scratchArg] = process.argv.slice(2);
if (!appArg || !scratchArg || resolve(appArg).startsWith("/Applications/")) throw new Error("usage: node extension-search-refresh-test.mjs <Debug app> <scratch>");
const scratch = resolve(scratchArg);
mkdirSync(scratch, { recursive: true });
const rep = reporter(join(scratch, "extension-search-refresh.log"), { name: "extension-search-refresh" });
const directory = join(scratch, "extension");
mkdirSync(directory, { recursive: true });
writeFileSync(join(directory, "manifest.json"), JSON.stringify({
  manifest_version: 3, name: "Row 3 Search", version: "1.0",
  chrome_settings_overrides: { search_provider: {
    name: "Row 3 Search", keyword: "row3", search_url: "https://example.test/search?q={searchTerms}",
    favicon_url: "https://example.test/favicon.ico", encoding: "UTF-8", is_default: false,
  } },
}));
const retained = { profile: "work", extensionId: "retained", extensionName: "Retained", name: "Retained", keyword: "retained", url: "https://example.test/%s", isDefault: false };
let app;
let id;
const run = (body) => app.eval(body, { timeout: 5000 });
const state = () => run(`
  const module = expo.modules.SolaraStoreAdapter;
  const status = module.status();
  if (!status.active || status.frozen !== false) throw new Error("native workspace ownership required");
  return JSON.parse(module.snapshot()).data.settings.extensionSearchEngines ?? [];
`);
const until = async (name, accept) => {
  const deadline = Date.now() + 8000;
  let last;
  while (Date.now() < deadline) {
    if (!app.alive) throw new Error(`${name}: app exited`);
    last = await state();
    if (accept(last)) return last;
    await sleep(80);
  }
  throw new Error(`${name}: timed out ${JSON.stringify(last)}`);
};
try {
  app = await launch(resolve(appArg), { data: join(scratch, "data"), fresh: true, onboarded: true, probe: true,
    session: session({ tabs: [{ id: "a", url: "about:blank" }], settings: { extensionSearchEngines: [retained] } }),
    ready: 'return !!ac.store.getState().windows.w1 && !!ac.extensions;' });
  await run(`
    const state = ac.store.getState();
    globalThis.__row3SettingsWriter = state.updateSettings;
    globalThis.__row3SearchWrites = 0;
    state.updateSettings = (patch, ...args) => {
      if ("extensionSearchEngines" in patch) {
        globalThis.__row3SearchWrites++;
        throw new Error("extension search must be written in Swift");
      }
      return globalThis.__row3SettingsWriter(patch, ...args);
    };
    return true;
  `);
  await rep.check("native-install-refresh", async () => {
    const installed = await run(`return expo.modules.SolaraExtensions.install(${JSON.stringify(directory)}, "");`);
    assert.ok(installed?.id && !installed.error, JSON.stringify(installed));
    id = installed.id;
    await run('return expo.modules.SolaraExtensions.list("");');
    const rows = await until("native search engine", (rows) => rows.some((row) => row.extensionId === id));
    const row = rows.find((row) => row.extensionId === id);
    assert.equal(row.profile, "");
    assert.ok(row.url.includes("%s"));
    assert.deepEqual(rows.find((row) => row.profile === "work"), retained);
  });
  await rep.check("native-disable-and-enable", async () => {
    assert.ok(id, "install check must succeed");
    await run(`return expo.modules.SolaraExtensions.setEnabled(${JSON.stringify(id)}, "", false);`);
    await run('return expo.modules.SolaraExtensions.list("");');
    await until("disabled search removed", (rows) => !rows.some((row) => row.extensionId === id));
    await run(`return expo.modules.SolaraExtensions.setEnabled(${JSON.stringify(id)}, "", true);`);
    await run('return expo.modules.SolaraExtensions.list("");');
    await until("enabled search restored", (rows) => rows.some((row) => row.extensionId === id));
  });
  await rep.check("native-uninstall-keeps-other-profile", async () => {
    assert.ok(id, "install check must succeed");
    await run(`return expo.modules.SolaraExtensions.uninstall(${JSON.stringify(id)}, "");`);
    await run('return expo.modules.SolaraExtensions.list("");');
    const rows = await until("uninstalled search removed", (rows) => !rows.some((row) => row.extensionId === id));
    assert.deepEqual(rows.find((row) => row.profile === "work"), retained);
    assert.equal(await run('return globalThis.__row3SearchWrites;'), 0);
  });
} finally {
  if (app) {
    await run('if (globalThis.__row3SettingsWriter) ac.store.getState().updateSettings = globalThis.__row3SettingsWriter; return true;').catch(() => null);
    if (id) await run(`return expo.modules.SolaraExtensions.uninstall(${JSON.stringify(id)}, "");`).catch(() => null);
    await app.quit();
  }
}
process.exitCode = rep.summary() ? 0 : 1;
