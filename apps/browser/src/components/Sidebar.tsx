import { WindowDragRegion } from "@solara/shell";
import { useEffect, useLayoutEffect, useMemo, useState } from "react";
import { Animated, Easing, StyleSheet, View } from "react-native";
import { layout, useTheme } from "../lib/theme";
import { useBrowser } from "../store/browser";
import { useWindowId, useWindowProfileId } from "../store/hooks";
import { downloadsIn } from "../store/ui";
import { SIDEBAR_FOOTER_DOWNLOADS, SIDEBAR_HEADER_WITH_FIELD, useAddressBarInSidebar } from "./layout/windowLayout";
import { DownloadsButton } from "./Downloads";
import { PROFILE_INDICATOR_X, ProfileIndicator } from "./ProfileIndicator";
import { usePagerPages } from "./layout/profilePager";
import { PROFILE_DOTS_HEIGHT, ProfileDots, useProfileDotsShown } from "./profiles/ProfileDots";
import { SidebarAddressRow, SidebarHeaderTools } from "./sidebar/AddressBar";
import { SidebarDropArea } from "./sidebar/fileDrop";
import { FolderPanel } from "./sidebar/FolderPanel";
import { dismissHoverIn } from "./sidebar/hover";
import { ResizeHandle } from "./sidebar/ResizeHandle";
import { NativeSidebar, nativeSidebarShell, shellColumnFitsAddressBar } from "./sidebar/NativeSidebar";
import { useTabDrag } from "./layout/tabDrag";

const GLOW_ROOM = 24;

export function Sidebar({ width }: { width: number }) {
  const windowId = useWindowId();
  const current = useWindowProfileId();
  const { paging } = usePagerPages(windowId);
  const addressBar = useAddressBarInSidebar();
  const header = addressBar ? SIDEBAR_HEADER_WITH_FIELD : layout.sidebarHeader;
  const hasDownloads = useBrowser((s) => downloadsIn(s, windowId).length > 0);
  const dots = useProfileDotsShown();
  const footerDownloads = addressBar && hasDownloads;
  const footer = dots || footerDownloads ? PROFILE_DOTS_HEIGHT : 0;
  const [shellCapable] = useState(() => nativeSidebarShell(windowId));
  const shellColumn = shellCapable && shellColumnFitsAddressBar(addressBar);
  const column = useMemo(() => ({ top: header - GLOW_ROOM, header, bottom: footer, clip: paging }), [header, footer, paging]);

  useLayoutEffect(() => dismissHoverIn(windowId), [windowId, current, paging]);

  if (shellColumn) {
    return (
      <>
        <NativeSidebar windowId={windowId} profileId={current} addressBar={addressBar} column={column} width={width} />
        <FolderPanel windowId={windowId} />
      </>
    );
  }

  return (
    <SidebarDropArea style={{ width, height: "100%" }}>
      <View
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          top: header - GLOW_ROOM,
          bottom: footer,
          overflow: paging ? "hidden" : "visible",
        }}
      >
        <NativeSidebar windowId={windowId} profileId={current} addressBar={addressBar} />
      </View>

      {footer ? (
        <View style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: footer }}>
          {dots ? <ProfileDots windowId={windowId} /> : null}
          {footerDownloads ? (
            <View style={{ position: "absolute", left: layout.sidebarInset, bottom: SIDEBAR_FOOTER_DOWNLOADS.bottom }}>
              <DownloadsButton windowId={windowId} />
            </View>
          ) : null}
        </View>
      ) : null}

      <View style={{ height: header }}>
        <WindowDragRegion style={StyleSheet.absoluteFill} />
        {addressBar ? (
          <>
            <SidebarHeaderTools width={width} />
            <SidebarAddressRow width={width} />
          </>
        ) : (
          <View pointerEvents="box-none" style={{ height: layout.sidebarHeader, flexDirection: "row", alignItems: "flex-start", paddingLeft: PROFILE_INDICATOR_X, paddingRight: 7, paddingTop: 27 - 17 }}>
            <ProfileIndicator room={width - PROFILE_INDICATOR_X - 7 - (hasDownloads ? 34 + 2 : 0)} />
            <View pointerEvents="none" style={{ flex: 1 }} />
            {hasDownloads ? <DownloadsButton windowId={windowId} /> : null}
          </View>
        )}
      </View>

      <ResizeHandle windowId={windowId} />
      <FolderPanel windowId={windowId} />
      <WindowDropHighlight />
    </SidebarDropArea>
  );
}

function WindowDropHighlight() {
  const windowId = useWindowId();
  const theme = useTheme();
  const over = useTabDrag((d) => d.overWindow === windowId);
  const glow = useMemo(() => new Animated.Value(0), []);
  useEffect(() => {
    Animated.timing(glow, { toValue: over ? 1 : 0, duration: 140, easing: Easing.out(Easing.quad), useNativeDriver: true }).start();
  }, [over]);
  return (
    <Animated.View
      pointerEvents="none"
      style={{
        position: "absolute",
        left: 5,
        right: 5,
        top: 44,
        bottom: 6,
        borderRadius: 10,
        borderWidth: 1.5,
        borderColor: theme.accent,
        backgroundColor: theme.dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)",
        opacity: glow,
      }}
    />
  );
}
