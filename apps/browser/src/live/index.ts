import { startLiveEngine } from "./engine";
import { startMeetingGroups } from "./meetingGroups";

export function startLive() {
  startLiveEngine();
  startMeetingGroups();
}
