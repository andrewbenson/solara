import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();

function moduleEvents(source) {
  const lines = source.split("\n");
  const found = [];
  let module = null;
  for (let i = 0; i < lines.length; i++) {
    const name = lines[i].match(/^(\s*)Name\("([^"]+)"\)/);
    if (name) {
      module = { indent: name[1].length, name: name[2] };
      continue;
    }
    const events = lines[i].match(/^(\s*)Events\(/);
    if (!module || !events || events[1].length !== module.indent) continue;
    let call = lines[i];
    while (!call.includes(")") && i + 1 < lines.length) call += lines[++i];
    for (const [, event] of call.matchAll(/"([^"]+)"/g)) found.push({ module: module.name, event });
  }
  return found;
}

test("moduleEvents reads module-level events and skips a view's", () => {
  const source = [
    "  public func definition() -> ModuleDefinition {",
    '    Name("A")',
    '    Events("onOne",',
    '           "onTwo")',
    "    View(V.self) {",
    '      Events("onView")',
    "    }",
    "  }",
  ].join("\n");
  assert.deepEqual(moduleEvents(source), [{ module: "A", event: "onOne" }, { module: "A", event: "onTwo" }]);
});

test("no two Expo modules declare the same module-level event", () => {
  const files = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z", "--", "*.swift"], { cwd: root, encoding: "utf8" }).split("\0").filter((file) => file && existsSync(join(root, file)));
  const owners = new Map();
  for (const file of files) {
    for (const { module, event } of moduleEvents(readFileSync(join(root, file), "utf8"))) {
      owners.set(event, [...(owners.get(event) ?? []), `${module} (${file})`]);
    }
  }
  assert.ok(owners.size > 10, `found only ${owners.size} module events`);
  const shared = [...owners].filter(([, modules]) => new Set(modules).size > 1);
  assert.deepEqual(shared, [], "Expo's sendEvent reaches every module declaring the name, so a listener on each gets it twice");
});
