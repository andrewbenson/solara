import { SolaraHostedView } from "@solara/settings";
import { Image } from "react-native";
import { APP_ICON } from "../../lib/appIcon";
import { useTheme } from "../../lib/theme";

export function CheckInBanner({ windowId, tabId, onboarding }: { windowId: string; tabId: string; onboarding: boolean }) {
  const { dark } = useTheme();
  return <SolaraHostedView
    kind="checkInBanner"
    windowId={windowId}
    state={JSON.stringify({ tabId, onboarding, dark, icon: Image.resolveAssetSource(APP_ICON)?.uri ?? "" })}
    style={{ position: "absolute", left: 0, top: 0, width: 282, height: 69 }}
  />;
}
