import { useEffect } from "react";
import { useWindowId } from "../../store/hooks";
import { startLive } from "../../live";
import { MeetingAlert } from "../live/MeetingAlert";

export function SidebarOverlays({ windowWidth }: { windowWidth: number }) {
  const windowId = useWindowId();
  useEffect(startLive, []);
  return <MeetingAlert windowId={windowId} windowWidth={windowWidth} />;
}
