import { useState } from "react";
import { Pressable, View } from "react-native";
import { useShallow } from "zustand/react/shallow";
import { switchProfile } from "../../lib/actions";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useIsIncognito, useWindowProfileId } from "../../store/hooks";
import { useHover } from "../primitives";
import { TooltipAbove } from "../TooltipAbove";

export const PROFILE_DOTS_HEIGHT = 41;
const CELL = 12;
const DOT = 6;
const BAND = 28;
const SELECTED = 0.85;
const HOVERED = 0.4;
const IDLE = 0.2;
const DOT_CENTER_TO_TOOLTIP = 18.25;

export function useProfileDotsShown() {
  const incognito = useIsIncognito();
  const count = useBrowser((s) => s.profileOrder.length);
  return !incognito && count > 1;
}

export function ProfileDots({ windowId }: { windowId: string }) {
  const ids = useBrowser(useShallow((s) => s.profileOrder));
  const current = useWindowProfileId();
  return (
    <View style={{ height: PROFILE_DOTS_HEIGHT, alignItems: "center" }}>
      <View style={{ marginTop: (PROFILE_DOTS_HEIGHT - 3 - BAND) / 2, height: BAND, flexDirection: "row" }}>
        {ids.map((id) => (
          <Dot key={id} id={id} windowId={windowId} selected={id === current} />
        ))}
      </View>
    </View>
  );
}

function Dot({ id, windowId, selected }: { id: string; windowId: string; selected: boolean }) {
  const theme = useTheme();
  const name = useBrowser((s) => s.profiles[id]?.name ?? "");
  const { hovered, hoverProps } = useHover();
  const [pressed, setPressed] = useState(false);
  if (pressed && !hovered) setPressed(false);
  const opacity = selected ? SELECTED : hovered ? HOVERED : IDLE;
  return (
    <View {...hoverProps}>
      <TooltipAbove text={name} active={hovered && !pressed} centerX={CELL / 2} bottom={BAND / 2 + DOT_CENTER_TO_TOOLTIP} />
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={name}
        onPress={() => {
          setPressed(true);
          switchProfile(windowId, id, true);
        }}
      >
        <View style={{ width: CELL, height: BAND, alignItems: "center", justifyContent: "center" }}>
          <View style={{ width: DOT, height: DOT, borderRadius: DOT / 2, backgroundColor: theme.dark ? "#FFFFFF" : "#000000", opacity }} />
        </View>
      </Pressable>
    </View>
  );
}
