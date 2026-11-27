import { onHostedEvent, SolaraHostedView } from "@solara/settings";
import { useEffect, useRef } from "react";
import { Image } from "react-native";
import { CHECK_IN_COPY, useDefaultBrowserCheckIn } from "../../lib/defaultBrowserCheckIn";
import { useTheme } from "../../lib/theme";
import { APP_ICON } from "../../lib/appIcon";

let nextPresentation = 0;

export function CheckInBanner({ windowId, tabId }: { windowId: string; tabId: string }) {
  const checkIn = useDefaultBrowserCheckIn(windowId);
  const theme = useTheme();
  const presentation = useRef({ tabId: "", visible: false, token: "" });
  if (presentation.current.tabId !== tabId || presentation.current.visible !== checkIn.visible) {
    presentation.current = { tabId, visible: checkIn.visible, token: String(++nextPresentation) };
  }
  const { token } = presentation.current;
  useEffect(() => {
    let mounted = true;
    const unsubscribe = onHostedEvent("checkInBanner", windowId, (name, payload) => {
      if (!mounted || name !== "action" || !checkIn.visible || payload.token !== token || presentation.current.token !== token) return;
      if (payload.action === "feedback") checkIn.leaveFeedback();
      else if (payload.action === "dismiss") checkIn.dismiss();
    });
    return () => { mounted = false; unsubscribe(); };
  }, [windowId, checkIn.visible, token]);
  return <SolaraHostedView
    kind="checkInBanner"
    windowId={windowId}
    state={JSON.stringify({ tabId, visible: checkIn.visible, dark: theme.dark, title: CHECK_IN_COPY.title, action: CHECK_IN_COPY.action, token, icon: Image.resolveAssetSource(APP_ICON)?.uri ?? "" })}
    style={{ position: "absolute", left: 0, top: 0, width: 282, height: 69 }}
  />;
}
