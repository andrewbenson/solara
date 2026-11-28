import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { documentWrites } from "../test-native/shell.ts";

const calls = [];
const listeners = new Map();
let current = { revision: 0, replicaJSON: "{}" };
globalThis.acTestNativeModules = {
  SolaraSettings: {
    liveInitialReplica: () => current,
    liveCommand: async (name, payloadJSON) => {
      calls.push({ name, payload: JSON.parse(payloadJSON) });
      return JSON.stringify({ revision: current.revision });
    },
    addListener: (name, listener) => { listeners.set(name, listener); return { remove: () => listeners.delete(name) }; },
  },
};

const store = await import("./store.ts");

test("each persisted store action sends one command and never writes live.json", async () => {
  const actions = [
    ["updateCalendarSettings", () => store.updateCalendarSettings({ prompted: true }), { patch: { prompted: true } }],
    ["setCalendarHidden", () => store.setCalendarHidden("c", true), { id: "c", hidden: true }],
    ["dismissAlert", () => store.dismissAlert("o"), { occurrence: "o" }],
    ["setMeetingGroup", () => store.setMeetingGroup(null, "g"), { group: null, groupId: "g" }],
  ];
  for (const [name, run, payload] of actions) {
    const before = calls.length;
    await run();
    assert.deepEqual(calls.slice(before), [{ name, payload }]);
  }
  assert.equal(documentWrites.includes("live.json"), false);
});

test("only newer meeting fields replace the replica, and unchanged fields keep their identity", () => {
  const before = store.live();
  const calendar = { prompted: true };
  listeners.get("onLiveReplica")({ revision: 2, replicaJSON: JSON.stringify({ calendar }) });
  const applied = store.live();
  assert.deepEqual(applied.calendar, calendar);
  assert.equal(applied.meetingGroups, before.meetingGroups);
  listeners.get("onLiveReplica")({ revision: 1, replicaJSON: '{"calendar":{"prompted":false}}' });
  listeners.get("onLiveReplica")({ revision: 3, replicaJSON: '{"folders":{"f":{}},"calendar":{"prompted":true}}' });
  assert.equal(store.live(), applied);
});

test("a command's own change is in the store when it resolves, even before its replica event", async () => {
  current = { revision: 10, replicaJSON: '{"calendar":{"prompted":false}}' };
  await store.updateCalendarSettings({ prompted: false });
  assert.equal(store.live().calendar.prompted, false);
});

test("source tree has no live.json write through a literal or alias", () => {
  const root = fileURLToPath(new URL("../", import.meta.url));
  const visit = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((entry) => entry.isDirectory() ? visit(`${dir}/${entry.name}`) : [`${dir}/${entry.name}`]);
  for (const path of visit(root).filter((path) => /\.(?:[cm]?[jt]sx?)$/.test(path))) {
    const source = readFileSync(path, "utf8");
    const aliases = [...source.matchAll(/(?:const|let)\s+(\w+)\s*=\s*["']live\.json["']/g)].map((match) => match[1]);
    const writes = [...source.matchAll(/writeDocument\s*\(\s*([A-Za-z_$][\w$]*|"[^"]*"|'[^']*')/g)];
    for (const match of writes) assert.equal(match[1] === '"live.json"' || match[1] === "'live.json'" || aliases.includes(match[1]), false, path);
  }
});

test("calendar and meeting alert replicas update their UI stores without replacing unchanged values", async () => {
  const calendar = await import("./calendar.ts");
  const alerts = await import("./alerts.ts");
  const beforeEvents = calendar.useCalendar.getState().events;
  const event = { id: "standup", occurrence: "standup@1", calendarId: "work", color: "#123456", title: "Standup", start: 10, end: 20, allDay: false, location: "", notes: "", url: "", cancelled: false, declined: false, organizer: null, attendees: [] };
  const calendarJSON = JSON.stringify({ access: "fixture", calendars: [], events: [event], loading: false, error: null, lastFetch: 10 });
  listeners.get("onLiveReplica")({ revision: 11, replicaJSON: "{}", calendarJSON, meetingAlertJSON: JSON.stringify(event) });
  assert.notEqual(calendar.useCalendar.getState().events, beforeEvents);
  assert.deepEqual(calendar.useCalendar.getState().events, [event]);
  assert.deepEqual(alerts.useMeetingAlert.getState().event, event);
  const appliedEvents = calendar.useCalendar.getState().events;
  const appliedAlert = alerts.useMeetingAlert.getState().event;
  listeners.get("onLiveReplica")({ revision: 12, replicaJSON: "{}", calendarJSON, meetingAlertJSON: JSON.stringify(event) });
  assert.equal(calendar.useCalendar.getState().events, appliedEvents);
  assert.equal(alerts.useMeetingAlert.getState().event, appliedAlert);
  listeners.get("onLiveReplica")({ revision: 10, replicaJSON: "{}", calendarJSON: "{}", meetingAlertJSON: "null" });
  assert.equal(alerts.useMeetingAlert.getState().event, appliedAlert);
  assert.equal(documentWrites.includes("live.json"), false);
});

test("live source no longer reads EventKit events or schedules moved polling", () => {
  const root = fileURLToPath(new URL("./", import.meta.url));
  for (const name of ["calendar.ts", "alerts.ts", "meetingGroups.ts"]) {
    const source = readFileSync(`${root}/${name}`, "utf8");
    assert.doesNotMatch(source, /\b(?:systemCalendars|systemCalendarEvents|calendarAuthorization|requestCalendarAccess|onCalendarChanged|everySlowly)\b/, name);
  }
  assert.doesNotMatch(readFileSync(`${root}/meetingGroups.ts`, "utf8"), /export function tick\(/);
});
