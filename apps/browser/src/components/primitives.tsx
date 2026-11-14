import { displayHost } from "@solara/core";
import { Symbol, type SymbolProps } from "@solara/shell";
import { onHostedEvent, SolaraHostedView } from "@solara/settings";
import { memo, useLayoutEffect, useRef, useState } from "react";
import { Image, Pressable, View, type ViewStyle } from "react-native";
import { markHoverProps } from "../lib/hoverShift";
import { faviconFailed, useAppearanceDark, useFavicon, useFaviconTheme } from "../lib/favicons";
import { bundledSiteIcon } from "../lib/siteIcons";
import { useTheme } from "../lib/theme";
import { useWindowId } from "../store/hooks";

export function useHover() {
  const [hovered, setHovered] = useState(false);
  const [hoverProps] = useState(() => markHoverProps({ onMouseEnter: () => setHovered(true), onMouseLeave: () => setHovered(false) }));
  return { hovered, hoverProps };
}

export const IconButton = memo(function IconButton({
  icon,
  onPress,
  disabled,
  active,
  size = 15,
  box = 30,
  radius = 7,
  weight = "regular",
  tooltip,
  color,
  style,
}: {
  icon: string;
  onPress?: () => void;
  disabled?: boolean;
  active?: boolean;
  size?: number;
  box?: number;
  radius?: number;
  weight?: SymbolProps["weight"];
  tooltip?: string;
  color?: string;
  style?: ViewStyle;
}) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View tooltip={tooltip} style={style} {...hoverProps}>
      <Pressable onPress={onPress} disabled={disabled}>
        {({ pressed }) => (
          <View
            style={{
              width: box,
              height: box,
              borderRadius: radius,
              alignItems: "center",
              justifyContent: "center",
              backgroundColor: disabled ? undefined : pressed || active ? theme.toolbarPressed : hovered ? theme.toolbarHover : undefined,
            }}
          >
            <Symbol
              name={icon}
              size={size}
              weight={weight}
              color={color ?? (disabled ? theme.iconDisabled : theme.icon)}
              style={{ width: box, height: box }}
            />
          </View>
        )}
      </Pressable>
    </View>
  );
});

export const Favicon = memo(function Favicon({
  url,
  favicon,
  size = 16,
  profileId,
  direct,
}: {
  url: string;
  favicon?: string | null;
  size?: number;
  profileId?: string;
  direct?: boolean;
}) {
  const theme = useTheme();
  useAppearanceDark();
  const cached = useFavicon(url, direct ? null : favicon, profileId);
  const resolved = direct && favicon ? { uri: favicon, profileId: "" } : cached;
  const shape = useFaviconTheme(theme.dark || direct ? "" : url, favicon, profileId);
  const white = shape?.kind === "template" && !!shape.stroke;
  const [broken, setBroken] = useState<string | null>(null);
  if (!url && !resolved) return <NewTabIcon size={size} />;
  if (!resolved || broken === resolved.uri) return <FaviconFallback url={url} size={size} />;
  return <NativeFavicon mode="image" url={url} size={size} uri={resolved.uri} tint={white ? theme.textPrimary : undefined} onError={() => {
    setBroken(resolved.uri);
    if (resolved.profileId) faviconFailed(resolved.profileId, resolved.uri);
  }} />;
});

export const FaviconFallback = memo(function FaviconFallback({ url, size = 16 }: { url: string; size?: number }) {
  const theme = useTheme();
  const bundled = bundledSiteIcon(url, theme.dark);
  const uri = bundled === undefined ? undefined : Image.resolveAssetSource(bundled)?.uri;
  return <NativeFavicon mode={bundled === undefined ? "fallback" : "image"} url={url} size={size} uri={uri} initial={hostInitial(url)} />;
});

function hostInitial(url: string): string {
  const host = /^(?:https?|ftp):\/\/(?:[^@/?#]*@)?([^/?#:]+)/i.exec(url)?.[1];
  if (!host || /^[\d.]+$|^\[/.test(host)) return "";
  const shown = displayHost(host.toLowerCase()).replace(/^www\./, "");
  return Array.from(shown)[0]?.toLocaleUpperCase() ?? "";
}

export const NEW_TAB_MARK: number = require("../../assets/solara/new-tab-mark.png");

export function NewTabIcon({ size = 16 }: { size?: number }) {
  return <NativeFavicon mode="newTab" url="" size={size} uri={Image.resolveAssetSource(NEW_TAB_MARK)?.uri} />;
}

let faviconReceipts = 0;

function NativeFavicon({ mode, url, size, uri, tint, initial, onError }: {
  mode: "image" | "fallback" | "newTab";
  url: string;
  size: number;
  uri?: string;
  tint?: string;
  initial?: string;
  onError?: () => void;
}) {
  const theme = useTheme();
  const windowId = useWindowId();
  const current = useRef<{ token: number; windowId: string; uri: string | undefined; mode: string; onError?: () => void } | null>(null);
  if (!current.current || current.current.windowId !== windowId || current.current.uri !== uri || current.current.mode !== mode) current.current = { token: ++faviconReceipts, windowId, uri, mode, onError };
  current.current.onError = onError;
  useLayoutEffect(() => onHostedEvent("favicon", windowId, (name, payload) => {
    if (name === "error" && current.current?.windowId === windowId && payload.token === current.current.token && payload.uri === current.current.uri) current.current.onError?.();
  }), [windowId]);
  return <SolaraHostedView kind="favicon" windowId={windowId} pointerEvents="none" accessible={false}
    state={JSON.stringify({ mode, url, size, uri, tint, initial, token: current.current.token, dark: !!theme.dark, textSecondary: theme.textSecondary })}
    style={{ width: size, height: size }} />;
}
