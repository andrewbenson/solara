import { liveInitialReplica, onLiveReplica, type LiveReplica } from "@solara/settings";
import { liveCommand } from "./command";
import { create } from "zustand";
export type CalendarSettings = {
  alertLead: string;
  alertCondition: "always" | "activeOnly";
  showPreview: boolean;
  showTimeToNext: boolean;
  hiddenCalendarIds: string[];
  prompted: boolean;
};

export type MeetingGroup = {
  groupId: string;
  callTabId: string;
  occurrence: string | null;
  title: string;
  start: number | null;
  end: number | null;
  endedAt: number | null;
};

type LiveState = {
  calendar: Pick<CalendarSettings, "prompted">;
  meetingGroups: Record<string, MeetingGroup>;
};

const initial = (() => {
  try { return liveInitialReplica(); }
  catch { return { revision: 0, replicaJSON: "{}" }; }
})();

const parseReplica = (replica: LiveReplica): Partial<LiveState> => JSON.parse(replica.replicaJSON) as Partial<LiveState>;
const saved = parseReplica(initial);
let lastRevision = initial.revision;
let latestReplica = initial;
const snapshotListeners = new Set<(replica: LiveReplica) => void>();

export function onLiveSnapshot(listener: (replica: LiveReplica) => void): () => void {
  snapshotListeners.add(listener);
  listener(latestReplica);
  return () => snapshotListeners.delete(listener);
}

export const useLive = create<LiveState>()(() => ({
  calendar: saved.calendar ?? { prompted: false },
  meetingGroups: saved.meetingGroups ?? {},
}));

let calendarJSON = JSON.stringify(useLive.getState().calendar);
let groupsJSON = JSON.stringify(useLive.getState().meetingGroups);

export const live = () => useLive.getState();

export function applyLiveReplica(replica: LiveReplica): void {
  if (replica.revision <= lastRevision) return;
  const { calendar, meetingGroups } = parseReplica(replica);
  const changed: Partial<LiveState> = {};
  if (calendar) {
    const json = JSON.stringify(calendar);
    if (json !== calendarJSON) {
      calendarJSON = json;
      changed.calendar = calendar;
    }
  }
  if (meetingGroups) {
    const json = JSON.stringify(meetingGroups);
    if (json !== groupsJSON) {
      groupsJSON = json;
      changed.meetingGroups = meetingGroups;
    }
  }
  lastRevision = replica.revision;
  latestReplica = replica;
  if (changed.calendar || changed.meetingGroups) useLive.setState(changed);
  for (const listener of snapshotListeners) listener(replica);
}

onLiveReplica(applyLiveReplica);
try { applyLiveReplica(liveInitialReplica()); } catch {}

const command = async (name: string, payload: Record<string, unknown>) => {
  const result = await liveCommand(name, payload);
  if (result.revision > lastRevision) {
    try { applyLiveReplica(liveInitialReplica()); } catch {}
  }
  return result;
};

export const updateCalendarSettings = (patch: Partial<CalendarSettings>) => command("updateCalendarSettings", { patch });
export const setCalendarHidden = (id: string, hidden: boolean) => command("setCalendarHidden", { id, hidden });
export const dismissAlert = (occurrence: string) => command("dismissAlert", { occurrence });
export const setMeetingGroup = (group: MeetingGroup | null, groupId?: string) => command("setMeetingGroup", { group, ...(groupId ? { groupId } : {}) });

export const refreshCalendarCommand = () => command("refreshCalendar", {});
export const connectCalendarCommand = () => command("connectCalendar", {});
export const offerAlertsForPinnedTab = (url: string) => command("offerAlertsForPinnedTab", { url });
export const answerAlertOffer = (confirmed: boolean) => command("answerAlertOffer", { confirmed });
