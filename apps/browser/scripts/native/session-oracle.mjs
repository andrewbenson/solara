#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

const HELP = `usage: node scripts/native/session-oracle.mjs <data folder> [--now <ms>] [--seed <n>]

Reads session.json and downloads.json from the folder, matches their exact contents
against session-fixtures.json beside this script, and prints the recorded expected
oracle output. The fixed clock is 1793016000000 and seed is 24301. Unknown inputs
or different clock/seed values fail; regenerate expectations explicitly when adding
fixtures. No application persistence code is imported and the folder is only read.`;

const args = process.argv.slice(2);
if (!args.length || args.includes("--help")) {
  console.log(HELP);
  process.exit(args.length ? 0 : 2);
}
const option = (name, fallback) => {
  const at = args.indexOf(name);
  if (at < 0) return fallback;
  const value = args[at + 1];
  args.splice(at, 2);
  return value;
};
const now = Number(option("--now", "1793016000000"));
const seed = Number(option("--seed", "24301"));
if (args.length !== 1 || now !== 1793016000000 || seed !== 24301) throw new Error("fixed fixtures require the recorded clock and seed");
const folder = resolve(args[0]);
const fixtures = JSON.parse(readFileSync(new URL("./session-fixtures.json", import.meta.url), "utf8"));
const inputs = Object.fromEntries(["session.json", "downloads.json"].filter((name) => existsSync(join(folder, name))).map((name) => [name, readFileSync(join(folder, name), "utf8")]));
const fixture = fixtures.find((entry) => JSON.stringify(entry.inputs) === JSON.stringify(inputs));
if (!fixture) throw new Error("no fixed oracle expectation matches these session/downloads bytes");
if (fixture.failure) {
  process.stderr.write(fixture.failure);
  process.exit(1);
}
process.stdout.write(JSON.stringify(fixture.expected) + "\n");
