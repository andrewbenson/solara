import assert from "node:assert/strict";
import test from "node:test";
import { AfterFirstWindowQueue } from "./afterFirstWindow.ts";

test("the admitted launch mark uses the native CA epoch instead of the callback time", async () => {
  const timers = Object.fromEntries(["setTimeout", "setInterval", "setImmediate"].map((key) => [key, globalThis[key]]));
  const before = { expo: globalThis.expo, hook: globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__, perf: globalThis.acPerf };
  globalThis.expo = { modules: {
    SolaraApp: { systemInfo: () => ({ isolatedInstance: true, testFacilities: true }) },
    SolaraShell: { readDocument: () => "native-epoch" },
  } };
  try {
    const { perfMark, perfProbeEnabled } = await import("./perfProbe.ts?native-epoch");
    assert.equal(perfProbeEnabled, true);
    const nativeEpoch = Date.now() - 1000;
    const queue = new AfterFirstWindowQueue();
    let admitted;
    queue.install((task) => { admitted = task; return () => {}; });
    queue.add(() => perfMark("firstWindow", nativeEpoch));
    assert.equal(globalThis.acPerf.marks.firstWindow, undefined);
    admitted();
    assert.equal(globalThis.acPerf.marks.firstWindow, nativeEpoch);
    perfMark("firstWindow", nativeEpoch + 200);
    assert.equal(globalThis.acPerf.marks.firstWindow, nativeEpoch);
    perfMark("invalidNativeEpoch", NaN);
    assert.equal(globalThis.acPerf.marks.invalidNativeEpoch, undefined);
  } finally {
    Object.assign(globalThis, timers);
    globalThis.expo = before.expo;
    globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__ = before.hook;
    globalThis.acPerf = before.perf;
  }
});
