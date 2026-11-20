import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";

const usage = "usage: node --import ./src/test-loader.mjs scripts/native/record-command-routes.mjs <git revision with the original runCommand>";
const revision = process.argv[2];
if (!revision || revision.startsWith("-")) {
  console.error(usage);
  process.exit(2);
}

const app = new URL("../../", import.meta.url);
const repo = new URL("../../", app);
const COMMANDS = new URL("src/lib/commands.ts", app).href;
const PEEK = new URL("src/components/peek/actions.ts", app).href;
const FIXTURE = new URL("native/SolaraKit/Tests/SolaraStoreTests/Cases/command-routes.json", repo);
const TAG = "?originalRoute";
const KEEP = [new URL("src/store/", app).href, new URL("src/lib/commandCatalog.ts", app).href, new URL("src/components/settings/windows.ts", app).href];

const original = (url) => execFileSync("git", ["-C", fileURLToPath(repo), "show", `${revision}:${fileURLToPath(url).slice(fileURLToPath(repo).length)}`], { encoding: "utf8" });

function replaceOnce(source, from, to, where) {
  const count = source.split(from).length - 1;
  if (count !== 1) throw new Error(`${where}: expected one ${JSON.stringify(from.slice(0, 60))}, found ${count}`);
  return source.replace(from, to);
}

function between(source, start, end) {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a);
  if (a < 0 || b < 0) throw new Error(`missing block ${start}`);
  return [a, b];
}

function caseLabels(block) {
  return [...block.matchAll(/case "(\w+)":/g)].map((m) => m[1]);
}

function probeCases(source, start, end, probe) {
  const [a, b] = between(source, start, end);
  const block = source.slice(a, b).replace(/case "(\w+)":/g, (whole) => `${whole} ${probe}`);
  return source.slice(0, a) + block + source.slice(b);
}

const probe = 'const __rec = (kind, windowId, tabId) => { throw { route: { kind, windowId: windowId ?? null, focusWindow: globalThis.__routeFocus ?? null, tabId: tabId || null } }; };\n';

function instrumentCommands(source) {
  let out = source;
  out = replaceOnce(out, 'if (command === "closeTab") return void closeNativeWindow(requested!);', 'if (command === "closeTab") return __rec("utilityClose", requested);', "utility close");
  out = replaceOnce(out, "return focusSettingsSearch();", 'return __rec("settingsSearch", requested);', "settings search");
  out = probeCases(out, "function runLittleSolaraCommand(", "\n}\n", '__rec("littleSolara", windowId);');
  out = probeCases(out, '  switch (command) {\n    case "newWindow":', "\n  const invokedFrom = requested;", '__rec("window", requested);');
  out = replaceOnce(out, "if (requested) focus(requested);", "if (requested) globalThis.__routeFocus = requested;", "redirect focus");
  out = replaceOnce(out, "const target = resolveWindowId(s, invokedFrom) ?? null;", 'const target = resolveWindowId(s, invokedFrom) ?? null;\n    __rec("invoker", target);', "folder commands");
  out = replaceOnce(out, "  if (!windowId) {\n", '  if (!windowId) {\n    __rec("noWindow", null);\n', "no window");
  out = replaceOnce(out, "peekTabId(s, windowId)) || activeTabId(s, windowId);\n", 'peekTabId(s, windowId)) || activeTabId(s, windowId);\n  __rec("main", windowId, tabId);\n', "main route");
  return probe + out;
}

function instrumentPeek(source) {
  let out = source;
  out = replaceOnce(out, "    openPeekAsTab(windowId);\n    return true;", '    return __rec("peekPromote", windowId, peek.tabId);', "peek promote");
  out = replaceOnce(out, "  if (s.find[peek.tabId]?.open) {\n", '  if (s.find[peek.tabId]?.open) {\n    __rec("peekCloseFind", windowId, peek.tabId);\n', "peek close find");
  out = replaceOnce(out, "  } else dismissPeek(windowId);", '  } else __rec("peekDismiss", windowId, peek.tabId);', "peek dismiss");
  return probe + out;
}

function importedNames(source, specifier) {
  const names = new Set();
  for (const m of source.matchAll(/import\s*\{([^}]*)\}\s*from\s*"([^"]+)"/g)) {
    if (m[2] !== specifier) continue;
    for (const part of m[1].split(",").map((p) => p.trim()).filter(Boolean)) {
      if (part.startsWith("type ")) continue;
      names.add(part.split(/\s+as\s+/)[0].trim());
    }
  }
  return [...names];
}

const keptPaths = ["apps/browser/src/store", "apps/browser/src/lib/commandCatalog.ts", "apps/browser/src/components/settings/windows.ts"];
const drift = execFileSync("git", ["-C", fileURLToPath(repo), "diff", "--name-only", revision, "--", ...keptPaths], { encoding: "utf8" }).trim();
if (drift) {
  console.error(`the store helpers differ from ${revision}, so the original routing can't be replayed against them:\n${drift}`);
  process.exit(1);
}

const sources = new Map([
  [COMMANDS, instrumentCommands(original(new URL(COMMANDS)))],
  [PEEK, instrumentPeek(original(new URL(PEEK)))],
]);

registerHooks({
  resolve(specifier, context, next) {
    const parent = context.parentURL ?? "";
    if (!parent.endsWith(TAG)) return next(specifier, context);
    const plainParent = parent.slice(0, -TAG.length);
    const resolved = next(specifier, { ...context, parentURL: plainParent });
    if (resolved.url === PEEK) return { url: PEEK + TAG, shortCircuit: true };
    if (KEEP.some((prefix) => resolved.url.startsWith(prefix))) return resolved;
    const names = importedNames(sources.get(plainParent), specifier);
    const stub = names.map((n) => `export const ${n} = () => { throw new Error("stub ${n} called"); };`).join("\n");
    return { url: `data:text/javascript,${encodeURIComponent(stub)}`, shortCircuit: true };
  },
  load(url, context, next) {
    if (url.endsWith(TAG)) return { format: "module-typescript", source: sources.get(url.slice(0, -TAG.length)), shortCircuit: true };
    return next(url, context);
  },
});

const { runCommand } = await import(COMMANDS + TAG);
const { LITTLE_SOLARA_PAGE_COMMANDS } = await import("../../src/lib/commandCatalog.ts");
const { SCENES, play, symbolic } = await import("./command-route-scenes.mjs");

function originalRoute(scene, windowId) {
  globalThis.__routeFocus = null;
  try {
    runCommand({ command: scene.command, arg: scene.arg, windowId });
  } catch (thrown) {
    if (thrown?.route) return thrown.route;
    throw thrown;
  }
  throw new Error(`${scene.name}: the original runCommand reached no route probe`);
}

const commandsSource = original(new URL(COMMANDS));
const littleSolara = caseLabels(commandsSource.slice(...between(commandsSource, "function runLittleSolaraCommand(", "\n}\n")));
const windowLevel = caseLabels(commandsSource.slice(...between(commandsSource, '  switch (command) {\n    case "newWindow":', "\n  const invokedFrom = requested;")));
const sorted = (xs) => [...new Set(xs)].sort();

const cases = [];
const wrong = [];
for (const scene of SCENES) {
  const played = play(scene, originalRoute);
  const got = symbolic(played.route, played.roles);
  if (JSON.stringify(got) !== JSON.stringify(scene.expect)) wrong.push(`${scene.name}: original ${JSON.stringify(got)}, scene expects ${JSON.stringify(scene.expect)}`);
  cases.push(played);
}
if (wrong.length) {
  console.error(wrong.join("\n"));
  process.exit(1);
}

const document = {
  format: 1,
  provenance: {
    recorder: "apps/browser/scripts/native/record-command-routes.mjs",
    revision: execFileSync("git", ["-C", fileURLToPath(repo), "rev-parse", "--short", revision], { encoding: "utf8" }).trim(),
    from: "apps/browser/src/lib/commands.ts runCommand and components/peek/actions.ts runPeekCommand at that revision, probed at each route's first effect",
  },
  littleSolaraPageCommands: sorted(LITTLE_SOLARA_PAGE_COMMANDS),
  littleSolaraCommands: sorted(littleSolara),
  windowLevelCommands: sorted(windowLevel),
  invokerCommands: sorted([...commandsSource.match(/if \(command === "(\w+)" \|\| command === "(\w+)"\) \{\n    const target = resolveWindowId\(s, invokedFrom\)/).slice(1)]),
  utilityWindowIds: sorted([...original(new URL("src/components/settings/windows.ts", app)).matchAll(/export const (?:SETTINGS|IMPORT)_WINDOW_ID = "(\w+)";/g)].map((m) => m[1])),
  cases,
};
writeFileSync(FIXTURE, JSON.stringify(document, null, 1) + "\n");
console.log(`${cases.length} cases from ${document.provenance.revision} written to ${fileURLToPath(FIXTURE)}`);
