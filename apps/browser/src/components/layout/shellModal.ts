import { setWindowShellModal, windowShellActive } from "@solara/settings";
import { useEffect, useState } from "react";
import { useOnboarding } from "../onboarding/state";
import { useCreateProfileOpen } from "../profiles/CreateProfile";
import { useWindowReplicaFallback } from "./windowLayout";

const MAIN_ROOT = "mainRoot";

export function useMainRootModal(windowId: string): boolean {
  const profile = useCreateProfileOpen(windowId);
  const onboarding = useOnboarding((o) => o.windowId === windowId);
  const fallbackPanel = useWindowReplicaFallback(windowId, (state) => !!state.windowUi[windowId]?.panel.open);
  return profile || onboarding || fallbackPanel === true;
}

export function useShellModal(windowId: string) {
  const [shell] = useState(() => windowShellActive(windowId));
  const modal = useMainRootModal(windowId);
  useEffect(() => {
    if (!shell || !modal) return;
    void setWindowShellModal(windowId, MAIN_ROOT, true);
    return () => void setWindowShellModal(windowId, MAIN_ROOT, false);
  }, [shell, windowId, modal]);
}
