import { readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, join, normalize, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const unquote = (value) => (value.startsWith('"') ? JSON.parse(value) : value);

function pbxObjects(text) {
  const objects = new Map();
  const object = /^\t\t([0-9A-F]{8,32})(?: \/\*.*?\*\/)? = \{(?:([^\n]*)\};|\n([\s\S]*?)\n\t\t\};)$/gm;
  for (const [, id, line, block] of text.matchAll(object)) {
    const body = line ?? block;
    const field = (name) => body.match(new RegExp(`\\b${name} = ("(?:[^"\\\\]|\\\\.)*"|[^;]+);`))?.[1];
    const children = body.match(/\bchildren = \(([\s\S]*?)\);/)?.[1].match(/\b[0-9A-F]{8,32}\b/g) ?? [];
    const path = field("path");
    objects.set(id, { isa: field("isa"), path: path === undefined ? undefined : unquote(path), sourceTree: field("sourceTree"), mainGroup: field("mainGroup"), children });
  }
  return objects;
}

export function listedPaths(pbxproj, podsDir) {
  const objects = pbxObjects(pbxproj);
  const project = [...objects.values()].find((o) => o.isa === "PBXProject");
  const listed = new Set();
  const seen = new Set();
  const walk = (id, base) => {
    const o = objects.get(id);
    if (!o || seen.has(id)) return;
    seen.add(id);
    const sourceTree = o.sourceTree === undefined ? undefined : unquote(o.sourceTree);
    const from = sourceTree === "SOURCE_ROOT" ? podsDir : sourceTree === "<group>" ? base : null;
    if (from === null) return;
    const here = o.path === undefined ? from : normalize(join(from, o.path));
    if (o.isa === "PBXGroup" || o.isa === "PBXVariantGroup") for (const child of o.children) walk(child, here);
    else if (o.isa === "PBXFileReference" && o.path !== undefined) listed.add(here);
  };
  if (project?.mainGroup) walk(project.mainGroup, podsDir);
  return listed;
}

export function podSourceGlobs(podspec) {
  const line = podspec.match(/^\s*s\.source_files\s*=\s*(.+)$/m)?.[1] ?? "";
  return [...line.matchAll(/'([^']*)'|"([^"]*)"/g)].map((m) => m[1] ?? m[2]);
}

function expandBraces(glob) {
  const m = glob.match(/\{([^{}]*)\}/);
  if (!m) return [glob];
  return m[1].split(",").flatMap((part) => expandBraces(glob.slice(0, m.index) + part + glob.slice(m.index + m[0].length)));
}

function globRegExp(glob) {
  let out = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*" && glob[i + 2] === "/") {
      out += "(?:.*/)?";
      i += 2;
    } else if (c === "*") out += "[^/]*";
    else if (c === "?") out += "[^/]";
    else out += c.replace(/[.+^$()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${out}$`);
}

export function podSources(globs, files) {
  const patterns = globs.flatMap(expandBraces).map(globRegExp);
  return files.filter((file) => patterns.some((p) => p.test(file)));
}

export function staleSources(pbxproj, podsDir, pods) {
  const listed = listedPaths(pbxproj, podsDir);
  return pods.flatMap(({ dir, globs, files }) => podSources(globs, files).map((file) => join(dir, file)).filter((path) => !listed.has(path)));
}

function filesUnder(dir, prefix = "") {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? filesUnder(path, `${prefix}${name}/`) : [`${prefix}${name}`];
  });
}

function repoPods(root) {
  const packages = join(root, "packages");
  return readdirSync(packages).flatMap((name) => {
    const dir = join(packages, name, "ios");
    let specs;
    try {
      specs = readdirSync(dir).filter((f) => f.endsWith(".podspec"));
    } catch {
      return [];
    }
    return specs.map((spec) => ({ dir, globs: podSourceGlobs(readFileSync(join(dir, spec), "utf8")), files: filesUnder(dir) }));
  });
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  const root = resolve(process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), "../.."));
  const pods = join(root, "apps/browser/macos/Pods");
  const stale = staleSources(readFileSync(join(pods, "Pods.xcodeproj/project.pbxproj"), "utf8"), pods, repoPods(root));
  for (const path of stale) console.error(`  ${relative(root, path)}`);
  process.exit(stale.length ? 1 : 0);
}
