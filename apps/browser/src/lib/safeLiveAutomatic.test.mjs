import assert from "node:assert/strict";
import { test } from "node:test";

let safeMode = "option";
const calls = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: { status: () => ({ active: false, safeMode }) },
  SolaraSettings: {
    liveInitialReplica: () => ({ revision: 0, replicaJSON: "{}" }),
    liveCommand: async (name) => { calls.push(name); return JSON.stringify({ revision: 0 }); },
    liveMeetingBrowser: async () => { calls.push("meetingBrowser"); },
    addListener: () => ({ remove() {} }),
  },
};
const { startNativeStore } = await import("../store/nativeStore.ts");
const { startMeetingGroups } = await import("../live/meetingGroups.ts");
const { updateCalendarSettings } = await import("../live/store.ts");

for (const safe of [true, false]) {
  test(`${safe ? "safe" : "normal"} meeting group subscriptions and explicit calendar command`, async () => {
    safeMode = safe ? "option" : null;
    startNativeStore();
    calls.length = 0;
    startMeetingGroups();
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.deepEqual(calls, safe ? [] : ["meetingBrowser"]);
    calls.length = 0;
    await updateCalendarSettings({ alertLead: "10" });
    assert.deepEqual(calls, ["updateCalendarSettings"]);
  });
}
