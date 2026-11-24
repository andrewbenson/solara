import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const flags = ["DEBUG", "SOLARA_PROBES", "SOLARA_PERF_TRACE"];
const emitter = new Set(["addListener", "removeListeners", "removeAllListeners", "emit"]);
const allowances = new Map([
  ["SolaraSettings.devLiveSnapshot", "Unused diagnostic wrapper for external development drivers"],
  ["SolaraSettings.devHistorySnapshot", "Unused history diagnostic wrapper for external development drivers"],
  ["SolaraSettings.devBookmarksSnapshot", "Unused bookmark diagnostic wrapper for external development drivers"],
  ["SolaraSettings.devFaviconLookup", "Unused favicon diagnostic wrapper for external development drivers"],
]);

function files(dir) {
  return readdirSync(resolve(root, dir), { withFileTypes: true }).flatMap((entry) => {
    const path = `${dir}/${entry.name}`;
    return entry.isDirectory() ? files(path) : entry.isFile() ? [path] : [];
  });
}

function tokens(source) {
  const pattern = /\/\/[^\n]*|\/\*[\s\S]*?\*\/|"""[\s\S]*?"""|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|^[ \t]*#(?:if|elseif|else|endif)\b[^\n]*|[A-Za-z_$][\w$]*|\?\.|&&|\|\||=>|[^\s]/gm;
  let line = 1;
  let end = 0;
  const result = [];
  for (const match of source.matchAll(pattern)) {
    line += source.slice(end, match.index).split("\n").length - 1;
    if (!match[0].startsWith("//") && !match[0].startsWith("/*")) result.push({ value: match[0].trim(), line });
    line += match[0].split("\n").length - 1;
    end = match.index + match[0].length;
  }
  return result;
}

function evaluate(expression, enabled) {
  const parts = expression.match(/&&|\|\||!|\(|\)|[A-Za-z_][\w]*|\S/g) ?? [];
  let at = 0;
  function atom() {
    const token = parts[at++];
    if (token === "!") return !atom();
    if (token === "(") {
      const value = or();
      assert.equal(parts[at++], ")", `Unsupported Swift condition: ${expression}`);
      return value;
    }
    assert.ok(flags.includes(token) || token === "true" || token === "false", `Unsupported Swift condition: ${expression}`);
    return token === "true" || enabled.has(token);
  }
  function and() {
    let value = atom();
    while (parts[at] === "&&") {
      at++;
      const rhs = atom();
      value = value && rhs;
    }
    return value;
  }
  function or() {
    let value = and();
    while (parts[at] === "||") {
      at++;
      const rhs = and();
      value = value || rhs;
    }
    return value;
  }
  const value = or();
  assert.equal(at, parts.length, `Unsupported Swift condition: ${expression}`);
  return value;
}

function swiftExports(sources) {
  const modules = new Map();
  for (const [file, source] of sources) {
    if (!/\bModuleDefinition\b/.test(source)) continue;
    const input = tokens(source);
    const stack = [];
    let depth = 0;
    let pending = false;
    let definition = null;
    for (let i = 0; i < input.length; i++) {
      const { value, line } = input[i];
      if (/^#(if|elseif|else|endif)\b/.test(value)) {
        const [, directive, expression] = value.replace(/\/\/.*$/, "").trim().match(/^#(if|elseif|else|endif)\b\s*(.*)$/);
        if (definition && (directive === "if" || directive === "elseif")) evaluate(expression, new Set());
        if (directive === "if") stack.push({ previous: [expression], current: expression, otherwise: false });
        else {
          const branch = stack.at(-1);
          assert.ok(branch, `${file}:${line}: unmatched ${value}`);
          if (directive === "endif") stack.pop();
          else {
            assert.ok(!branch.otherwise, `${file}:${line}: branch after #else`);
            branch.current = `!(${branch.previous.map((x) => `(${x})`).join(" || ")})`;
            if (directive === "elseif") {
              branch.current += ` && (${expression})`;
              branch.previous.push(expression);
            } else branch.otherwise = true;
          }
        }
        continue;
      }
      if (value === "ModuleDefinition") pending = true;
      if (value === "{") {
        depth++;
        if (pending) {
          definition = { depth, name: null, exports: [] };
          pending = false;
        }
      }
      if (definition && depth === definition.depth && ["Name", "Function", "AsyncFunction", "Property", "Constant", "Events"].includes(value) && input[i + 1]?.value === "(") {
        const condition = stack.map((b) => `(${b.current})`).join(" && ") || "true";
        const release = evaluate(condition, new Set());
        const possible = Array.from({ length: 8 }, (_, mask) => new Set(flags.filter((_, bit) => mask & (1 << bit)))).some((enabled) => evaluate(condition, enabled));
        const names = [];
        let end = i + 2;
        if (value !== "Events") {
          assert.match(input[end]?.value ?? "", /^"[^"\\]*"$/, `${file}:${line}: unsupported ${value} name`);
          names.push(input[end].value.slice(1, -1));
        } else for (; input[end]?.value !== ")"; end++) {
          assert.ok(input[end], `${file}:${line}: unclosed ${value}`);
          if (/^"[^"\\]*"$/.test(input[end].value)) names.push(input[end].value.slice(1, -1));
          else assert.equal(input[end].value, ",", `${file}:${line}: unsupported ${value} argument`);
        }
        assert.ok(names.length, `${file}:${line}: unnamed ${value}`);
        if (value === "Name") {
          assert.equal(definition.name, null, `${file}:${line}: duplicate Name`);
          definition.name = names[0];
          definition.location = `${file}:${line}`;
          definition.release = release;
          definition.possible = possible;
        } else for (const member of names) definition.exports.push({ member, release, possible, file, line, condition });
      }
      if (value === "}") {
        if (definition?.depth === depth) {
          assert.ok(definition.name, `${file}:${line}: ModuleDefinition without Name`);
          const module = modules.get(definition.name) ?? { location: definition.location, members: new Map() };
          for (const entry of definition.exports) {
            const entries = module.members.get(entry.member) ?? [];
            entries.push({ ...entry, release: entry.release && definition.release, possible: entry.possible && definition.possible });
            module.members.set(entry.member, entries);
          }
          modules.set(definition.name, module);
          definition = null;
        }
        depth--;
      }
    }
    assert.equal(stack.length, 0, `${file}: unclosed Swift condition`);
    assert.equal(definition, null, `${file}: unclosed ModuleDefinition`);
  }
  return modules;
}

function productionAccesses(sources) {
  const accesses = [];
  const factories = new Set(["requireNativeModule", "requireOptionalNativeModule", "nativeModule", "optionalNativeModule"]);
  for (const [file, source] of sources) {
    const input = tokens(source);
    const bindings = new Map();
    const calls = [];
    for (let i = 0; i < input.length; i++) {
      if (!factories.has(input[i].value)) continue;
      let end = i + 1;
      if (input[end]?.value === "<") {
        let depth = 1;
        while (depth && input[++end]) {
          if (input[end].value === "<") depth++;
          if (input[end].value === ">") depth--;
        }
        assert.equal(depth, 0, `${file}:${input[i].line}: unclosed native type argument`);
        end++;
      }
      if (input[end]?.value !== "(") continue;
      const name = input[end + 1]?.value;
      assert.match(name ?? "", /^["'][^"']+["']$/, `${file}:${input[i].line}: native module name must be literal`);
      assert.equal(input[end + 2]?.value, ")", `${file}:${input[i].line}: unsupported native factory arguments`);
      const module = name.slice(1, -1);
      if (input[i - 1]?.value === "=" && /^[\w$]+$/.test(input[i - 2]?.value ?? "")) bindings.set(input[i - 2].value, module);
      calls.push({ end: end + 2, module });
    }
    function access(index, module) {
      if (![".", "?."].includes(input[index + 1]?.value)) return;
      const member = input[index + 2]?.value;
      if (!/^[A-Za-z_$][\w$]*$/.test(member ?? "") || emitter.has(member)) return;
      accesses.push({ file, line: input[index + 2].line, module, member });
    }
    for (let i = 0; i < input.length; i++) if (bindings.has(input[i].value)) access(i, bindings.get(input[i].value));
    for (const call of calls) access(call.end, call.module);
  }
  return accesses;
}

function violations(modules, accesses) {
  return accesses.flatMap(({ file, line, module, member }) => {
    const entries = modules.get(module)?.members.get(member) ?? [];
    const key = `${module}.${member}`;
    const defined = entries.some((entry) => entry.possible);
    if (defined && (entries.some((entry) => entry.release) || (file === "packages/settings/src/index.ts" && allowances.has(key)))) return [];
    const definitions = entries.length ? entries.map((entry) => `${entry.file}:${entry.line} [${entry.condition}]`).join(", ") : `no Swift definition (module: ${modules.get(module)?.location ?? "missing"})`;
    return [`${file}:${line}: ${key} ${defined ? "is not Release-defined" : "is not defined in any build"}; ${definitions}`];
  });
}

const packageNames = readdirSync(resolve(root, "packages"), { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name);
const swiftFiles = [...packageNames.flatMap((name) => {
  try { return files(`packages/${name}/ios`); } catch (error) { if (error.code === "ENOENT") return []; throw error; }
}), ...files("apps/browser/macos")].filter((file) => file.endsWith(".swift"));
const jsFiles = [...files("apps/browser/src"), ...packageNames.flatMap((name) => {
  try { return files(`packages/${name}/src`); } catch (error) { if (error.code === "ENOENT") return []; throw error; }
})].filter((file) => /\.tsx?$/.test(file) && !/\.test\.|\/(test-native|fixtures)\/|\/test-loader\.|^apps\/browser\/src\/lib\/devHarness\.ts$|^packages\/(shell|solaracore)\/src\/nativeModules\.ts$/.test(file));
const swiftSources = new Map(swiftFiles.map((file) => [file, readFileSync(resolve(root, file), "utf8")]));
const accesses = productionAccesses(new Map(jsFiles.map((file) => [file, readFileSync(resolve(root, file), "utf8")])));

test("production native accesses exist in shipping Release modules", (t) => {
  const modules = swiftExports(swiftSources);
  const errors = violations(modules, accesses);
  assert.deepEqual(errors, [], errors.join("\n"));
  const members = [...modules.values()].reduce((sum, module) => sum + [...module.members.values()].filter((entries) => entries.some((entry) => entry.release)).length, 0);
  t.diagnostic(`${modules.size} modules, ${members} Release members, ${accesses.length} production accesses`);
});

test("the guard catches a Debug-only store freeze export", () => {
  const file = "packages/store/ios/StoreModule.swift";
  const original = swiftSources.get(file);
  const source = original.replace(/^(\s*)Function\("freeze"\)([\s\S]*?^\s*})/m, "$1#if DEBUG\n$1Function(\"freeze\")$2\n$1#endif");
  assert.notEqual(source, original);
  const mutated = new Map(swiftSources).set(file, source);
  const errors = violations(swiftExports(mutated), accesses);
  assert.equal(errors.length, 1, errors.join("\n"));
  assert.match(errors[0], /packages\/store\/src\/index\.ts:\d+: SolaraStoreAdapter\.freeze is not Release-defined/);
  assert.match(errors[0], /StoreModule\.swift:\d+ \[\(DEBUG\)\]/);
});

test("conditional alternatives and missing exports fail closed", () => {
  const source = `
    func definition() -> ModuleDefinition {
      Name("Fixture")
      #if DEBUG || (SOLARA_PROBES && !SOLARA_PERF_TRACE)
      Function("debug") {}
      #elseif SOLARA_PERF_TRACE
      Function("trace") {}
      #else
      Property("ready") { true }
      Constant("version", 1)
      Events("changed", "closed")
      #endif
      View(FixtureView.self) { Function("viewOnly") {} }
    }
  `;
  const modules = swiftExports(new Map([["fixture.swift", source]]));
  const accesses = productionAccesses(new Map([["fixture.ts", `
    const native = requireOptionalNativeModule<{ ready: boolean }>("Fixture");
    native.ready;
    native?.version;
    native?.debug?.();
    native.trace();
    native?.missing?.();
    native.viewOnly();
    native.addListener("changed");
    const other = nativeModule("Other");
    other.ready;
  `]]));
  const errors = violations(modules, accesses);
  assert.equal(accesses.length, 7);
  assert.equal(errors.length, 5);
  assert.ok(errors.some((error) => error.includes("Fixture.debug is not Release-defined")));
  assert.ok(errors.some((error) => error.includes("Fixture.trace is not Release-defined")));
  for (const name of ["Fixture.missing", "Fixture.viewOnly", "Other.ready"]) {
    assert.ok(errors.some((error) => error.includes(`${name} is not defined in any build`)));
  }
  assert.equal(modules.get("Fixture").members.get("changed")[0].release, true);
  assert.throws(() => swiftExports(new Map([["fixture.swift", source.replace("#if DEBUG", "#if UNKNOWN")]])), /Unsupported Swift condition/);
});
