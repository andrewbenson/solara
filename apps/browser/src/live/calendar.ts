import type { CalendarAuthorization, SystemCalendar } from "@solara/shell";
import { create } from "zustand";
import type { CalendarEvent } from "./meetings";
import { connectCalendarCommand, onLiveSnapshot, refreshCalendarCommand, setCalendarHidden as setCalendarHiddenCommand } from "./store";

type CalendarData = {
  access: CalendarAuthorization | "fixture";
  calendars: SystemCalendar[];
  events: CalendarEvent[];
  loading: boolean;
  error: string | null;
  lastFetch: number | null;
};

export const useCalendar = create<CalendarData>()(() => ({
  access: "notDetermined",
  calendars: [],
  events: [],
  loading: false,
  error: null,
  lastFetch: null,
}));

let fieldJSON: Partial<Record<keyof CalendarData, string>> = {};
for (const [key, value] of Object.entries(useCalendar.getState())) fieldJSON[key as keyof CalendarData] = JSON.stringify(value);

export function applyCalendarReplica(calendarJSON: string): void {
  const data = JSON.parse(calendarJSON) as CalendarData;
  const changed: Partial<CalendarData> = {};
  for (const key of Object.keys(data) as (keyof CalendarData)[]) {
    const json = JSON.stringify(data[key]);
    if (json === fieldJSON[key]) continue;
    fieldJSON[key] = json;
    (changed as Record<string, unknown>)[key] = data[key];
  }
  if (Object.keys(changed).length) useCalendar.setState(changed);
}

onLiveSnapshot((replica) => { if (replica.calendarJSON) applyCalendarReplica(replica.calendarJSON); });

export const refreshCalendar = async (): Promise<void> => { await refreshCalendarCommand(); };
export const connectCalendar = async (): Promise<boolean> => (await connectCalendarCommand()).boolean ?? false;
export const calendarConnected = () => {
  const access = useCalendar.getState().access;
  return access === "fullAccess" || access === "fixture";
};
export const setCalendarHidden = (id: string, hidden: boolean) => setCalendarHiddenCommand(id, hidden);

export { useNow } from "../lib/useNow";
