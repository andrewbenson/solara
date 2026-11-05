import { permissionWarnings, type InstalledExtension } from "@solara/solaracore";
import { Surface } from "@solara/shell";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Animated, Easing, findNodeHandle, Image, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { hex, useTheme } from "../../lib/theme";
import { webviews } from "../../lib/webviews";
import { useBrowser } from "../../store/browser";
import { shownPageId } from "../../store/peek";
import { useWindowId } from "../../store/hooks";
import { PromptButton } from "../layout/controls";
import { Checkbox, useFormColors } from "../settings/controls";
import { nativeToolbarAvailable, NativePanelView, type NativePanelEvent } from "@solara/settings";
import {
  cancelInstall,
  confirmInstall,
  extensionProfile,
  setPinned,
  useExtensions,
  useWindowExtensions,
  type InstallRequest,
} from "./state";

export function ExtensionOverlays() {
  const windowId = useWindowId();
  const install = useExtensions((e) => (e.install?.windowId === windowId ? e.install : null));
  const pin = useExtensions((e) => e.pinDialog?.windowId === windowId);
  return (
    <>
      {install && <InstallDialog request={install} />}
      {pin && <PinDialog windowId={windowId} />}
    </>
  );
}

export function InstallDialogHost({ windowId, onClosed }: { windowId: string; onClosed: () => void }) {
  const install = useExtensions((e) => (e.install?.windowId === windowId ? e.install : null));
  useEffect(() => {
    if (!install) onClosed();
  }, [!install]);
  return install ? <InstallDialog request={install} /> : null;
}

function InstallDialog({ request }: { request: InstallRequest }) {
  const theme = useTheme();
  const pkg = request.pkg;
  const name = pkg?.name ?? "Extension";
  const warnings = request.prompt ? request.prompt.permissions : pkg ? permissionWarnings(pkg) : [];
  const kind = request.prompt?.type;
  const title = kind === "re-enable" ? `Turn “${name}” back on?` : kind === "permissions" ? `“${name}” needs new permissions` : `Add “${name}”?`;
  const action = kind === "re-enable" ? "Turn On" : kind === "permissions" ? "Allow" : "Add Extension";
  const busy = request.status === "installing";
  if (nativeToolbarAvailable()) {
    return (
      <Dialog windowId={request.windowId} onDismiss={busy ? undefined : cancelInstall} onSubmit={request.status === "error" ? cancelInstall : () => void confirmInstall()}>
        <NativeDialogBody
          kind="extensionInstall"
          state={JSON.stringify({
            status: request.status,
            title,
            error: request.error ?? null,
            icon: pkg?.icon ?? null,
            warnings,
            loadedFrom: request.source === "unpacked" ? (pkg?.path ?? "") : null,
            action,
            dark: !!theme.dark,
            theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, textTertiary: theme.textTertiary },
            goButton: theme.goButton,
            goButtonText: theme.goButtonText,
          })}
          onEvent={(e) => (e.kind === "confirm" ? void confirmInstall() : cancelInstall())}
        />
      </Dialog>
    );
  }

  let body;
  if (request.status === "error") {
    body = (
      <>
        <Text style={{ fontSize: 15, fontWeight: "600", color: theme.textPrimary }}>Couldn't add the extension</Text>
        <Text style={{ fontSize: 13, color: theme.textSecondary, marginTop: 6 }}>{request.error}</Text>
      </>
    );
  } else {
    body = (
      <>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
          {pkg?.icon ? <Image source={{ uri: pkg.icon }} style={{ width: 36, height: 36 }} /> : null}
          <Text style={{ flex: 1, fontSize: 15, fontWeight: "600", color: theme.textPrimary }}>{title}</Text>
        </View>
        {warnings.length ? (
          <>
            <Text style={{ fontSize: 13, color: theme.textPrimary, marginTop: 14, marginBottom: 6 }}>It can:</Text>
            <ScrollView style={{ maxHeight: 180 }}>
              {warnings.map((w) => (
                <View key={w} style={{ flexDirection: "row", gap: 7, marginBottom: 4 }}>
                  <Text style={{ fontSize: 13, color: theme.textSecondary }}>•</Text>
                  <Text style={{ flex: 1, fontSize: 13, color: theme.textSecondary }}>{w}</Text>
                </View>
              ))}
            </ScrollView>
          </>
        ) : (
          <Text style={{ fontSize: 13, color: theme.textSecondary, marginTop: 14 }}>This extension requires no special permissions.</Text>
        )}
        {request.source === "unpacked" ? (
          <Text numberOfLines={2} ellipsizeMode="middle" style={{ fontSize: 11, color: theme.textTertiary, marginTop: 10 }}>
            {`Loaded from ${pkg?.path ?? ""}`}
          </Text>
        ) : null}
      </>
    );
  }

  return (
    <Dialog windowId={request.windowId} onDismiss={busy ? undefined : cancelInstall} onSubmit={request.status === "error" ? cancelInstall : () => void confirmInstall()}>
      {body}
      <View style={{ flexDirection: "row", justifyContent: "flex-end", gap: 8, marginTop: 18 }}>
        {request.status === "error" ? (
          <PromptButton title="OK" primary onPress={cancelInstall} />
        ) : (
          <>
            <PromptButton title="Cancel" onPress={cancelInstall} />
            <PromptButton title={request.status === "installing" ? "Adding…" : action} primary onPress={() => void confirmInstall()} />
          </>
        )}
      </View>
    </Dialog>
  );
}

function PinDialog({ windowId }: { windowId: string }) {
  const theme = useTheme();
  const profile = useBrowser((s) => extensionProfile(s, windowId));
  const list = useWindowExtensions(windowId);
  const close = () => useExtensions.setState({ pinDialog: null });
  const colors = useFormColors();
  if (nativeToolbarAvailable()) {
    return (
      <Dialog windowId={windowId} onDismiss={close} onSubmit={close}>
        <NativeDialogBody
          kind="extensionPins"
          state={JSON.stringify({
            extensions: list.map((ext) => ({ id: ext.id, name: ext.name, icon: ext.actionIcon || ext.icon || null, pinned: !!ext.pinned })),
            dark: !!theme.dark,
            theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, textTertiary: theme.textTertiary, accent: colors.accent },
            control: colors.control,
            controlBorder: colors.controlBorder,
            goButton: theme.goButton,
            goButtonText: theme.goButtonText,
          })}
          onEvent={(e) => (e.kind === "toggle" ? void setPinned(profile, String(e.id), !!e.pinned) : close())}
        />
      </Dialog>
    );
  }
  return (
    <Dialog windowId={windowId} onDismiss={close} onSubmit={close}>
      <Text style={{ fontSize: 15, fontWeight: "600", color: theme.textPrimary }}>Pin Extensions</Text>
      <Text style={{ fontSize: 13, color: theme.textSecondary, marginTop: 4, marginBottom: 12 }}>
        Pinned extensions appear in the toolbar, next to the address.
      </Text>
      {list.length ? (
        <ScrollView style={{ maxHeight: 300 }}>
          {list.map((ext) => (
            <PinRow key={ext.id} ext={ext} onChange={(pinned) => void setPinned(profile, ext.id, pinned)} />
          ))}
        </ScrollView>
      ) : (
        <Text style={{ fontSize: 13, color: theme.textTertiary }}>No extensions are turned on.</Text>
      )}
      <View style={{ flexDirection: "row", justifyContent: "flex-end", marginTop: 16 }}>
        <PromptButton title="Done" primary onPress={close} />
      </View>
    </Dialog>
  );
}

function PinRow({ ext, onChange }: { ext: InstalledExtension; onChange: (pinned: boolean) => void }) {
  const theme = useTheme();
  return (
    <Pressable onPress={() => onChange(!ext.pinned)} style={{ flexDirection: "row", alignItems: "center", gap: 10, paddingVertical: 6 }}>
      <Checkbox value={ext.pinned} onChange={onChange} />
      <Image source={{ uri: ext.actionIcon || ext.icon }} style={{ width: 16, height: 16 }} />
      <Text numberOfLines={1} style={{ flex: 1, fontSize: 13, color: theme.textPrimary }}>
        {ext.name}
      </Text>
    </Pressable>
  );
}

function Dialog({ windowId, onDismiss, onSubmit, children }: { windowId: string; onDismiss?: () => void; onSubmit?: () => void; children: ReactNode }) {
  const theme = useTheme();
  const appear = useRef(new Animated.Value(0)).current;
  const keys = useRef<View>(null);
  useEffect(() => {
    Animated.timing(appear, { toValue: 1, duration: 170, easing: Easing.out(Easing.cubic), useNativeDriver: true }).start();
    keys.current?.focus();
    return () => {
      const tabId = shownPageId(useBrowser.getState(), windowId);
      if (tabId) void webviews.get(tabId)?.focus();
    };
  }, []);
  return (
    <View style={[StyleSheet.absoluteFill, { alignItems: "center", justifyContent: "center" }]}>
      <Animated.View style={[StyleSheet.absoluteFill, { opacity: appear, backgroundColor: theme.dark ? "rgba(0,0,0,0.35)" : "rgba(0,0,0,0.15)" }]}>
        <Pressable focusable={false} style={StyleSheet.absoluteFill} onPress={onDismiss} />
      </Animated.View>
      <Animated.View style={{ opacity: appear, transform: [{ scale: appear.interpolate({ inputRange: [0, 1], outputRange: [0.96, 1] }) }] }}>
        <Surface
          fill={hex(theme.panel)}
          cornerRadius={14}
          borderColor={hex(theme.panelBorder)}
          borderWidth={0.5}
          shadowColor="#000000"
          shadowOpacity={theme.panelShadowOpacity}
          shadowRadius={30}
          shadowOffset={[0, 12]}
          style={{ width: 380 }}
        >
          <View
            ref={keys}
            focusable
            enableFocusRing={false}
            keyDownEvents={DIALOG_KEYS}
            onKeyDown={(e) => {
              if (e.nativeEvent.key === "Escape") onDismiss?.();
              else if (e.nativeEvent.key === "Enter" && targetTag(e.nativeEvent) === findNodeHandle(keys.current)) onSubmit?.();
            }}
            style={{ padding: 20 }}
          >
            {children}
          </View>
        </Surface>
      </Animated.View>
    </View>
  );
}

const DIALOG_KEYS = [{ key: "Escape" }, { key: "Enter" }, { key: "Tab" }, { key: "Tab", shiftKey: true }];
const targetTag = (event: object) => (event as { target?: number }).target;

function NativeDialogBody({ kind, state, onEvent }: { kind: string; state: string; onEvent: (e: NativePanelEvent & { id?: unknown; pinned?: unknown }) => void }) {
  const [height, setHeight] = useState<number | null>(null);
  return (
    <View style={{ height: height ?? undefined, minHeight: 1 }}>
      <NativePanelView kind={kind} style={StyleSheet.absoluteFill} state={state} onPanelEvent={(e) => onEvent(e.nativeEvent)} onPanelHeight={(e) => setHeight(e.nativeEvent.height)} />
    </View>
  );
}
