import { useShallow } from "zustand/react/shallow";
import { useRef } from "react";
import { switchToTab } from "../../lib/actions";
import { useBrowser } from "../../store/browser";
import { isTabShown, playerTabFor, useMedia } from "./state";
import { addMediaActions, runPlayerAction } from "./nativeMedia";

const NO_IDS: string[] = [];

export function useSidebarPlayerTab(windowId: string, profileId: string): string | undefined {
  const sessions = useMedia(useShallow((m) => Object.keys(m.sessions)));
  const hidden = useBrowser(
    useShallow((s) => {
      const w = s.windows[windowId];
      if (!sessions.length || !w || !s.settings.sidebarMediaControls) return NO_IDS;
      const ids = sessions.filter((id) => s.tabs[id]?.windowId === windowId && s.tabs[id]!.profileId === profileId && !isTabShown(s, id, profileId));
      return ids.length > 1 ? ids.sort((a, b) => w.tabIds.indexOf(a) - w.tabIds.indexOf(b)) : ids;
    }),
  );
  const shown = useRef<string | undefined>(undefined);
  shown.current = useMedia((m) => playerTabFor(m, hidden, shown.current));
  return shown.current;
}

addMediaActions({ sidebarPlayer: (_windowId, tabId, extra) => runPlayerAction(tabId, extra, () => switchToTab(tabId)) });
