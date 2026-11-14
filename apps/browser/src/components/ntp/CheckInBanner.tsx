import { onHostedEvent, SolaraHostedView } from "@solara/settings";
import { useEffect, useRef } from "react";
import { Image } from "react-native";
import { CHECK_IN_COPY, useDefaultBrowserCheckIn } from "../../lib/defaultBrowserCheckIn";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { APP_ICON } from "../../lib/appIcon";

let nextPresentation = 0;

export function CheckInBanner({ windowId }: { windowId: string }) {
  const checkIn = useDefaultBrowserCheckIn(windowId);
  const theme = useTheme();
  const window = useBrowser(state => state.windows[windowId]);
  const focusContext = useBrowser(state => {
    const current = state.windows[windowId];
    const tabId = current?.activeTabIds?.[current.profileId];
    return JSON.stringify([windowId, current?.profileId, tabId, tabId ? state.tabs[tabId]?.url : null, state.ui?.focusedWindowId]);
  });
  const identity = `${window?.profileId}:${checkIn.visible}`;
  const presentation = useRef({ identity: "", token: "" });
  if (presentation.current.identity !== identity) presentation.current = { identity, token: String(++nextPresentation) };
  const token = presentation.current.token;
  const profileId = window?.profileId;
  useEffect(() => {
    let mounted = true;
    const unsubscribe = onHostedEvent("checkInBanner", windowId, (name, payload) => {
      const current = useBrowser.getState().windows[windowId];
      if (!mounted || name !== "action" || !current || current.incognito || !checkIn.visible || current.profileId !== profileId || current.profileId !== payload.profileId || payload.token !== token || presentation.current.token !== token) return;
      if (payload.action === "feedback") checkIn.leaveFeedback();
      else if (payload.action === "dismiss") checkIn.dismiss();
    });
    return () => { mounted = false; unsubscribe(); };
  }, [windowId, profileId, checkIn.visible, token]);
  if (!window || window.incognito) return null;
  return <SolaraHostedView
    kind="checkInBanner"
    windowId={windowId}
    state={JSON.stringify({ visible: checkIn.visible, focusContext, dark: theme.dark, title: CHECK_IN_COPY.title, action: CHECK_IN_COPY.action, profileId: window.profileId, token, icon: Image.resolveAssetSource(APP_ICON)?.uri ?? "" })}
    style={{ position: "absolute", left: 0, top: 0, width: 282, height: 69 }}
  />;
}
