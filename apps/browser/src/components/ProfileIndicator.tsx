import { nativeWorkspaceCommand, windowLayoutAnchorsAvailable, windowNativeLayout } from "@solara/settings";
import { useState } from "react";
import { Symbol } from "@solara/shell";
import { Pressable, Text, View } from "react-native";
import { profileNameColor, useTheme } from "../lib/theme";
import { useIsIncognito, useProfiles, useWindowId, useWindowProfile } from "../store/hooks";
import { setMeasuredWidth, useMeasuredWidth } from "./layout/measuredWidths";
import { useHover } from "./primitives";

const PAD = 9;
const HEIGHT = 34;
const MIN_CUT_NAME = 52;
const ICON_WIDTH = 32;
export const PROFILE_INDICATOR_X = 84;

function useIndicator(room: number) {
  const theme = useTheme();
  const incognito = useIsIncognito();
  const profiles = useProfiles();
  const profile = useWindowProfile();
  const title = incognito ? "Incognito" : profile.name;
  const textWidth = useMeasuredWidth(`profile-name|${title}`);
  const shown = (incognito || profiles.length >= 2) && room >= ICON_WIDTH;
  const nameRoom = room - 2 * PAD;
  const showName = !!textWidth && (textWidth <= nameRoom || nameRoom >= MIN_CUT_NAME);
  const width = !shown ? 0 : showName ? Math.min(room, textWidth + 2 * PAD) : ICON_WIDTH;
  const color = incognito ? theme.textPrimary : profileNameColor(profile, theme.dark);
  return { incognito, title, textWidth, shown, showName, width, color };
}

export const useProfileIndicatorWidth = (room: number) => useIndicator(room).width;

export function useProfileTitle() {
  const incognito = useIsIncognito();
  const profile = useWindowProfile();
  return incognito ? "Incognito" : profile.name;
}

export function ProfileNameMeasure({ title }: { title: string }) {
  const windowId = useWindowId();
  const [native] = useState(() => windowNativeLayout(windowId) && windowLayoutAnchorsAvailable(windowId));
  if (native) return null;
  return (
    <View pointerEvents="none" style={{ position: "absolute", width: 1000, height: 0, overflow: "hidden", opacity: 0 }}>
      <Text
        numberOfLines={1}
        style={{ alignSelf: "flex-start", fontSize: 13, fontWeight: "600" }}
        onLayout={(e) => setMeasuredWidth(`profile-name|${title}`, Math.ceil(e.nativeEvent.layout.width))}
      >
        {title}
      </Text>
    </View>
  );
}

export function ProfileIndicator({ room, captionAligned = false }: { room: number; captionAligned?: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const { hovered, hoverProps } = useHover();
  const { incognito, title, textWidth, shown, showName, width, color } = useIndicator(room);
  if (!shown) return null;

  return (
    <View {...hoverProps} tooltip={incognito ? undefined : "Switch between profiles"} style={{ marginTop: captionAligned ? 0 : 0.5 }}>
      <ProfileNameMeasure title={title} />
      <Pressable accessible accessibilityRole="button" accessibilityLabel={title} onPress={() => !incognito && void nativeWorkspaceCommand("openProfileMenu", null, windowId)} disabled={incognito}>
        {({ pressed }) => (
          <View
            style={{
              height: HEIGHT,
              width,
              borderRadius: 10,
              flexDirection: "row",
              alignItems: "center",
              justifyContent: "center",
              paddingHorizontal: showName ? PAD : 0,
              backgroundColor: incognito ? undefined : pressed ? theme.tabPressed : hovered ? theme.tabHover : undefined,
            }}
          >
            {showName ? (
              <Text numberOfLines={1} ellipsizeMode="tail" style={{ flexShrink: 1, fontSize: 13, fontWeight: "600", color }}>
                {title}
              </Text>
            ) : textWidth ? (
              <Symbol name="person.fill" size={14} weight="semibold" color={color} style={{ width: 16, height: 16 }} />
            ) : null}
          </View>
        )}
      </Pressable>
    </View>
  );
}
