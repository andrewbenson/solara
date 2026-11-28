import { useEffect } from "react";
import { useWindowId } from "../../store/hooks";
import { startMeetingGroups } from "../../live/meetingGroups";
import { MeetingAlert } from "../live/MeetingAlert";

export function SidebarOverlays({ windowWidth }: { windowWidth: number }) {
  const windowId = useWindowId();
  useEffect(startMeetingGroups, []);
  return <MeetingAlert windowId={windowId} windowWidth={windowWidth} />;
}
