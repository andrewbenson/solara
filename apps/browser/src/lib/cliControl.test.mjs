import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;
const cli = await import("./cliControl.ts");

test("the command is the app's name in lowercase, so a fork ships its own", async () => {
  const { appInfo } = await import("../test-native/index.ts");
  assert.equal(cli.cliProduct(), "Solara");
  assert.equal(cli.cliCommand(), "solara");
  appInfo.appName = "Solara";
  try {
    assert.equal(cli.cliProduct(), "Solara");
    assert.equal(cli.cliCommand(), "solara");
  } finally {
    delete appInfo.appName;
  }
  assert.equal(cli.cliCommand(), "solara");
});
