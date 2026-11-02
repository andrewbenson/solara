import { FadeLabel, Surface, Symbol } from "@solara/shell";
import { useLayoutEffect, useState } from "react";
import { Animated, Pressable, StyleSheet, Text, View, type AccessibilityActionEvent, type GestureResponderEvent } from "react-native";
import { displayUrl } from "@solara/core";
import { hex, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useStoreWhile } from "../../store/tabWatch";
import { useIsBookmarked } from "../../store/hooks";
import { activeTabId, bookmarkProfileId, plural } from "../../store/model";
import { folderIn, folderLabel, folderMembers } from "../../store/tileFolders";
import { useShallow } from "zustand/react/shallow";
import { useFolderPanel } from "./tileFolderUi";
import { awayFromPin } from "../../store/organize";
import { openInSplit } from "../layout/splitActions";
import { CalendarPreview, useIsCalendarTab } from "../live/CalendarPreview";
import { LiveItemCard } from "../live/LiveItemCard";
import { useIsSleeping } from "../../lib/tabLifecycle";
import { useHover } from "../primitives";
import { clickTab, tabTitle } from "./actions";
import { GroupPanel } from "./GroupPanel";
import { cardHoverProps, dismissHover, setHoverSpace } from "./hover";
import { hoverCardOrigin, useHoverCardMotion, useHoverCardPlacement } from "./hoverMotion";
import { useSidebarUi, type Anchor, type Hover } from "./state";
import { TabIcon } from "./TabIcon";
import { HoverPlayer, usePlayerEdge, useShowsMiniPlayer } from "../media/HoverPlayer";
import { useMedia, usePictureInPicture } from "../media/state";
import { useSidebarWidth } from "./tokens";
import { bareHost, FOLDER_PEEK_ROWS, NativeCalendarCard, nativeCardKind, useNativeHoverCard, useNativeHoverCardActive } from "./nativeHoverCard";

const WIDTH = 264;
const DIA_WIDTH = 200;
const DIA_HEIGHT = 109;
const DIA_PITCH = 49;

type ActionPress = GestureResponderEvent | AccessibilityActionEvent;

function diaCardOrigin(anchor: Anchor, sidebarWidth: number, cardHeight: number, windowHeight: number) {
  const right = anchor.x + anchor.width;
  const left = right <= sidebarWidth + 1 ? sidebarWidth + 0.5 : right + 8;
  const centred = anchor.y + anchor.height / 2 - cardHeight / 2;
  return { left, top: Math.max(8, Math.min(centred, windowHeight - cardHeight - 8)) };
}

export function HoverCard({ windowId, width, height }: { windowId: string; width: number; height: number }) {
  const hover = useSidebarUi((u) => (u.hover?.windowId === windowId ? u.hover : null));
  const orphaned = useStoreWhile(
    useBrowser,
    !!hover,
    (s) => (hover?.kind === "tab" && !s.tabs[hover.id]) || (hover?.kind === "group" && !s.groups[hover.id]) || (hover?.kind === "folder" && !folderIn(s, windowId, hover.id)),
  );
  useLayoutEffect(() => {
    if (orphaned) dismissHover();
  }, [orphaned]);
  useLayoutEffect(() => setHoverSpace(windowId, height), [windowId, height]);
  const target = orphaned ? null : hover;
  const { drawn, leaving, entering, motion } = useHoverCardMotion(windowId, target);
  const shown = drawn ?? target;
  const player = useShowsMiniPlayer(shown?.kind === "tab" ? shown.id : undefined);
  const calendar = useIsCalendarTab(shown?.kind === "tab" ? shown.id : null);
  const edge = usePlayerEdge(windowId, shown?.anchor);
  const sidebarWidth = useSidebarWidth(windowId);
  const [diaHeight, setDiaHeight] = useState(DIA_HEIGHT);
  const dia = shown?.kind === "tab" && !player && !calendar;
  const origin = !shown ? null : dia ? diaCardOrigin(shown.anchor, sidebarWidth, diaHeight, height) : hoverCardOrigin(shown.anchor, player ? edge : undefined);
  useHoverCardPlacement(motion, origin, { width, height });
  const nativeKind = nativeCardKind(useNativeHoverCardActive(windowId), shown, dia, player, calendar);
  useNativeHoverCard(windowId, nativeKind, target, sidebarWidth, height, edge);
  if (!shown) return null;
  if (nativeKind === "calendar") return target ? <NativeCalendarCard windowId={windowId} tabId={shown.id} anchor={shown.anchor} /> : null;
  if (nativeKind) return null;
  return (
    <Animated.View pointerEvents={leaving || entering ? "none" : "box-none"} style={[StyleSheet.absoluteFill, motion.style]}>
      {dia && origin ? (
        <DiaTabCard tabId={shown.id} windowId={windowId} origin={origin} onHeight={setDiaHeight} />
      ) : (
        <HoverContent hover={shown} windowId={windowId} player={player} calendar={calendar} windowHeight={height} />
      )}
    </Animated.View>
  );
}

function HoverContent({ hover, windowId, player, calendar, windowHeight }: { hover: Hover; windowId: string; player: boolean; calendar: boolean; windowHeight: number }) {
  if (hover.kind === "live") return <LiveItemCard id={hover.id} windowId={windowId} anchor={hover.anchor} />;
  if (hover.kind === "tab" && player) return <HoverPlayer tabId={hover.id} windowId={windowId} anchor={hover.anchor} />;
  if (hover.kind === "tab" && calendar) return <CalendarPreview tabId={hover.id} windowId={windowId} anchor={hover.anchor} />;
  if (hover.kind === "folder") return <FolderPeek folderId={hover.id} windowId={windowId} anchor={hover.anchor} />;
  return hover.kind === "tab" ? <TabCard tabId={hover.id} windowId={windowId} anchor={hover.anchor} /> : <GroupPanel key={`${windowId}:${hover.id}`} groupId={hover.id} windowId={windowId} anchor={hover.anchor} windowHeight={windowHeight} />;
}

function DiaTabCard({ tabId, windowId, origin, onHeight }: { tabId: string; windowId: string; origin: { left: number; top: number }; onHeight: (height: number) => void }) {
  const theme = useTheme();
  const tab = useBrowser((s) => s.tabs[tabId]);
  const isActive = useBrowser((s) => activeTabId(s, windowId) === tabId);
  const bookmarked = useIsBookmarked(tab?.url ?? "");
  const video = useMedia((m) => !!m.sessions[tabId]?.hasVideo || !!m.pipOpen[tabId]);
  const [pip, togglePip] = usePictureInPicture(tabId);
  const sleeping = useIsSleeping(tabId);
  if (!tab) return null;
  const s = () => useBrowser.getState();
  const away = awayFromPin(tab);
  const primary = theme.dark ? "rgba(255,255,255,0.86)" : theme.textPrimary;
  const secondary = theme.dark ? "rgba(255,255,255,0.585)" : theme.textSecondary;
  const actions: { icon: string; label: string; onPress(press: ActionPress): void }[] = [
    { icon: tab.pinned ? "pin.slash" : "pin", label: tab.pinned ? "Unpin" : "Pin", onPress: () => s().togglePin(tabId) },
  ];
  if (tab.url)
    actions.push({
      icon: bookmarked ? "bookmark.fill" : "bookmark",
      label: bookmarked ? "Remove Bookmark" : "Bookmark",
      onPress: () => s().toggleBookmark(bookmarkProfileId(s(), s().windows[windowId]), { url: tab.url, title: tabTitle(tab), favicon: tab.favicon }),
    });
  if (!isActive && !tab.pinned)
    actions.push({
      icon: "rectangle.split.2x1",
      label: "Open in Split View",
      onPress: () => {
        dismissHover();
        openInSplit(tabId);
      },
    });
  if (video) actions.push({ icon: pip ? "pip.exit" : "pip.enter", label: pip ? "Exit Picture in Picture" : "Picture in Picture", onPress: togglePip });
  if (away)
    actions.push({
      icon: "arrow.uturn.backward",
      label: "Back to Pinned URL",
      onPress: () => {
        dismissHover();
        s().returnToPinnedUrl(tabId);
      },
    });
  const pitch = Math.min(DIA_PITCH, (DIA_WIDTH - 4) / actions.length);
  return (
    <Surface
      {...cardHoverProps}
      onLayout={(e) => {
        cardHoverProps.onLayout(e);
        onHeight(e.nativeEvent.layout.height);
      }}
      fill={theme.dark ? "#262626" : hex(theme.panel)}
      cornerRadius={11}
      borderColor={theme.dark ? "#404040" : hex(theme.panelBorder)}
      borderWidth={0.5}
      shadowColor="#000000"
      shadowOpacity={theme.panelShadowOpacity * 0.8}
      shadowRadius={16}
      shadowOffset={[0, 6]}
      style={{ position: "absolute", ...origin, width: DIA_WIDTH, paddingTop: 16.5, paddingBottom: 6 }}
    >
      <Text numberOfLines={2} ellipsizeMode="tail" style={{ marginHorizontal: 14, fontSize: 13, lineHeight: 16, fontWeight: "600", color: primary }}>
        {tabTitle(tab)}
      </Text>
      {tab.url ? (
        <Text numberOfLines={1} ellipsizeMode="tail" style={{ marginHorizontal: 14, fontSize: 13, lineHeight: 16, color: secondary }}>
          {bareHost(tab.url)}
        </Text>
      ) : null}
      {sleeping ? (
        <Text numberOfLines={1} accessibilityLabel="Web content has been discarded" style={{ marginHorizontal: 14, marginTop: 2, fontSize: 11.5, color: theme.textTertiary }}>
          This tab needs to reload
        </Text>
      ) : null}
      <View style={{ flexDirection: "row", justifyContent: "center", marginTop: 10, paddingHorizontal: 2 }}>
        {actions.map((a) => (
          <IconAction key={a.label} width={pitch} icon={a.icon} label={a.label} color={secondary} onPress={a.onPress} />
        ))}
      </View>
    </Surface>
  );
}

function IconAction({ width, icon, label, color, onPress }: { width: number; icon: string; label: string; color: string; onPress(press: ActionPress): void }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps} tooltip={label} style={{ width, height: 28, alignItems: "center", justifyContent: "center" }}>
      <Pressable
        onPress={onPress}
        accessibilityRole="button"
        accessibilityLabel={label}
        accessibilityActions={ACTIVATE}
        onAccessibilityAction={(event) => event.nativeEvent.actionName === "activate" && onPress(event)}
      >
        {({ pressed }) => (
          <View
            style={{
              width: 28,
              height: 28,
              borderRadius: 7,
              alignItems: "center",
              justifyContent: "center",
              backgroundColor: pressed ? theme.toolbarPressed : hovered ? theme.toolbarHover : undefined,
            }}
          >
            <Symbol name={icon} size={14} color={color} style={{ width: 20, height: 20 }} />
          </View>
        )}
      </Pressable>
    </View>
  );
}

function Card({ anchor, children }: { anchor: Anchor; children: React.ReactNode }) {
  const theme = useTheme();
  return (
    <Surface
      {...cardHoverProps}
      fill={hex(theme.panel)}
      cornerRadius={12}
      borderColor={hex(theme.panelBorder)}
      borderWidth={0.5}
      shadowColor="#000000"
      shadowOpacity={theme.panelShadowOpacity * 0.8}
      shadowRadius={16}
      shadowOffset={[0, 6]}
      style={{ position: "absolute", ...hoverCardOrigin(anchor), width: WIDTH, padding: 10 }}
    >
      {children}
    </Surface>
  );
}

function TabCard({ tabId, windowId, anchor }: { tabId: string; windowId: string; anchor: Anchor }) {
  const theme = useTheme();
  const tab = useBrowser((s) => s.tabs[tabId]);
  const isActive = useBrowser((s) => activeTabId(s, windowId) === tabId);
  const bookmarked = useIsBookmarked(tab?.url ?? "");
  const video = useMedia((m) => !!m.sessions[tabId]?.hasVideo || !!m.pipOpen[tabId]);
  const [pip, togglePip] = usePictureInPicture(tabId);
  const sleeping = useIsSleeping(tabId);
  if (!tab) return null;
  const s = () => useBrowser.getState();
  const away = awayFromPin(tab);
  return (
    <Card anchor={anchor}>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
        <TabIcon tabId={tabId} url={tab.url} favicon={tab.favicon} icon={tab.customIcon} />
        <FadeLabel text={tabTitle(tab)} fontSize={13} weight="medium" color={theme.textPrimary} style={{ flex: 1, height: 18 }} />
      </View>
      {tab.url ? (
        <Text numberOfLines={2} style={{ marginTop: 4, fontSize: 11.5, lineHeight: 15, color: theme.textSecondary }}>
          {displayUrl(tab.url)}
        </Text>
      ) : null}
      {sleeping ? (
        <View accessible accessibilityLabel="Web content has been discarded" style={{ flexDirection: "row", alignItems: "center", gap: 4, marginTop: 4 }}>
          <Symbol name="moon.zzz" size={10} color={theme.textTertiary} style={{ width: 14, height: 14 }} />
          <Text style={{ fontSize: 11.5, color: theme.textTertiary }}>This tab needs to reload</Text>
        </View>
      ) : null}
      {away && tab.pinnedUrl ? (
        <Text numberOfLines={1} style={{ marginTop: 2, fontSize: 11.5, color: theme.textTertiary }}>
          Pinned: {displayUrl(tab.pinnedUrl)}
        </Text>
      ) : null}
      <View style={{ flexDirection: "row", gap: 4, marginTop: 8 }}>
        <Action icon={tab.pinned ? "pin.slash" : "pin"} label={tab.pinned ? "Unpin" : "Pin"} onPress={() => s().togglePin(tabId)} />
        {tab.url ? (
          <Action
            icon={bookmarked ? "bookmark.fill" : "bookmark"}
            label={bookmarked ? "Bookmarked" : "Bookmark"}
            onPress={() => s().toggleBookmark(bookmarkProfileId(s(), s().windows[windowId]), { url: tab.url, title: tabTitle(tab), favicon: tab.favicon })}
          />
        ) : null}
        {!isActive && !tab.pinned ? (
          <Action
            icon="rectangle.split.2x1"
            label="Split"
            onPress={() => {
              dismissHover();
              openInSplit(tabId);
            }}
          />
        ) : null}
        {video ? <Action icon={pip ? "pip.exit" : "pip.enter"} label={pip ? "Exit PiP" : "PiP"} onPress={togglePip} /> : null}
        {away ? (
          <Action
            icon="arrow.uturn.backward"
            label="Reset"
            onPress={() => {
              dismissHover();
              s().returnToPinnedUrl(tabId);
            }}
          />
        ) : null}
      </View>
    </Card>
  );
}

const ACTIVATE = [{ name: "activate" }];

function Action({ icon, label, onPress }: { icon: string; label: string; onPress(press: GestureResponderEvent | AccessibilityActionEvent): void }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps} style={{ flex: 1 }}>
      <Pressable
        onPress={onPress}
        accessibilityRole="button"
        accessibilityLabel={label}
        accessibilityActions={ACTIVATE}
        onAccessibilityAction={(event) => event.nativeEvent.actionName === "activate" && onPress(event)}
      >
        {({ pressed }) => (
          <View
            style={{
              height: 44,
              borderRadius: 8,
              alignItems: "center",
              justifyContent: "center",
              gap: 3,
              backgroundColor: pressed ? theme.toolbarPressed : hovered ? theme.toolbarHover : theme.urlPill,
            }}
          >
            <Symbol name={icon} size={13} color={theme.icon} style={{ width: 18, height: 16 }} />
            <Text style={{ fontSize: 10.5, color: theme.textSecondary }}>{label}</Text>
          </View>
        )}
      </Pressable>
    </View>
  );
}

function FolderPeek({ folderId, windowId, anchor }: { folderId: string; windowId: string; anchor: Anchor }) {
  const theme = useTheme();
  const members = useBrowser(useShallow((s) => folderMembers(s, windowId, folderId)));
  const label = useBrowser((s) => folderLabel(folderIn(s, windowId, folderId)));
  const open = useFolderPanel((u) => u.open?.windowId === windowId && u.open.folderId === folderId);
  if (open || !members.length) return null;
  const more = members.length - FOLDER_PEEK_ROWS;
  return (
    <Card anchor={anchor}>
      <Text style={{ fontSize: 12, fontWeight: "600", color: theme.textSecondary, marginBottom: 4, marginLeft: 4 }}>
        {label} · {plural(members.length, "tab")}
      </Text>
      {members.slice(0, FOLDER_PEEK_ROWS).map((id) => (
        <PeekRow key={id} tabId={id} windowId={windowId} />
      ))}
      {more > 0 ? <Text style={{ fontSize: 11.5, color: theme.textTertiary, marginTop: 4, marginLeft: 4 }}>and {more} more</Text> : null}
    </Card>
  );
}

function PeekRow({ tabId, windowId }: { tabId: string; windowId: string }) {
  const theme = useTheme();
  const tab = useBrowser((s) => s.tabs[tabId]);
  const [hovered, setHovered] = useState(false);
  if (!tab) return null;
  return (
    <Pressable
      onPress={() => {
        dismissHover();
        clickTab(windowId, tabId);
      }}
    >
      <View
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => setHovered(false)}
        style={{ height: 28, borderRadius: 7, flexDirection: "row", alignItems: "center", paddingHorizontal: 5, backgroundColor: hovered ? theme.rowHover : undefined }}
      >
        <TabIcon url={tab.url} favicon={tab.favicon} icon={tab.customIcon} size={14} profileId={tab.profileId} />
        <FadeLabel text={tabTitle(tab)} fontSize={12.5} color={theme.textTab} style={{ flex: 1, height: 17, marginLeft: 7 }} />
      </View>
    </Pressable>
  );
}
