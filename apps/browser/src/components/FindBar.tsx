import { useShortcutHint, withShortcut } from "../lib/commandShortcuts";
import { claimFocusTag, findFocus } from "../lib/focusClaims";
import { Surface } from "@solara/shell";
import { memo, useEffect, useRef, useState } from "react";
import { Animated, Easing, findNodeHandle, StyleSheet, View } from "react-native";
import { hex, useTheme } from "../lib/theme";
import { webviews } from "../lib/webviews";
import { useBrowser } from "../store/browser";
import { useFind } from "../store/hooks";
import type { FindState } from "../store/types";
import { replaceInField } from "./site/selection";
import { NativeFindBarView, type NativeFindEvent } from "@solara/settings";

export const FindBar = memo(function FindBar({ tabId }: { tabId: string }) {
  const hasPage = useBrowser((s) => !!s.tabs[tabId]?.url);
  const find = useFind(tabId);
  if (!find.open || !hasPage) return null;
  return <FindBarPanel key={tabId} tabId={tabId} find={find} />;
});

function FindBarPanel({ tabId, find }: { tabId: string; find: FindState }) {
  const previousHint = useShortcutHint("findPrevious");
  const nextHint = useShortcutHint("findNext");
  const theme = useTheme();
  const nativeRef = useRef<View>(null);
  const initialFocusRequest = useRef(find.focusRequest || Date.now()).current;
  const appear = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.timing(appear, { toValue: 1, duration: 160, easing: Easing.out(Easing.cubic), useNativeDriver: true }).start();
  }, []);
  const setFind = (patch: Partial<FindState>) => useBrowser.getState().setFind(tabId, patch);
  const run = (backwards: boolean, query = find.query, findNext = true) => {
    if (!query) setFind({ count: null, active: 0 });
    void webviews.get(tabId)?.find(query, !backwards, findNext);
  };
  const close = () => {
    setFind({ open: false, count: null, active: 0 });
    void webviews.get(tabId)?.stopFinding(false);
    void webviews.get(tabId)?.focus();
  };
  const [replacement, setReplacement] = useState("");
  const [note, setNote] = useState<{ text: string; error: boolean } | null>(null);
  useEffect(() => {
    if (!note) return;
    const timer = setTimeout(() => setNote(null), 2200);
    return () => clearTimeout(timer);
  }, [note]);
  const replace = async (all: boolean) => {
    if (!find.query) return;
    const { field, count } = await replaceInField(tabId, find.query, replacement, all);
    if (!field) return setNote({ text: "Not in a text field", error: true });
    if (all || !count) setNote({ text: count ? `${count} replaced` : "No matches", error: !count });
    run(false, find.query, false);
  };
  const nativeState = JSON.stringify({
    query: find.query,
    count: find.count,
    active: find.active,
    replace: !!find.replace,
    note: note?.text ?? null,
    noteError: !!note?.error,
    focusRequest: find.focusRequest || initialFocusRequest,
    previousTooltip: withShortcut("Previous", previousHint),
    nextTooltip: withShortcut("Next", nextHint),
    dark: !!theme.dark,
    theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, placeholder: theme.placeholder, selection: theme.selection, toolbarHover: theme.toolbarHover, toolbarPressed: theme.toolbarPressed, icon: theme.icon, iconDisabled: theme.iconDisabled, rowHover: theme.rowHover },
  });
  const onNativeEvent = (e: NativeFindEvent) => {
    if (e.kind === "query") {
      setFind({ query: e.text });
      run(false, e.text, false);
    } else if (e.kind === "step") run(e.backwards);
    else if (e.kind === "close") close();
    else if (e.kind === "replacement") setReplacement(e.text);
    else if (e.kind === "replace") void replace(e.all);
    else if (e.kind === "focused") {
      const windowId = useBrowser.getState().tabs[tabId]?.windowId;
      if (windowId) claimFocusTag(windowId, findFocus(tabId), () => findNodeHandle(nativeRef.current));
      if (find.query) void webviews.get(tabId)?.find(find.query, true, false);
    }
  };

  return (
    <Animated.View
      style={{
        position: "absolute",
        top: 10,
        right: 12,
        opacity: appear,
        transform: [{ translateY: appear.interpolate({ inputRange: [0, 1], outputRange: [-6, 0] }) }],
      }}
    >
      <Surface
        fill={hex(theme.panel)}
        cornerRadius={12}
        borderColor={hex(theme.panelBorder)}
        borderWidth={0.5}
        shadowColor="#000000"
        shadowOpacity={theme.panelShadowOpacity}
        shadowRadius={16}
        shadowOffset={[0, 6]}
        style={{ width: 340 }}
      >
        <View ref={nativeRef} style={{ height: find.replace ? 79 : 40 }}>
          <NativeFindBarView style={StyleSheet.absoluteFill} state={nativeState} onFindEvent={(e) => onNativeEvent(e.nativeEvent)} />
        </View>
      </Surface>
    </Animated.View>
  );
}
