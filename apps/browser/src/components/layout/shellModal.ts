import { setWindowShellModal, windowShellActive } from "@solara/settings";
import { useEffect, useState } from "react";
import { useBrowser } from "../../store/browser";
import { useOnboarding } from "../onboarding/state";
import { useCreateProfileOpen } from "../profiles/CreateProfile";

const MAIN_ROOT = "mainRoot";

export function useMainRootModal(windowId: string): boolean {
  const panel = useBrowser((s) => !!s.windowUi[windowId]?.panel.open);
  const profile = useCreateProfileOpen(windowId);
  const onboarding = useOnboarding((o) => o.windowId === windowId);
  return panel || profile || onboarding;
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
