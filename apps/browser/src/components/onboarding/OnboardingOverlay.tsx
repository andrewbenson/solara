import { hostedKinds, SolaraHostedView } from "@solara/settings";
import { StyleSheet } from "react-native";
import { useWindowId } from "../../store/hooks";
import { useOnboarding } from "./state";
import { ToolTour } from "./tour/ToolTour";

export function OnboardingOverlay() {
  const windowId = useWindowId();
  const active = useOnboarding((s) => s.windowId === windowId);
  const session = useOnboarding((s) => s.session);
  const requestId = useOnboarding((s) => s.requestId);
  return (
    <>
      {active && hostedKinds().includes("onboarding") ? (
        <SolaraHostedView key={session} kind="onboarding" windowId={windowId} state={requestId ?? ""} active style={StyleSheet.absoluteFill} />
      ) : null}
      <ToolTour />
    </>
  );
}
