import { hideNativeMeetingAlert, nativePagesAvailable, onNativeMeetingAlert, showNativeMeetingAlert } from "@solara/settings";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { View } from "react-native";
import { useTheme } from "../../lib/theme";
import { dismiss, joinEvent, useMeetingAlert } from "../../live/alerts";
import { useCalendar, useNow } from "../../live/calendar";
import { attendeesLabel, guestsLabel, isCalendarUrl, joinLink, joinTitle, relatedLinks, relativeTime, timeRange, type CalendarEvent } from "../../live/meetings";
import { useBrowser } from "../../store/browser";
import { viewTabIds } from "../../store/model";
import { measureRow, type Anchor } from "../sidebar/state";
import { NativeCard } from "./CalendarPreview";
import { useLiveColors } from "./colors";

const WIDTH = 300;

export function MeetingAlert({ windowId, windowWidth }: { windowId: string; windowWidth: number }) {
  const event = useMeetingAlert((s) => s.event);
  const front = useBrowser((s) => s.ui.focusedWindowId === windowId);
  if (!event || !front) return null;
  return <AlertCard key={event.occurrence} event={event} windowId={windowId} windowWidth={windowWidth} />;
}

function AlertCard({ event, windowId, windowWidth }: { event: CalendarEvent; windowId: string; windowWidth: number }) {
  const theme = useTheme();
  const colors = useLiveColors();
  const now = useNow(15_000);
  const calendarTab = useBrowser((s) => viewTabIds(s, windowId).find((id) => s.tabs[id]?.pinned && isCalendarUrl(s.tabs[id]!.pinnedUrl ?? s.tabs[id]!.url)));
  const sidebarShown = useBrowser((s) => !!s.windows[windowId]?.sidebarOpen);
  const calendarName = useCalendar((s) => s.calendars.find((c) => c.id === event.calendarId)?.title);
  const [anchor, setAnchor] = useState<Anchor | null>(null);
  const [framed, setFramed] = useState<boolean | null>(nativePagesAvailable() ? null : false);

  useEffect(() => {
    let cancelled = false;
    if (calendarTab && sidebarShown) void measureRow(windowId, calendarTab).then((a) => !cancelled && setAnchor(a));
    else setAnchor(null);
    return () => {
      cancelled = true;
    };
  }, [calendarTab, sidebarShown, windowWidth]);

  const link = joinLink(event);
  const related = relatedLinks(event);
  const running = event.start <= now;
  const people = event.attendees.filter((a) => !a.me);
  const who = attendeesLabel(event);
  const position = anchor ? { left: anchor.x + anchor.width + 8, top: Math.max(8, anchor.y - 4) } : { left: Math.max(8, windowWidth - WIDTH - 14), top: 52 };
  const nativeState = JSON.stringify({
    card: "meetingAlert",
    dark: !!theme.dark,
    nowColor: colors.now,
    alert: {
      id: event.occurrence,
      title: event.title || "Untitled event",
      color: event.color,
      time: timeRange(event),
      when: running ? "Now" : relativeTime(event.start, now),
      running,
      joinTitle: link ? joinTitle(link.provider) : null,
      people: people.map((a) => a.name || a.email),
    },
    calendarName: calendarName ?? null,
    who: who || guestsLabel(event),
    viewEvent: !link && !!calendarTab,
    openAll: link && related.length ? `Opens ${related.length === 1 ? "1 link" : `${related.length} links`} from the invitation, then joins` : null,
  });
  const onNativeEvent = (e: { kind: string; all?: unknown }) => {
    if (e.kind === "dismiss") dismiss(event);
    else if (e.kind === "join") joinEvent(event, !!e.all, windowId);
    else if (e.kind === "view" && calendarTab) {
      useBrowser.getState().activate(calendarTab);
      dismiss(event);
    }
  };
  const handler = useRef(onNativeEvent);
  handler.current = onNativeEvent;
  useEffect(() => {
    if (!nativePagesAvailable() || framed === false) return;
    let live = true;
    void showNativeMeetingAlert(windowId, nativeState, position.left, position.top).then((shown) => live && setFramed(shown));
    return () => {
      live = false;
    };
  }, [windowId, nativeState, position.left, position.top, framed]);
  useEffect(() => {
    if (!nativePagesAvailable()) return;
    const sub = onNativeMeetingAlert((e) => e.windowId === windowId && handler.current(e));
    return () => {
      sub?.remove();
      void hideNativeMeetingAlert(windowId);
    };
  }, [windowId]);
  if (framed !== false) return null;

  return (
    <AlertFrame position={position}>
      <NativeCard state={nativeState} onEvent={onNativeEvent} />
    </AlertFrame>
  );
}

function AlertFrame({ position, children }: { position: { left: number; top: number }; children: ReactNode }) {
  return (
    <View style={{ position: "absolute", ...position, width: WIDTH }}>
      {children}
    </View>
  );
}
